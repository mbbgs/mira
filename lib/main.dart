import 'package:flutter/material.dart';
import 'terminal_screen.dart';

void main() {
  runApp(const DIDEApp());
}

class DIDEApp extends StatelessWidget {
  const DIDEApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DIDE',
      theme: ThemeData.dark(useMaterial3: true),
      home: const HostEntryPage(),
    );
  }
}

// Simple entry screen: type the backend host:port, then open a real
// terminal (xterm2-backed) connected to it over /shell.
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

  void _openTerminal() {
    final host = _hostController.text.trim();
    if (host.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TerminalScreen(host: host),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('DIDE')),
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
              onSubmitted: (_) => _openTerminal(),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _openTerminal,
              child: const Text('Open terminal'),
            ),
          ],
        ),
      ),
    );
  }
}
