import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import 'package:highlight/languages/go.dart';
import 'lsp_client.dart';

// Real file editor: loads content from the backend (/files/read), lets
// you edit with Go syntax highlighting, saves back (/files/write).
// The LSP connection to gopls opens automatically as soon as this screen
// loads — no separate "connect" step. Diagnostics show as a red banner;
// completions show as a popup list below the cursor line, driven by real
// textDocument/completion requests to gopls.
class CodeEditorScreen extends StatefulWidget {
  final String host;
  final String filePath;
  const CodeEditorScreen({
    super.key,
    required this.host,
    required this.filePath,
  });

  @override
  State<CodeEditorScreen> createState() => _CodeEditorScreenState();
}

class _CodeEditorScreenState extends State<CodeEditorScreen> {
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

  // Converts a character offset in the text into 0-indexed {line, character}
  // as LSP expects. character is a UTF-16 code-unit count within the line —
  // Dart strings are already UTF-16 internally, so .length here is correct.
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
      if (mounted) setState(() => _completions = []);
      return;
    }
    final text = _controller.fullText;
    final pos = _offsetToPosition(text, selection.baseOffset);
    try {
      final items = await lsp.completion(_fileUri, pos.line, pos.character);
      if (mounted) setState(() => _completions = items);
    } catch (_) {
      // Timed-out or errored completion request — just show nothing
      // rather than surface a popup error for a background feature.
      if (mounted) setState(() => _completions = []);
    }
  }

  void _applyCompletion(Map item) {
    final label = item['label'] as String? ?? '';
    // insertText, when present, is what should actually be typed; falls
    // back to label if the server didn't provide one, per spec.
    final insertText = item['insertText'] as String? ?? label;
    if (insertText.isEmpty) return;

    final selection = _controller.selection;
    if (!selection.isValid) return;
    final text = _controller.fullText;
    final offset = selection.baseOffset;

    // Replace the partial word being typed (back to the last
    // non-identifier character) with the chosen completion.
    var start = offset;
    while (start > 0 && _isIdentifierChar(text[start - 1])) {
      start--;
    }
    final newText = text.replaceRange(start, offset, insertText);
    final newOffset = start + insertText.length;

    _controller.removeListener(_onTextChanged); // avoid recursive trigger
    _controller.fullText = newText;
    _controller.selection = TextSelection.collapsed(offset: newOffset);
    _controller.addListener(_onTextChanged);

    setState(() => _completions = []);

    final lsp = _lsp;
    if (lsp != null) {
      _docVersion++;
      lsp.didChange(_fileUri, _docVersion, _controller.fullText);
    }
  }

  bool _isIdentifierChar(String ch) {
    return RegExp(r'[A-Za-z0-9_]').hasMatch(ch);
  }

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

  Future<void> _saveFile() async {
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
          const SnackBar(content: Text('Saved'), duration: Duration(seconds: 1)),
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

  // Opens automatically when the screen loads — this is the "no buttons"
  // part. dir= is the file's containing folder so gopls resolves the
  // right module/package context for it. Does the real LSP handshake
  // (initialize -> initialized) before treating the connection as ready.
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
        },
        onDiagnostics: (fileUri, diags) {
          if (mounted) setState(() => _diagnostics = diags);
        },
      );
      _lsp = lsp;
      await lsp.initialize(rootUri: 'file://$dir');
      lsp.didOpen('file://${widget.filePath}', 'go', _controller.fullText);
    } catch (e) {
      if (mounted) setState(() => _lspStatus = 'connect failed: $e');
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onTextChanged);
    _lsp?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.filePath.split('/').last,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(
              child: Text(
                'lsp: $_lspStatus',
                style: TextStyle(
                  fontSize: 11,
                  color: _lspStatus == 'connected'
                      ? Colors.greenAccent
                      : Colors.orange,
                ),
              ),
            ),
          ),
          IconButton(
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save),
            onPressed: _saving ? null : _saveFile,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('Failed to load file:\n$_error'))
              : Column(
                  children: [
                    if (_diagnostics.isNotEmpty)
                      Container(
                        width: double.infinity,
                        color: Colors.red.withValues(alpha: 0.15),
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: _diagnostics.map((d) {
                            final msg = (d as Map)['message'] as String? ?? '';
                            final line = ((d['range'] as Map?)?['start']
                                    as Map?)?['line'] as int?;
                            return Text(
                              'Line ${(line ?? 0) + 1}: $msg',
                              style: const TextStyle(
                                  color: Colors.redAccent, fontSize: 12),
                            );
                          }).toList(),
                        ),
                      ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: CodeTheme(
                          data: CodeThemeData(styles: monokaiSublimeTheme),
                          child: CodeField(
                            controller: _controller,
                            textStyle: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_completions.isNotEmpty)
                      Container(
                        constraints: const BoxConstraints(maxHeight: 180),
                        decoration: BoxDecoration(
                          color: const Color(0xFF272822), // matches monokai bg
                          border: Border(
                            top: BorderSide(color: Colors.grey.shade800),
                          ),
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: _completions.length,
                          itemBuilder: (context, i) {
                            final item = _completions[i] as Map;
                            final label = item['label'] as String? ?? '';
                            final detail = item['detail'] as String?;
                            return ListTile(
                              dense: true,
                              leading: const Icon(
                                Icons.code,
                                size: 16,
                                color: Colors.tealAccent,
                              ),
                              title: Text(
                                label,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 13,
                                  color: Colors.white,
                                ),
                              ),
                              subtitle: detail != null
                                  ? Text(
                                      detail,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Colors.grey.shade400,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    )
                                  : null,
                              onTap: () => _applyCompletion(item),
                            );
                          },
                        ),
                      ),
                  ],
                ),
    );
  }
}
