import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/network/cashier_realtime_client.dart';
import 'package:kingclub_cash_register/src/network/cashier_socket.dart';
import 'package:kingclub_cash_register/src/network/ccsop_crypto.dart';

import 'support/realtime_fixture.dart';

Future<void> until(bool Function() predicate) async {
  for (var i = 0; i < 250 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue);
}

void main() {
  test('Store URI preserves proxy prefix, signature binds cashier path, ready and event invalidate once each', () async {
    final session = realtimeSession(), socket = TestCashierSocket();
    Uri? uri;
    final client = CashierRealtimeClient(
      session,
      connect: (value) async {
        uri = value;
        return socket;
      },
    );
    addTearDown(client.dispose);
    client.start();
    await until(() => uri != null);
    expect(uri!.scheme, 'wss');
    expect(uri!.path, '/prefix/cashier/ws');
    expect(uri!.queryParameters['clientId'], 'store:test-store');
    final q = uri!.queryParameters;
    final canonical = [
      'GET',
      '/cashier/ws',
      q['apiKeyId'],
      q['sessionId'],
      q['timestamp'],
      q['nonce'],
      q['requestId'],
      await sha256Hex('store:test-store'),
    ].join('\n');
    expect(
      q['sign'],
      await sign(
        await derive(
          session.credentials.key,
          '${q['timestamp']}:${q['nonce']}',
          'ccsop:websocket:sign:${q['requestId']}',
        ),
        canonical,
      ),
    );
    socket.inbound.add(
      await serverFrame(session, uri!, 1, 'connection.ready', {
        'storeRef': 'test-store',
      }),
    );
    await until(() => client.state == CashierRealtimeState.connected);
    expect(client.revision, 1);
    socket.inbound.add(
      await serverFrame(session, uri!, 2, 'commerce.changed', {
        'storeRef': 'test-store',
        'topic': 'orders',
      }),
    );
    await until(() => client.revision == 2);
    client.stop();
    expect(socket.closed, isTrue);
    expect(client.state, CashierRealtimeState.offline);
  });
  test('Bad store, replay, sequence gap and unsupported event close instead of mutating state', () async {
    for (final reason in ['store', 'replay', 'gap', 'event']) {
      final session = realtimeSession(), socket = TestCashierSocket();
      Uri? uri;
      final client = CashierRealtimeClient(
        session,
        connect: (value) async {
          uri = value;
          return socket;
        },
      );
      client.start();
      await until(() => uri != null);
      socket.inbound.add(
        await serverFrame(session, uri!, 1, 'connection.ready', {
          'storeRef': 'test-store',
        }),
      );
      await until(() => client.state == CashierRealtimeState.connected);
      socket.inbound.add(
        await serverFrame(
          session,
          uri!,
          reason == 'replay'
              ? 1
              : reason == 'gap'
              ? 3
              : 2,
          reason == 'event' ? 'payment.success' : 'commerce.changed',
          {
            'storeRef': reason == 'store' ? 'other' : 'test-store',
            'topic': 'tables',
          },
        ),
      );
      await until(() => socket.closed);
      expect(client.revision, 1, reason: reason);
      client.dispose();
    }
  });
  test(
    'A socket arriving after stop is closed without publishing ready state',
    () async {
      final session = realtimeSession(), socket = TestCashierSocket();
      final gate = Completer<CashierSocket>();
      var requested = false;
      final client = CashierRealtimeClient(
        session,
        connect: (_) {
          requested = true;
          return gate.future;
        },
      );
      addTearDown(client.dispose);
      client.start();
      await until(() => requested);
      client.stop();
      gate.complete(socket);
      await until(() => socket.closed);
      expect(client.revision, 0);
      expect(client.state, CashierRealtimeState.offline);
    },
  );
  test(
    'Reconnect uses fresh nonce and request id; expired session does not dial',
    () async {
      final session = realtimeSession();
      final uris = <Uri>[];
      final sockets = <TestCashierSocket>[];
      final client = CashierRealtimeClient(
        session,
        connect: (uri) async {
          uris.add(uri);
          final socket = TestCashierSocket();
          sockets.add(socket);
          return socket;
        },
      );
      addTearDown(client.dispose);
      client.start();
      await until(() => sockets.isNotEmpty);
      await sockets.first.inbound.close();
      await until(() => sockets.length == 2);
      expect(
        uris.first.queryParameters['nonce'],
        isNot(uris.last.queryParameters['nonce']),
      );
      expect(
        uris.first.queryParameters['requestId'],
        isNot(uris.last.queryParameters['requestId']),
      );
      final expired = CashierRealtimeClient(
        session,
        now: () => session.expiresAt,
        connect: (_) async => throw StateError('must not dial'),
      );
      expired.start();
      expect(expired.state, CashierRealtimeState.offline);
      expired.dispose();
    },
  );
}
