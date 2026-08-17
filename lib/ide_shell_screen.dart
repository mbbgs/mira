import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'editor_pane.dart';
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

class _OpenTab {
  final String path;
  final GlobalKey<EditorPaneState> key = GlobalKey<EditorPaneState>();
  String lspStatus = 'connecting...';
  int problemCount = 0;
  _OpenTab(this.path);

  String get name => path.split('/').last;
}

/// Main IDE shell: a narrow file tree on the left, a tab bar + editor on
/// the right, both visible at once — this is the real "VS Code on phone"
/// layout. Tapping a file in the tree opens (or focuses) a tab; multiple
/// files can be open simultaneously, each with its own EditorPane (and
/// therefore its own LSP session).
class IdeShellScreen extends StatefulWidget {
  final String host;
  const IdeShellScreen({super.key, required this.host});

  @override
  State<IdeShellScreen> createState() => _IdeShellScreenState();
}

class _IdeShellScreenState extends State<IdeShellScreen>
    with TickerProviderStateMixin {
  String? _currentPath;
  List<FileEntry> _entries = [];
  bool _loadingTree = true;
  String? _treeError;
  final List<String> _pathStack = [];

  final List<_OpenTab> _tabs = [];
  TabController? _tabController;

  @override
  void initState() {
    super.initState();
    _loadTree();
  }

  Future<void> _loadTree() async {
    setState(() {
      _loadingTree = true;
      _treeError = null;
    });
    try {
      final uri = Uri.parse('http://${widget.host}/files/list').replace(
        queryParameters: _currentPath != null ? {'path': _currentPath!} : null,
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
        _loadingTree = false;
      });
    } catch (e) {
      setState(() {
        _treeError = e.toString();
        _loadingTree = false;
      });
    }
  }

  void _openDir(FileEntry entry) {
    _pathStack.add(_currentPath!);
    _currentPath = entry.path;
    _loadTree();
  }

  void _goUp() {
    if (_pathStack.isEmpty) return;
    _currentPath = _pathStack.removeLast();
    _loadTree();
  }

  void _openFile(FileEntry entry) {
    final existingIndex = _tabs.indexWhere((t) => t.path == entry.path);
    if (existingIndex != -1) {
      _tabController?.animateTo(existingIndex);
      return;
    }
    setState(() {
      _tabs.add(_OpenTab(entry.path));
      _rebuildTabController(initialIndex: _tabs.length - 1);
    });
  }

  void _closeTab(int index) {
    setState(() {
      _tabs.removeAt(index);
      final newIndex = index >= _tabs.length ? _tabs.length - 1 : index;
      _rebuildTabController(initialIndex: newIndex < 0 ? 0 : newIndex);
    });
  }

  void _rebuildTabController({required int initialIndex}) {
    _tabController?.dispose();
    if (_tabs.isEmpty) {
      _tabController = null;
      return;
    }
    _tabController = TabController(
      length: _tabs.length,
      vsync: this,
      initialIndex: initialIndex.clamp(0, _tabs.length - 1),
    );
  }

  void _saveCurrentTab() {
    if (_tabController == null || _tabs.isEmpty) return;
    final tab = _tabs[_tabController!.index];
    tab.key.currentState?.save();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasOpenTabs = _tabs.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Text(
          hasOpenTabs ? _breadcrumb(_tabs[_tabController!.index].path) : 'govin',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (hasOpenTabs) ...[
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Text(
                  'lsp: ${_tabs[_tabController!.index].lspStatus}',
                  style: TextStyle(
                    fontSize: 11,
                    color: _tabs[_tabController!.index].lspStatus == 'connected'
                        ? Colors.greenAccent
                        : Colors.orange,
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _saveCurrentTab,
            ),
          ],
          IconButton(
            icon: const Icon(Icons.terminal),
            tooltip: 'Terminal',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TerminalScreen(host: widget.host),
                ),
              );
            },
          ),
        ],
        bottom: hasOpenTabs
            ? PreferredSize(
                preferredSize: const Size.fromHeight(36),
                child: _TabStrip(
                  tabs: _tabs,
                  controller: _tabController!,
                  onClose: _closeTab,
                ),
              )
            : null,
      ),
      // File tree is a slide-over drawer (swipe from left edge, or tap the
      // menu icon) instead of a persistent side panel — it covers the
      // editor while open and disappears once a file is picked, so it
      // never eats screen space while you're actually editing.
      drawer: Drawer(
        width: MediaQuery.of(context).size.width * 0.85,
        child: SafeArea(
          child: _FileTree(
            currentPath: _currentPath,
            entries: _entries,
            loading: _loadingTree,
            error: _treeError,
            canGoUp: _pathStack.isNotEmpty,
            onGoUp: _goUp,
            onOpenDir: _openDir,
            onOpenFile: (entry) {
              _openFile(entry);
              Navigator.of(context).pop(); // close drawer after picking a file
            },
            onRetry: _loadTree,
          ),
        ),
      ),
      body: hasOpenTabs
          ? TabBarView(
              controller: _tabController,
              physics: const NeverScrollableScrollPhysics(),
              children: _tabs
                  .map(
                    (tab) => EditorPane(
                      key: tab.key,
                      host: widget.host,
                      filePath: tab.path,
                      onLspStatus: (status) {
                        setState(() => tab.lspStatus = status);
                      },
                      onDiagnosticsCount: (count) {
                        setState(() => tab.problemCount = count);
                      },
                    ),
                  )
                  .toList(),
            )
          : const Center(
              child: Text(
                'Open a file from the tree to start editing',
                style: TextStyle(color: Colors.grey),
              ),
            ),
    );
  }

  String _breadcrumb(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length <= 2) return parts.join(' › ');
    return parts.sublist(parts.length - 2).join(' › ');
  }
}

