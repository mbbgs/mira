import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:web_socket_channel/web_socket_channel.dart';

// A minimal real LSP client speaking JSON-RPC 2.0 over the raw byte
// stream gopls sends/expects. LSP frames look like:
//
//   Content-Length: 123\r\n
//   \r\n
//   {"jsonrpc":"2.0",...}
//
// gopls does not send anything unsolicited on connect — the client MUST
// send an `initialize` request first, then an `initialized` notification,
// before any other messages are meaningful. This class implements exactly
// that handshake plus basic request/response + diagnostics handling.
class LspClient {
  final WebSocketChannel channel;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  int _nextId = 1;
  final _buffer = BytesBuilder();
  bool _initialized = false;

  final void Function(String status)? onStatus;
  final void Function(String uri, List<dynamic> diagnostics)? onDiagnostics;

  LspClient(this.channel, {this.onStatus, this.onDiagnostics}) {
    channel.stream.listen(
      _onData,
      onError: (e) => onStatus?.call('error: $e'),
      onDone: () => onStatus?.call('disconnected'),
    );
  }

  Future<void> initialize({required String rootUri}) async {
    onStatus?.call('handshaking...');
    final result = await _request('initialize', {
      'processId': null,
      'rootUri': rootUri,
      'capabilities': {
        'textDocument': {
          'synchronization': {'didSave': true},
          'publishDiagnostics': {},
        },
      },
    });
    // Server responded to initialize — now send the required
    // 'initialized' notification (no response expected for this one).
    _notify('initialized', {});
    _initialized = true;
    onStatus?.call('connected');
    // result is the server's capabilities; not used yet, but confirms
    // the handshake completed rather than just assuming.
    // ignore: unnecessary_statements
    result;
  }

  void didOpen(String uri, String languageId, String text) {
    if (!_initialized) return;
    _notify('textDocument/didOpen', {
      'textDocument': {
        'uri': uri,
        'languageId': languageId,
        'version': 1,
        'text': text,
      },
    });
  }

  void didChange(String uri, int version, String fullText) {
    if (!_initialized) return;
    _notify('textDocument/didChange', {
      'textDocument': {'uri': uri, 'version': version},
      'contentChanges': [
        {'text': fullText}
      ],
    });
  }

  void didSave(String uri) {
    if (!_initialized) return;
    _notify('textDocument/didSave', {
      'textDocument': {'uri': uri},
    });
  }

  void dispose() {
    channel.sink.close();
  }

  // --- wire protocol plumbing ---

  int _idCounter() => _nextId++;

  Future<Map<String, dynamic>> _request(
      String method, Map<String, dynamic> params) {
    final id = _idCounter();
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return completer.future;
  }

  void _notify(String method, Map<String, dynamic> params) {
    _send({'jsonrpc': '2.0', 'method': method, 'params': params});
  }

  void _send(Map<String, dynamic> message) {
    final json = jsonEncode(message);
    final bodyBytes = utf8.encode(json);
    final header = 'Content-Length: ${bodyBytes.length}\r\n\r\n';
    final frame = BytesBuilder()
      ..add(utf8.encode(header))
      ..add(bodyBytes);
    channel.sink.add(frame.toBytes());
  }

  void _onData(dynamic data) {
    final bytes = data is List<int>
        ? Uint8List.fromList(data)
        : Uint8List.fromList(utf8.encode(data.toString()));
    _buffer.add(bytes);
    _drainBuffer();
  }

  void _drainBuffer() {
    while (true) {
      final all = _buffer.toBytes();
      final headerEnd = _findHeaderEnd(all);
      if (headerEnd == -1) return; // haven't received full header yet

      final headerText = utf8.decode(all.sublist(0, headerEnd));
      final contentLength = _parseContentLength(headerText);
      if (contentLength == null) {
        // Malformed header we can't recover from cleanly; drop buffer.
        _buffer.clear();
        return;
      }

      final bodyStart = headerEnd + 4; // skip \r\n\r\n
      final bodyEnd = bodyStart + contentLength;
      if (all.length < bodyEnd) return; // body not fully received yet

      final bodyBytes = all.sublist(bodyStart, bodyEnd);
      final remaining = all.sublist(bodyEnd);
      _buffer.clear();
      _buffer.add(remaining);

      try {
        final msg = jsonDecode(utf8.decode(bodyBytes)) as Map<String, dynamic>;
        _handleMessage(msg);
      } catch (_) {
        // Ignore unparseable frame rather than crash the stream.
      }
    }
  }

  int _findHeaderEnd(Uint8List bytes) {
    for (int i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  int? _parseContentLength(String header) {
    for (final line in header.split('\r\n')) {
      final parts = line.split(':');
      if (parts.length == 2 &&
          parts[0].trim().toLowerCase() == 'content-length') {
        return int.tryParse(parts[1].trim());
      }
    }
    return null;
  }

  void _handleMessage(Map<String, dynamic> msg) {
    if (msg.containsKey('id') && (msg.containsKey('result') || msg.containsKey('error'))) {
      // response to one of our requests
      final id = msg['id'];
      final completer = _pending.remove(id is int ? id : int.tryParse('$id'));
      if (completer == null) return;
      if (msg.containsKey('error')) {
        completer.completeError(Exception(msg['error'].toString()));
      } else {
        completer.complete((msg['result'] as Map?)?.cast<String, dynamic>() ?? {});
      }
      return;
    }

    // server-initiated notification
    final method = msg['method'] as String?;
    if (method == 'textDocument/publishDiagnostics') {
      final params = msg['params'] as Map<String, dynamic>?;
      if (params != null) {
        onDiagnostics?.call(
          params['uri'] as String? ?? '',
          params['diagnostics'] as List<dynamic>? ?? [],
        );
      }
    }
    // Other notifications (window/logMessage, $/progress, etc.) are
    // ignored for now — not needed for basic diagnostics support.
  }
}
