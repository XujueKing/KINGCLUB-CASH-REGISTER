import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ccsop_crypto.dart';

class CcsopFailure implements Exception {
  const CcsopFailure(this.code, {this.deliveryUncertain = false});
  final String code;

  /// For commands, query by the business idempotency key before retrying.
  final bool deliveryUncertain;
  @override
  String toString() => 'CcsopFailure($code)';
}

class JsonReply {
  const JsonReply(this.statusCode, this.body);
  final int statusCode;
  final Map<String, dynamic> body;
}

abstract interface class JsonTransport {
  Future<JsonReply> post(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> body,
  );
  void close();
}

/// Bounded, TLS-validated, non-redirecting, non-retrying transport.
class IoJsonTransport implements JsonTransport {
  final _clients = <HttpClient>{};
  final _idle = <HttpClient>[];
  bool _closed = false;
  static const maxBytes = 1024 * 1024;

  @override
  Future<JsonReply> post(
    Uri uri,
    Map<String, String> headers,
    Map<String, dynamic> body, {
    int responseLimit = maxBytes,
  }) async {
    serviceBase(uri.toString());
    if (_closed) throw const CcsopFailure('CLIENT_CLOSED');
    final encoded = utf8.encode(jsonEncode(body));
    if (encoded.length > maxBytes) {
      throw const CcsopFailure('REQUEST_TOO_LARGE');
    }
    final client = _idle.isNotEmpty
        ? _idle.removeLast()
        : (HttpClient()
            ..connectionTimeout = const Duration(seconds: 8)
            ..idleTimeout = const Duration(seconds: 30));
    _clients.add(client);
    var sent = false;
    var reusable = false;
    try {
      return await (() async {
        final request = await client.postUrl(uri);
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        headers.forEach(request.headers.set);
        // Once sent, timeout does NOT mean an order/payment command failed.
        sent = true;
        request.add(encoded);
        final response = await request.close();
        if (response.statusCode >= 300 && response.statusCode < 400) {
          throw const CcsopFailure(
            'REDIRECT_REJECTED',
            deliveryUncertain: true,
          );
        }
        if (response.contentLength > responseLimit) {
          throw const CcsopFailure(
            'RESPONSE_TOO_LARGE',
            deliveryUncertain: true,
          );
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > responseLimit) {
            throw const CcsopFailure(
              'RESPONSE_TOO_LARGE',
              deliveryUncertain: true,
            );
          }
          bytes.addAll(chunk);
        }
        final reply = JsonReply(
          response.statusCode,
          jsonObject(jsonDecode(utf8.decode(bytes))),
        );
        reusable = true;
        return reply;
      })().timeout(const Duration(seconds: 20));
    } on CcsopFailure {
      rethrow;
    } catch (_) {
      // Do not leak URLs, response bodies, payment codes or credentials.
      throw CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: sent);
    } finally {
      _clients.remove(client);
      // An in-flight request owns its client: cancelling it cannot interrupt
      // another request. Only fully consumed responses return to the idle pool.
      if (reusable && !_closed && _idle.length < 4) {
        _idle.add(client);
      } else {
        client.close(force: true);
      }
    }
  }

  @override
  void close() {
    _closed = true;
    for (final client in {..._clients, ..._idle}) {
      client.close(force: true);
    }
    _clients.clear();
    _idle.clear();
  }
}

/// One instance per authenticated employee session and selected service.
/// No member login, token persistence or automatic command retries.
abstract interface class SessionChannel {
  Future<Object?> call(String interfaceId, Map<String, dynamic> params);
  void close();
}

class CcsopClient implements SessionChannel {
  CcsopClient(String base, this._credentials, {JsonTransport? transport})
    : base = serviceBase(base),
      _transport = transport ?? IoJsonTransport();
  final Uri base;
  final CcsopCredentials _credentials;
  final JsonTransport _transport;
  bool _closed = false;

  @override
  Future<Object?> call(String interfaceId, Map<String, dynamic> params) async {
    if (_closed) throw const CcsopFailure('CLIENT_CLOSED');
    final sealed = await sealRequest(
      credentials: _credentials,
      interfaceId: interfaceId,
      params: params,
    );
    if (_closed) throw const CcsopFailure('CLIENT_CLOSED');
    final uri = base.replace(path: '${base.path}/supper-interface');
    // The complete supplier procurement catalogue is ~812 KB before encryption.
    // Keep request limits and other interfaces unchanged; allow its base64 envelope.
    final reply =
        _transport is IoJsonTransport && interfaceId == 'K261006002017'
        ? await _transport.post(
            uri,
            sealed.headers,
            sealed.body,
            responseLimit: 2 * IoJsonTransport.maxBytes,
          )
        : await _transport.post(uri, sealed.headers, sealed.body);
    if (_closed) {
      throw const CcsopFailure('SESSION_CHANGED', deliveryUncertain: true);
    }
    if (reply.statusCode != 200) {
      final code = reply.body['code'];
      // Only machine codes are exposed; never echo server-provided user content.
      final safeCode =
          code is String && RegExp(r'^[A-Z][A-Z0-9_]{0,79}$').hasMatch(code)
          ? code
          : 'SERVICE_REJECTED';
      throw CcsopFailure(safeCode, deliveryUncertain: true);
    }
    try {
      final value = await sealed.openResponse(reply.body);
      if (_closed) {
        throw const CcsopFailure('SESSION_CHANGED', deliveryUncertain: true);
      }
      return value;
    } on CcsopFailure {
      rethrow;
    } catch (_) {
      throw const CcsopFailure(
        'INVALID_SECURE_RESPONSE',
        deliveryUncertain: true,
      );
    }
  }

  @override
  void close() {
    _closed = true;
    _transport.close();
  }
}
