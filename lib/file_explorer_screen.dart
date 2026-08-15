import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'code_editor_screen.dart';
import 'terminal_screen.dart';

class FileEntry {
  final String name;
  final String path;
  final bool isDir;
  FileEntry({required this.name, required this.path, required this.isDir});

  factory FileEntry.fromJson(Map<String, dynamic> j) => FileEntry(
        name: j['name'] as String,
        path: j['path'] as String,
        isDir: j['isDir'] as bool,
      );
}

// Home screen: file explorer, reached via GET /files/list on the backend.
// Side drawer gives access to the terminal and (later) other utilities.
// Tapping a file loads it (GET /files/read) straight into the code editor
// — no manual "connect" step anywhere in this flow.
class FileExplorerScreen extends StatefulWidget {
  final String host;
  const FileExplorerScreen({super.key, required this.host});

  @override
  State<FileExplorerScreen> createState() => _FileExplorerScreenState();
}

class _FileExplorerScreenState extends State<FileExplorerScreen> {
  String? _currentPath; // null = let backend default to $HOME
  List<FileEntry> _entries = [];
  bool _loading = true;
  String? _error;
  final List<String> _pathStack = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final uri = Uri.parse('http://${widget.host}/files/list').replace(
        queryParameters:
            _currentPath != null ? {'path': _currentPath!} : null,
      );
      final resp = await http.get(uri);
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      _currentPath = body['path'] as String;
      final entries = (body['entries'] as List)
          .map((e) => FileEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      setState(() {
        _entries = entries;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _openDir(FileEntry entry) {
    _pathStack.add(_currentPath!);
    _currentPath = entry.path;
    _load();
  }

  void _goUp() {
    if (_pathStack.isEmpty) return;
    _currentPath = _pathStack.removeLast();
    _load();
  }

  Future<void> _openFile(FileEntry entry) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CodeEditorScreen(
          host: widget.host,
          filePath: entry.path,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentPath ?? 'govin', overflow: TextOverflow.ellipsis),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest),
              child: const Align(
                alignment: Alignment.bottomLeft,
                child: Text('govin', style: TextStyle(fontSize: 24)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Files'),
              selected: true,
              onTap: () => Navigator.pop(context),
            ),
            ListTile(
              leading: const Icon(Icons.terminal),
              title: const Text('Terminal'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TerminalScreen(host: widget.host),
                  ),
                );
              },
            ),
          ],
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Could not load files:\n$_error',
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              ElevatedButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    return ListView(
      children: [
        if (_pathStack.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.arrow_upward),
            title: const Text('..'),
            onTap: _goUp,
          ),
        for (final entry in _entries)
          ListTile(
            leading: Icon(entry.isDir ? Icons.folder : Icons.insert_drive_file),
            title: Text(entry.name),
            onTap: () => entry.isDir ? _openDir(entry) : _openFile(entry),
          ),
        if (_entries.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('Empty folder')),
          ),
      ],
    );
  }
}
