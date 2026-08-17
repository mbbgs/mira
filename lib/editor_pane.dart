import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import 'package:highlight/languages/go.dart';
import 'lsp_client.dart';

/// Embeddable editor for a single file — no Scaffold/AppBar of its own,
/// meant to live inside a tab body in the IDE shell. Holds all the real
/// logic: loading/saving via the backend, the LSP handshake, diagnostics,
/// and completions. One instance per open tab; each keeps its own
/// LspClient connection (gopls handles multiple concurrent client
/// connections to the same workspace fine — each is a normal LSP
/// session).
class EditorPane extends StatefulWidget {
  final String host;
  final String filePath;
  final void Function(String status)? onLspStatus;
  final void Function(int problemCount)? onDiagnosticsCount;

  const EditorPane({
    super.key,
    required this.host,
    required this.filePath,
    this.onLspStatus,
    this.onDiagnosticsCount,
  });

  @override
  State<EditorPane> createState() => EditorPaneState();
}

class EditorPaneState extends State<EditorPane> {
  late final CodeController _controller;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  LspClient? _lsp;
  String _lspStatus = 'connecting...';
  List<dynamic> _diagnostics = [];
  List<dynamic> _completions = [];
  Timer? _debounce;
  int _docVersion = 1;
  String get _fileUri => 'file://${widget.filePath}';

  final LayerLink _editorLayerLink = LayerLink();
  OverlayEntry? _completionOverlay;
  Offset _completionOffset = Offset.zero;

  static const _fontSize = 12.0;
  static const _fontFamily = 'monospace';
  static const _lineHeight = _fontSize * 1.4; // matches default TextStyle height used below
  static const _gutterWidth = 32.0 + 4.0; // GutterStyle width + margin, from the CodeField below

  bool get isSaving => _saving;

  @override
  void initState() {
    super.initState();
    _controller = CodeController(text: '', language: go);
    _controller.addListener(_onTextChanged);
    _loadFile();
    _connectLsp();
  }

