import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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
      home: const ShellTestPage(),
    );
  }
}

// This screen is step 1 only: prove the Flutter app can reach the Go
// backend's /shell websocket over the network and exchange raw bytes.
// No ANSI parsing, no LSP yet — those come after this pipe is confirmed
// working end to end on a real device.
class ShellTestPage extends StatefulWidget {
  const ShellTestPage({super.key});

  @override
  State<ShellTestPage> createState() => _ShellTestPageState();
}

class _ShellTestPageState extends State<ShellTestPage> {
  final TextEditingController _hostController =
      TextEditingController(text: '127.0.0.1:8791');
  final TextEditingController _cmdController = TextEditingController();
  final List<String> _log = [];
  WebSocketChannel? _channel;
  bool _connected = false;

  void _connect() {
    final host = _hostController.text.trim();
    final uri = Uri.parse('ws://$host/shell');
    try {
      final channel = WebSocketChannel.connect(uri);
      setState(() {
        _channel = channel;
        _connected = true;
        _log.add('[connecting to $uri ...]');
      });
      channel.stream.listen(
        (data) {
          // Shell endpoint sends binary frames; decode as UTF-8 for display.
          final text = data is List<int>
              ? utf8.decode(data, allowMalformed: true)
              : data.toString();
          setState(() => _log.add(text));
        },
        onError: (err) {
          setState(() => _log.add('[error: $err]'));
        },
        onDone: () {
          setState(() {
            _connected = false;
            _log.add('[connection closed]');
          });
        },
      );
    } catch (e) {
      setState(() => _log.add('[connect failed: $e]'));
    }
  }

  void _send() {
    final text = _cmdController.text;
    if (text.isEmpty || _channel == null) return;
    _channel!.sink.add(utf8.encode('$text\n'));
    _cmdController.clear();
  }

  void _disconnect() {
    _channel?.sink.close();
    setState(() => _connected = false);
  }

  @override
  void dispose() {
    _channel?.sink.close();
    _hostController.dispose();
    _cmdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('govin — shell pipe test')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _hostController,
                    decoration: const InputDecoration(
                      labelText: 'backend host:port',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _connected ? _disconnect : _connect,
                  child: Text(_connected ? 'Disconnect' : 'Connect'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                color: Colors.black,
                child: SingleChildScrollView(
                  reverse: true,
                  child: Text(
                    _log.join(),
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontFamily: 'monospace',
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _cmdController,
                    enabled: _connected,
                    decoration: const InputDecoration(
                      labelText: 'command',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _connected ? _send : null,
                  child: const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