class _TabStrip extends StatelessWidget {
  final List<_OpenTab> tabs;
  final TabController controller;
  final void Function(int index) onClose;

  const _TabStrip({
    required this.tabs,
    required this.controller,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: tabs.length,
        itemBuilder: (context, i) {
          final tab = tabs[i];
          final selected = controller.index == i;
          return InkWell(
            onTap: () => controller.animateTo(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: selected
                    ? Theme.of(context).colorScheme.surfaceContainerHighest
                    : null,
                border: Border(
                  bottom: BorderSide(
                    color: selected ? Colors.tealAccent : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tab.problemCount > 0) ...[
                    const Icon(Icons.error, size: 12, color: Colors.redAccent),
                    const SizedBox(width: 4),
                  ],
                  Text(tab.name, style: const TextStyle(fontSize: 12)),
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: () => onClose(i),
                    child: const Icon(Icons.close, size: 14),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _FileTree extends StatelessWidget {
  final String? currentPath;
  final List<FileEntry> entries;
  final bool loading;
  final String? error;
  final bool canGoUp;
  final VoidCallback onGoUp;
  final void Function(FileEntry) onOpenDir;
  final void Function(FileEntry) onOpenFile;
  final VoidCallback onRetry;

  const _FileTree({
    required this.currentPath,
    required this.entries,
    required this.loading,
    required this.error,
    required this.canGoUp,
    required this.onGoUp,
    required this.onOpenDir,
    required this.onOpenFile,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 20, color: Colors.redAccent),
              const SizedBox(height: 4),
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        if (canGoUp)
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: const Icon(Icons.arrow_upward, size: 16),
            title: const Text('..', style: TextStyle(fontSize: 12)),
            onTap: onGoUp,
          ),
        for (final entry in entries)
          ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: Icon(
              entry.isDir ? Icons.folder : Icons.insert_drive_file,
              size: 16,
              color: entry.isDir ? Colors.amber : Colors.grey.shade400,
            ),
            title: Text(
              entry.name,
              style: const TextStyle(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => entry.isDir ? onOpenDir(entry) : onOpenFile(entry),
          ),
      ],
    );
  }
}
