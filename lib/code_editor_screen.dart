import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import 'package:highlight/languages/go.dart';

// Real file editor: loads content from the backend (/files/read), lets
// you edit with Go syntax highlighting, saves back (/files/write).
// The LSP connection to gopls opens automatically as soon as this screen
// loads — no separate "connect" step. LSP messages are received and
// logged for now; wiring diagnostics/completion into the UI is the next
// piece of work, not this one.
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
  WebSocketChannel? _lspChannel;
  String _lspStatus = 'connecting...';

  @override
  void initState() {
    super.initState();
    _controller = CodeController(text: '', language: go);
    _loadFile();
    _connectLsp();
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
  // right module/package context for it.
  void _connectLsp() {
    final dir = widget.filePath.contains('/')
        ? widget.filePath.substring(0, widget.filePath.lastIndexOf('/'))
        : widget.filePath;
    final uri = Uri.parse('ws://${widget.host}/lsp?dir=$dir');
    try {
      final channel = WebSocketChannel.connect(uri);
      _lspChannel = channel;
      channel.stream.listen(
        (data) {
          // gopls speaks raw LSP JSON-RPC (Content-Length framed) here.
          // Parsing that into diagnostics/completion UI is the next
          // piece of work; for now this just confirms the connection is
          // alive so the status indicator is honest.
          if (mounted) setState(() => _lspStatus = 'connected');
        },
        onError: (e) {
          if (mounted) setState(() => _lspStatus = 'error: $e');
        },
        onDone: () {
          if (mounted) setState(() => _lspStatus = 'disconnected');
        },
      );
    } catch (e) {
      setState(() => _lspStatus = 'connect failed: $e');
    }
  }

  @override
  void dispose() {
    _lspChannel?.sink.close();
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
              : SingleChildScrollView(
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
    );
  }
}
