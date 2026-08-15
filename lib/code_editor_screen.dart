import 'package:flutter/material.dart';
import 'package:flutter_code_editor/flutter_code_editor.dart';
import 'package:flutter_highlight/themes/monokai-sublime.dart';
import 'package:highlight/languages/go.dart';

// Step 1 of the editor: a real, working Go syntax-highlighting code
// editor widget. Not yet wired to the backend's filesystem or to gopls
// (LSP diagnostics/completion) — those are the next two pieces. This
// screen exists to prove flutter_code_editor itself renders and edits
// correctly on-device before building file I/O on top of it.
class CodeEditorScreen extends StatefulWidget {
  const CodeEditorScreen({super.key});

  @override
  State<CodeEditorScreen> createState() => _CodeEditorScreenState();
}

class _CodeEditorScreenState extends State<CodeEditorScreen> {
  late final CodeController _controller;

  static const _placeholder = '''package main

import "fmt"

func main() {
	fmt.Println("govin editor test")
}
''';

  @override
  void initState() {
    super.initState();
    _controller = CodeController(
      text: _placeholder,
      language: go,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('govin — editor test')),
      body: CodeTheme(
        data: CodeThemeData(styles: monokaiSublimeTheme),
        child: SingleChildScrollView(
          child: CodeField(
            controller: _controller,
            textStyle: const TextStyle(fontFamily: 'monospace', fontSize: 14),
          ),
        ),
      ),
    );
  }
}
