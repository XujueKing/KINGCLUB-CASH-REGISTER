import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

class Headers implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class Response extends Stream<List<int>> implements HttpClientResponse {
  Response(this.body);
  final String body;
  @override
  int get statusCode => 200;
  @override
  int get contentLength => utf8.encode(body).length;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Request implements HttpClientRequest {
  Request(this.client);
  final Client client;
  @override
  final headers = Headers();
  @override
  Future<HttpClientResponse> close() async =>
      client.gate?.future ?? Response(client.body);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class Client implements HttpClient {
  bool closed = false;
  String body = '{}';
  Completer<HttpClientResponse>? gate;
  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    if (closed) throw StateError('closed');
    return Request(this);
  }

  @override
  void close({bool force = false}) => closed = true;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class Clients extends HttpOverrides {
  final created = <Client>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = Client();
    created.add(client);
    return client;
  }
}

void main() {
  final uri = Uri.parse('https://service.invalid/supper');
  test('large inventory envelope is bounded separately from default replies and requests', () async {
    final clients = Clients();
    await HttpOverrides.runWithHttpOverrides(() async {
      final transport = IoJsonTransport();
      await transport.post(uri, {}, {});
      clients.created.single.body = jsonEncode({
        'data': 'a' * (IoJsonTransport.maxBytes + 20),
      });
      await expectLater(
        transport.post(uri, {}, {}),
        throwsA(
          isA<CcsopFailure>().having(
            (e) => e.code,
            'code',
            'RESPONSE_TOO_LARGE',
          ),
        ),
      );
      await transport.post(uri, {}, {});
      clients.created.last.body = jsonEncode({
        'data': 'a' * (IoJsonTransport.maxBytes + 20),
      });
      await transport.post(
        uri,
        {},
        {},
        responseLimit: 2 * IoJsonTransport.maxBytes,
      );
      clients.created.last.body = jsonEncode({
        'data': 'a' * (2 * IoJsonTransport.maxBytes),
      });
      await expectLater(
        transport.post(
          uri,
          {},
          {},
          responseLimit: 2 * IoJsonTransport.maxBytes,
        ),
        throwsA(
          isA<CcsopFailure>().having(
            (e) => e.code,
            'code',
            'RESPONSE_TOO_LARGE',
          ),
        ),
      );
      await expectLater(
        transport.post(uri, {}, {
          'data': 'a' * IoJsonTransport.maxBytes,
        }, responseLimit: 2 * IoJsonTransport.maxBytes),
        throwsA(
          isA<CcsopFailure>().having(
            (e) => e.code,
            'code',
            'REQUEST_TOO_LARGE',
          ),
        ),
      );
      transport.close();
    }, clients);
  });
  test(
    'completed reads reuse a client; logout closes it and forbids reuse',
    () async {
      final clients = Clients();
      await HttpOverrides.runWithHttpOverrides(() async {
        final transport = IoJsonTransport();
        await transport.post(uri, {}, {});
        await transport.post(uri, {}, {});
        expect(clients.created, hasLength(1));
        expect(clients.created.single.closed, isFalse);
        transport.close();
        expect(clients.created.single.closed, isTrue);
        await expectLater(
          transport.post(uri, {}, {}),
          throwsA(isA<CcsopFailure>()),
        );
      }, clients);
    },
  );
  test(
    'malformed responses discard their connection without retrying',
    () async {
      final clients = Clients();
      await HttpOverrides.runWithHttpOverrides(() async {
        final transport = IoJsonTransport();
        await transport.post(uri, {}, {});
        clients.created.single.body = 'invalid json';
        await expectLater(
          transport.post(uri, {}, {}),
          throwsA(isA<CcsopFailure>()),
        );
        expect(clients.created, hasLength(1));
        expect(clients.created.single.closed, isTrue);
        await transport.post(uri, {}, {});
        expect(clients.created, hasLength(2));
        transport.close();
      }, clients);
    },
  );
  test('concurrent calls own separate clients; closing cancels both', () async {
    final clients = Clients();
    await HttpOverrides.runWithHttpOverrides(() async {
      final transport = IoJsonTransport();
      await transport.post(uri, {}, {});
      final gate = Completer<HttpClientResponse>();
      clients.created.single.gate = gate;
      final pending = transport.post(uri, {}, {});
      await transport.post(uri, {}, {});
      expect(clients.created, hasLength(2));
      transport.close();
      expect(clients.created.every((client) => client.closed), isTrue);
      gate.complete(Response('{}'));
      await pending;
      expect(clients.created.every((client) => client.closed), isTrue);
    }, clients);
  });
}