  void _onTextChanged() {
    final lsp = _lsp;
    if (lsp == null) return;
    _docVersion++;
    lsp.didChange(_fileUri, _docVersion, _controller.fullText);

    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _requestCompletion);
  }

  ({int line, int character}) _offsetToPosition(String text, int offset) {
    var line = 0;
    var lastNewline = -1;
    for (var i = 0; i < offset && i < text.length; i++) {
      if (text[i] == '\n') {
        line++;
        lastNewline = i;
      }
    }
    final character = offset - lastNewline - 1;
    return (line: line, character: character);
  }

  Future<void> _requestCompletion() async {
    final lsp = _lsp;
    if (lsp == null) return;
    final selection = _controller.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      _hideCompletionOverlay();
      return;
    }
    final text = _controller.fullText;
    final pos = _offsetToPosition(text, selection.baseOffset);
    try {
      final items = await lsp.completion(_fileUri, pos.line, pos.character);
      if (!mounted) return;
      _completions = items;
      if (items.isEmpty) {
        _hideCompletionOverlay();
      } else {
        _updateCompletionPosition(text, selection.baseOffset);
        _showCompletionOverlay();
      }
    } catch (_) {
      _hideCompletionOverlay();
    }
  }

  // Uses TextPainter — Flutter's real text-measurement API — to compute
  // the pixel width of the current line up to the cursor, so the
  // popup lands directly under the caret rather than at a guessed spot.
  // This is exact for our case because the editor uses a fixed-size
  // monospace font, so per-character width is uniform and measurable.
  void _updateCompletionPosition(String text, int offset) {
    final pos = _offsetToPosition(text, offset);
    final lineStart = offset - pos.character;
    final lineText = text.substring(
      lineStart.clamp(0, text.length),
      offset.clamp(0, text.length),
    );
    final painter = TextPainter(
      text: TextSpan(
        text: lineText,
        style: const TextStyle(fontFamily: _fontFamily, fontSize: _fontSize),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    setState(() {
      _completionOffset = Offset(
        _gutterWidth + painter.width,
        (pos.line + 1) * _lineHeight,
      );
    });
  }

  void _showCompletionOverlay() {
    _completionOverlay?.remove();
    _completionOverlay = OverlayEntry(
      builder: (context) => Positioned(
        width: 260,
        child: CompositedTransformFollower(
          link: _editorLayerLink,
          showWhenUnlinked: false,
          offset: _completionOffset,
          child: Material(
            elevation: 6,
            color: const Color(0xFF272822),
            borderRadius: BorderRadius.circular(4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _completions.length,
                itemBuilder: (context, i) {
                  final item = _completions[i] as Map;
                  final label = item['label'] as String? ?? '';
                  final detail = item['detail'] as String?;
                  return ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    leading: const Icon(Icons.code, size: 14, color: Colors.tealAccent),
                    title: Text(
                      label,
                      style: const TextStyle(
                        fontFamily: _fontFamily,
                        fontSize: 12,
                        color: Colors.white,
                      ),
                    ),
                    subtitle: detail != null
                        ? Text(
                            detail,
                            style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : null,
                    onTap: () => _applyCompletion(item),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(_completionOverlay!);
  }

  void _hideCompletionOverlay() {
    _completionOverlay?.remove();
    _completionOverlay = null;
    if (_completions.isNotEmpty && mounted) {
      setState(() => _completions = []);
    }
  }

  void _applyCompletion(Map item) {
    final label = item['label'] as String? ?? '';
    final insertText = item['insertText'] as String? ?? label;
    if (insertText.isEmpty) return;

    final selection = _controller.selection;
    if (!selection.isValid) return;
    final text = _controller.fullText;
    final offset = selection.baseOffset;

    var start = offset;
    while (start > 0 && _isIdentifierChar(text[start - 1])) {
      start--;
    }
    final newText = text.replaceRange(start, offset, insertText);
    final newOffset = start + insertText.length;

    _controller.removeListener(_onTextChanged);
    _controller.fullText = newText;
    _controller.selection = TextSelection.collapsed(offset: newOffset);
    _controller.addListener(_onTextChanged);

    _hideCompletionOverlay();

    final lsp = _lsp;
    if (lsp != null) {
      _docVersion++;
      lsp.didChange(_fileUri, _docVersion, _controller.fullText);
    }
  }

  bool _isIdentifierChar(String ch) => RegExp(r'[A-Za-z0-9_]').hasMatch(ch);

  Future<void> _loadFile() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = Uri.parse('http://${widget.host}/files/read')
          .replace(queryParameters: {'path': widget.filePath});
      final resp = await http.get(uri);
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      _controller.text = body['content'] as String;
      setState(() => _loading = false);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Public so the shell's toolbar Save button can trigger it.
  Future<void> save() async {
    setState(() => _saving = true);
    try {
      final uri = Uri.parse('http://${widget.host}/files/write');
      final resp = await http.post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'path': widget.filePath,
          'content': _controller.fullText,
        }),
      );
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Saved'), duration: Duration(seconds: 1)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Save failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _connectLsp() async {
    final dir = widget.filePath.contains('/')
        ? widget.filePath.substring(0, widget.filePath.lastIndexOf('/'))
        : widget.filePath;
    final uri = Uri.parse('ws://${widget.host}/lsp?dir=$dir');
    try {
      final channel = WebSocketChannel.connect(uri);
      final lsp = LspClient(
        channel,
        onStatus: (status) {
          if (mounted) setState(() => _lspStatus = status);
          widget.onLspStatus?.call(status);
        },
        onDiagnostics: (fileUri, diags) {
          if (mounted) setState(() => _diagnostics = diags);
          widget.onDiagnosticsCount?.call(diags.length);
        },
      );
      _lsp = lsp;
      await lsp.initialize(rootUri: 'file://$dir');
      lsp.didOpen('file://${widget.filePath}', 'go', _controller.fullText);
    } catch (e) {
      if (mounted) setState(() => _lspStatus = 'connect failed: $e');
      widget.onLspStatus?.call('connect failed: $e');
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onTextChanged);
    _completionOverlay?.remove();
    _lsp?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text('Failed to load file:\n$_error'));
    }
    return Column(
      children: [
        if (_diagnostics.isNotEmpty)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              initiallyExpanded: true,
              tilePadding: const EdgeInsets.symmetric(horizontal: 12),
              backgroundColor: Colors.red.withValues(alpha: 0.08),
              collapsedBackgroundColor: Colors.red.withValues(alpha: 0.08),
              title: Text(
                '${_diagnostics.length} problem${_diagnostics.length == 1 ? '' : 's'}',
                style: const TextStyle(
                  color: Colors.redAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              children: _diagnostics.map((d) {
                final msg = (d as Map)['message'] as String? ?? '';
                final line =
                    ((d['range'] as Map?)?['start'] as Map?)?['line'] as int?;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Line ${(line ?? 0) + 1}: $msg',
                      style:
                          const TextStyle(color: Colors.redAccent, fontSize: 12),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        Expanded(
          child: CompositedTransformTarget(
            link: _editorLayerLink,
            child: SingleChildScrollView(
              child: CodeTheme(
                data: CodeThemeData(styles: monokaiSublimeTheme),
                child: CodeField(
                  controller: _controller,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  gutterStyle: const GutterStyle(width: 32, margin: 4),
                  textStyle: const TextStyle(fontFamily: _fontFamily, fontSize: _fontSize),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
