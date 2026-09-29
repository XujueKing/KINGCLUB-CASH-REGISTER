import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/table_clear_command.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/network/ccsop_handshake.dart';

import 'live_backend_interop_test.dart' show TestCertificateTrust;

void main() {
  final env = Platform.environment;
  test(
    'real HTTPS table clear and historical original receipt',
    () async {
      final base = env['CASHIER_TEST_BASE']!;
      final uri = Uri.parse(base);
      expect(uri.scheme, 'https');
      expect(uri.host, '127.0.0.1');
      expect(uri.path, isEmpty);
      final fixture = jsonDecode(
        env['CASHIER_TEST_TABLE_CLEAR_FIXTURE']!,
      ) as Map<String, dynamic>;
      expect(fixture['storeRef'], 'TEST_STORE');
      expect(fixture['tableRef'], 'TEST_TLS_CLEAR');
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(env['CASHIER_TEST_CERT']!);
      await HttpOverrides.runWithHttpOverrides(() async {
        final handshake = CcsopHandshakeClient(base);
        CcsopClient? client;
        try {
          final login = await handshake.call('K260929001901', {
            'loginName': 'test-http-only',
            'password': env['CASHIER_TEST_PASSWORD']!,
            'storeRef': fixture['storeRef'],
            'deviceId': env['CASHIER_TEST_DEVICE']!,
          });
          final session = StaffSession.fromServer(
            login,
            base: base,
            deviceId: env['CASHIER_TEST_DEVICE']!,
            expectedStore: fixture['storeRef'] as String,
          );
          expect(session.employeeRef, 'E00000000008');
          expect(session.permissions, contains('table.clear'));
          client = CcsopClient(base, session.credentials);
          final prepared = PendingTableClear.prepare(
            identity: session,
            tableRef: fixture['tableRef'] as String,
            sessionRef: fixture['sessionRef'] as String,
            now: DateTime.now(),
            confirmed: true,
          );
          // Fixed TEST_ONLY request ID lets a separate Dart process recover the original.
          final command = PendingTableClear.decode({
            ...prepared.encode(),
            'params': {...prepared.params, 'requestId': fixture['requestId']},
          });
          Matcher denied(String code) =>
              throwsA(isA<CcsopFailure>().having((e) => e.code, 'code', code));
          if (fixture['nextSessionRef'] == null) {
            expect(
              TableClearResult.parse(
                await client.call('K260929001922', command.lookup),
                command,
              ).confirmed,
              false,
            );
            final results = await Future.wait([
              client.call('K260929001921', command.params),
              client.call('K260929001921', command.params),
            ]);
            for (final raw in results) {
              final result = TableClearResult.parse(raw, command);
              expect(result.confirmed, true);
              expect(result.receipt!['paidOrderCount'], 1);
              expect(result.receipt!['settledCents'], 200);
              expect(result.receipt!['departedSeatCount'], 1);
            }
            expect(
              (results[0] as Map)['result'],
              (results[1] as Map)['result'],
            );
            final recovered = await client.call(
              'K260929001922',
              command.lookup,
            );
            expect(TableClearResult.parse(recovered, command).confirmed, true);
            expect((recovered as Map)['result'], (results[0] as Map)['result']);
            // New HTTP encryption envelope, new business request ID, same closed session must fail.
            await expectLater(
              client.call('K260929001921', prepared.params),
              denied('TABLE_CLEAR_STATE_CHANGED'),
            );
            await expectLater(
              client.call('K260929001921', {
                ...command.params,
                'tableRef': 'OTHER_TEST_TABLE',
              }),
              denied('TABLE_CLEAR_REQUEST_CONFLICT'),
            );
          } else {
            // A second process and employee session can recover the historical command.
            final recovered = TableClearResult.parse(
              await client.call('K260929001922', command.lookup),
              command,
            );
            expect(recovered.confirmed, true);
            expect(recovered.receipt, fixture['expectedReceipt']);
            final replay = TableClearResult.parse(
              await client.call('K260929001921', command.params),
              command,
            );
            expect(replay.receipt, recovered.receipt);
            await expectLater(
              client.call('K260929001921', {
                ...command.params,
                'sessionRef': fixture['nextSessionRef'],
              }),
              denied('TABLE_CLEAR_REQUEST_CONFLICT'),
            );
          }
          await client.call('K260929001904', {});
        } finally {
          client?.close();
          handshake.close();
        }
      }, TestCertificateTrust(trust));
    },
    skip: env['CASHIER_TEST_TABLE_CLEAR_FIXTURE'] == null
        ? 'Requires isolated paid-session MySQL/Redis/TLS fixture'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
