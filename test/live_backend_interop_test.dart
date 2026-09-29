import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';
import 'package:kingclub_cash_register/src/live/serving_command.dart';
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
          expect(session.permissions, isNot(contains('orders.serve')));
          final servingScope = <String, dynamic>{
            'storeRef': session.storeRef,
            'tableRef': 'TEST_HTTP_TABLE',
            'sessionRef': 'H00000000001',
            'orderRef': 'D00000000001',
            'productRef': 'TEST_ONLY_PRODUCT',
            'requestId': 'ed029c31-14a9-40b4-a5a3-bbc2c056fa22',
          };
          // Bypass UI guards deliberately: the real server must enforce both.
          await expectLater(
            client.call('K260929001919', {
              ...servingScope,
              'expectedServedQuantity': 0,
              'targetServedQuantity': 1,
            }),
            throwsA(
              isA<CcsopFailure>().having(
                (e) => e.code,
                'code',
                env['CASHIER_TEST_SERVING'] == '1'
                    ? 'CASHIER_PERMISSION_DENIED'
                    : 'CASHIER_SERVING_NOT_ENABLED',
              ),
            ),
          );
          await expectLater(
            client.call('K260929001920', servingScope),
            throwsA(
              isA<CcsopFailure>().having(
                (e) => e.code,
                'code',
                'CASHIER_PERMISSION_DENIED',
              ),
            ),
          );
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
          if ((env['CASHIER_TEST_SERVING_FIXTURE'] ?? '').isNotEmpty) {
            final fixture = jsonDecode(
              env['CASHIER_TEST_SERVING_FIXTURE']!,
            ) as Map<String, dynamic>;
            final servingLogin = await handshake.call('K260929001901', {
              'loginName': 'test-http-only',
              'password': env['CASHIER_TEST_PASSWORD']!,
              'storeRef': fixture['storeRef'],
              'deviceId': env['CASHIER_TEST_DEVICE']!,
            });
            final servingSession = StaffSession.fromServer(
              servingLogin,
              base: base,
              deviceId: env['CASHIER_TEST_DEVICE']!,
              expectedStore: fixture['storeRef'] as String,
            );
            final servingClient = CcsopClient(base, servingSession.credentials);
            try {
              final command = PendingServing.prepare(
                identity: servingSession,
                tableRef: fixture['tableRef'] as String,
                sessionRef: fixture['sessionRef'] as String,
                orderRef: fixture['orderRef'] as String,
                productRef: fixture['productRef'] as String,
                quantity: fixture['quantity'] as int,
                expectedServedQuantity: fixture['servedQuantity'] as int,
                targetServedQuantity: (fixture['servedQuantity'] as int) + 1,
                now: DateTime.now(),
                confirmed: true,
              );
              expect(
                ServingResult.parse(
                  await servingClient.call('K260929001920', command.lookup),
                  command,
                ).confirmed,
                false,
              );
              final results = await Future.wait([
                servingClient.call('K260929001919', command.params),
                servingClient.call('K260929001919', command.params),
              ]);
              for (final result in results) {
                expect(ServingResult.parse(result, command).confirmed, true);
              }
              expect((results[0] as Map)['result'], (results[1] as Map)['result']);
              final recovered = await servingClient.call(
                'K260929001920',
                command.lookup,
              );
              expect(ServingResult.parse(recovered, command).confirmed, true);
              expect((recovered as Map)['result'], (results[0] as Map)['result']);
              await expectLater(
                servingClient.call('K260929001919', {
                  ...command.params,
                  'expectedServedQuantity': 0,
                }),
                throwsA(
                  isA<CcsopFailure>().having(
                    (e) => e.code,
                    'code',
                    'ORDERING_SERVING_REQUEST_CONFLICT',
                  ),
                ),
              );
              final stale = PendingServing.prepare(
                identity: servingSession,
                tableRef: command.tableRef,
                sessionRef: command.sessionRef,
                orderRef: command.orderRef,
                productRef: command.productRef,
                quantity: command.quantity,
                expectedServedQuantity: command.before,
                targetServedQuantity: command.after,
                now: DateTime.now(),
                confirmed: true,
              );
              await expectLater(
                servingClient.call('K260929001919', stale.params),
                throwsA(
                  isA<CcsopFailure>().having(
                    (e) => e.code,
                    'code',
                    'ORDERING_SERVING_REVISION_CONFLICT',
                  ),
                ),
              );
              await servingClient.call('K260929001904', {});
            } finally {
              servingClient.close();
            }
          }
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
