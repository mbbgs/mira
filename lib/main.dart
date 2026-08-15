import 'package:flutter/material.dart';
import 'ide_shell_screen.dart';

void main() {
  runApp(const GovinApp());
}

class GovinApp extends StatelessWidget {
  const GovinApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'govin',
      theme: ThemeData.dark(useMaterial3: true),
      home: const HostEntryPage(),
    );
  }
}

// One-time host entry, then straight into the IDE shell: file tree +
// tabs + editor, all visible together.
class HostEntryPage extends StatefulWidget {
  const HostEntryPage({super.key});

  @override
  State<HostEntryPage> createState() => _HostEntryPageState();
}

class _HostEntryPageState extends State<HostEntryPage> {
  final TextEditingController _hostController =
      TextEditingController(text: '127.0.0.1:8791');

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  void _open() {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => IdeShellScreen(host: host),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('govin')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _hostController,
              decoration: const InputDecoration(
                labelText: 'backend host:port',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _open(),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _open,
              child: const Text('Open project'),
            ),
          ],
        ),
      ),
    );
  }
}
