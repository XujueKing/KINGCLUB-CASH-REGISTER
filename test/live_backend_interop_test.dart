import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';
import 'package:kingclub_cash_register/src/network/cashier_socket.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/network/ccsop_handshake.dart';
import 'package:kingclub_cash_register/src/network/ccsop_realtime_codec.dart';

// Test-only trust root. No badCertificateCallback or production transport changes.
class TestCertificateTrust extends HttpOverrides {
  TestCertificateTrust(this.context);
  final SecurityContext context;
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context ?? this.context);
}

void main() {
  final env = Platform.environment;
  test(
    'real TLS backend: Dart handshake, staff projection, workbench, WSS and rotation',
    () async {
      final base = env['CASHIER_TEST_BASE']!;
      final uri = Uri.parse(base);
      expect(uri.scheme, 'https');
      expect(uri.host, '127.0.0.1');
      expect(uri.path, isEmpty);
      final untrusted = IoJsonTransport();
      try {
        await expectLater(
          untrusted.post(uri.replace(path: '/supper-handshake'), {}, {}),
          throwsA(
            isA<CcsopFailure>().having(
              (e) => e.code,
              'code',
              'TRANSPORT_FAILED',
            ),
          ),
        );
      } finally {
        untrusted.close();
      }
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(env['CASHIER_TEST_CERT']!);
      await HttpOverrides.runWithHttpOverrides(() async {
        final handshake = CcsopHandshakeClient(base);
        CcsopClient? client, renewedClient;
        CashierSocket? socket;
        StreamIterator<Object?>? messages;
        CcsopRealtimeCodec? codec;
        try {
          final login = await handshake.call('K260929001901', {
            'loginName': 'test-http-only',
            'password': env['CASHIER_TEST_PASSWORD']!,
            'storeRef': 'TEST_HTTP_STORE',
            'deviceId': env['CASHIER_TEST_DEVICE']!,
          });
          final session = StaffSession.fromServer(
            login,
            base: base,
            deviceId: env['CASHIER_TEST_DEVICE']!,
            expectedStore: 'TEST_HTTP_STORE',
          );
          expect(session.employeeRef, 'E00000000008');
          client = CcsopClient(base, session.credentials);
          final workbench = TableSnapshot.parse(
            await client.call('K260929001902', {'storeRef': session.storeRef}),
            storeRef: session.storeRef,
            employeeRef: session.employeeRef,
          );
          expect(workbench.tables.single.reference, 'TEST_HTTP_TABLE');
          expect(workbench.tables.single.name, 'TEST COMMITTED');
          codec = CcsopRealtimeCodec(
            session.credentials,
            'store:${session.storeRef}',
            endpoint: '/cashier/ws',
          );
          socket = await IoCashierSocket.connect(
            await codec.connectionUri(base),
          );
          messages = StreamIterator(socket.messages);
          expect(
            await messages.moveNext().timeout(const Duration(seconds: 8)),
            true,
          );
          expect(
            (await codec.decode(messages.current as String))['eventType'],
            'connection.ready',
          );
          socket.send(await codec.encode('ping', {}));
          expect(
            await messages.moveNext().timeout(const Duration(seconds: 8)),
            true,
          );
          expect(
            (await codec.decode(messages.current as String))['eventType'],
            'pong',
          );
          final refreshed = await handshake.call(
            'K260929001903',
            session.refreshRequest(),
          );
          final next = StaffSession.fromServer(
            refreshed,
            base: base,
            deviceId: session.deviceId,
            expectedStore: session.storeRef,
          );
          await expectLater(
            client.call('K260929001902', {'storeRef': session.storeRef}),
            throwsA(
              isA<CcsopFailure>().having(
                (e) => e.code,
                'code',
                'INVALID_SIGNATURE',
              ),
            ),
          );
          socket.send(await codec.encode('ping', {}));
          expect(
            await messages.moveNext().timeout(const Duration(seconds: 8)),
            false,
          );
          renewedClient = CcsopClient(base, next.credentials);
          final read = TableSnapshot.parse(
            await renewedClient.call('K260929001902', {
              'storeRef': next.storeRef,
            }),
            storeRef: next.storeRef,
            employeeRef: next.employeeRef,
          );
          expect(read.tables.single.reference, 'TEST_HTTP_TABLE');
          await renewedClient.call('K260929001904', {});
          await expectLater(
            renewedClient.call('K260929001902', {'storeRef': next.storeRef}),
            throwsA(
              isA<CcsopFailure>().having(
                (e) => e.code,
                'code',
                'SESSION_EXPIRED',
              ),
            ),
          );
        } finally {
          await messages?.cancel();
          await socket?.close();
          codec?.close();
          renewedClient?.close();
          client?.close();
          handshake.close();
        }
      }, TestCertificateTrust(trust));
    },
    skip: env['CASHIER_TEST_BASE'] == null
        ? 'Requires isolated Redis/MySQL/TLS harness'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
