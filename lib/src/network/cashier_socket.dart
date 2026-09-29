import 'dart:async';
import 'dart:io';

abstract interface class CashierSocket {
  Stream<Object?> get messages;
  void send(String message);
  Future<void> close();
}

/// WebSocket.connect currently obtains its upgrade request through openUrl.
/// Only that API is exposed: unsupported client operations fail closed.
class _NoRedirectClient implements HttpClient {
  _NoRedirectClient(this.inner);
  final HttpClient inner;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = await inner.openUrl(method, url);
    request.followRedirects = false;
    return request;
  }

  @override
  void close({bool force = false}) => inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class IoCashierSocket implements CashierSocket {
  IoCashierSocket._(this.socket);
  final WebSocket socket;
  static Future<CashierSocket> connect(Uri uri) async {
    if (uri.scheme != 'wss' || uri.userInfo.isNotEmpty || uri.hasFragment) {
      throw const FormatException('Secure websocket required');
    }
    final client = _NoRedirectClient(
      HttpClient()..connectionTimeout = const Duration(seconds: 8),
    );
    var finished = false;
    try {
      final pending =
          WebSocket.connect(
            uri.toString(),
            customClient: client,
            compression: CompressionOptions.compressionOff,
          ).then((socket) {
            if (finished) {
              unawaited(socket.close().catchError((Object _) {}));
              throw StateError('Connection expired');
            }
            return IoCashierSocket._(socket);
          });
      return await pending.timeout(const Duration(seconds: 10));
    } catch (_) {
      // Exceptions from dart:io may contain the signed URI. Never pass them to UI/logs.
      throw StateError('Realtime connection failed');
    } finally {
      finished = true;
      client.close(force: true);
    }
  }

  @override
  Stream<Object?> get messages => socket;
  @override
  void send(String message) => socket.add(message);
  @override
  Future<void> close() async {
    await socket.close();
  }
}
