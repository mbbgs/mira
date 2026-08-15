import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm2/xterm.dart';
import 'package:xterm2/flutter.dart';

// Real terminal screen: connects to the Go backend's /shell websocket and
// feeds every byte into an xterm2 Terminal(), which does the actual
// ANSI/VT100 parsing (cursor movement, colors, etc.) instead of dumping
// raw escape codes as plain text.
class TerminalScreen extends StatefulWidget {
  final String host;
  const TerminalScreen({super.key, required this.host});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  late final Terminal terminal;
  WebSocketChannel? _channel;
  bool _connected = false;
  String _status = 'disconnected';

  @override
  void initState() {
    super.initState();
    terminal = Terminal(maxLines: 10000);
    _connect();
  }

  void _connect() {
    final uri = Uri.parse('ws://${widget.host}/shell');
    try {
      final channel = WebSocketChannel.connect(uri);
      setState(() {
        _channel = channel;
        _status = 'connecting...';
      });

      // Every keystroke/input the terminal widget produces gets sent
      // straight to the shell over the socket.
      terminal.onOutput = (data) {
        _channel?.sink.add(utf8.encode(data));
      };

      // Terminal resize -> tell the backend so the pty matches, so
      // programs like vim/htop that care about window size behave.
      terminal.onResize = (w, h, pw, ph) {
        final msg = jsonEncode({'type': 'resize', 'cols': w, 'rows': h});
        _channel?.sink.add(msg);
      };

      channel.stream.listen(
        (data) {
          setState(() => _status = 'connected');
          final bytes = data is Uint8List
              ? data
              : data is List<int>
                  ? Uint8List.fromList(data)
                  : Uint8List.fromList(utf8.encode(data.toString()));
          // Feed raw bytes straight into the terminal; xterm2 parses the
          // ANSI escape sequences itself.
          terminal.write(utf8.decode(bytes, allowMalformed: true));
        },
        onError: (err) {
          setState(() {
            _connected = false;
            _status = 'error: $err';
          });
        },
        onDone: () {
          setState(() {
            _connected = false;
            _status = 'disconnected';
          });
        },
      );
      setState(() => _connected = true);
    } catch (e) {
      setState(() => _status = 'connect failed: $e');
    }
  }

  @override
  void dispose() {
    _channel?.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('govin — ${widget.host}'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                _status,
                style: TextStyle(
                  color: _connected ? Colors.greenAccent : Colors.orange,
                  fontSize: 12,
                ),
              ),
            ),
          ),
        ],
      ),
      body: TerminalView(
        terminal,
        autofocus: true,
        backgroundOpacity: 1.0,
      ),
    );
  }
}
