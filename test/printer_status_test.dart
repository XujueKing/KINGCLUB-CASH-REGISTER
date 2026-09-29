import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/printer_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cn.kingclub.cashier/printer-status');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('raw codes including unknown future codes survive without readiness inference', () {
    for (final status in [null, 0, 1, 4, 505, 507, 999, -1]) {
      final result = PrinterStatus.parse({
        'statusCode': status,
        'paperCode': null,
      });
      expect(result.statusCode, status);
      expect(result.paperCode, null);
    }
    expect(
      PrinterStatus.parse({'statusCode': null, 'paperCode': 0}).paperCode,
      0,
    );
  });

  test('malformed and invented success fields are rejected', () {
    for (final value in [
      null,
      {},
      {'statusCode': 1},
      {'statusCode': 1, 'paperCode': 0, 'printed': true},
      {'statusCode': true, 'paperCode': 0},
      {'statusCode': 1.0, 'paperCode': 0},
      {'statusCode': 1, 'paperCode': '80'},
      {'statusCode': 2147483648, 'paperCode': null},
    ]) {
      expect(() => PrinterStatus.parse(value), throwsFormatException);
    }
  });

  test('only explicit argument-free inspect is sent', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return {'statusCode': 4, 'paperCode': 1};
    });
    expect((await const PrinterStatusClient().inspect()).statusCode, 4);
    expect(calls.single.method, 'inspect');
    expect(calls.single.arguments, null);
  });

  test('missing plugin is not absence of printer', () async {
    await expectLater(
      const PrinterStatusClient().inspect(),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'PRINTER_STATUS_UNSUPPORTED',
        ),
      ),
    );
  });

  test('private native failures are sanitized', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'PRIVATE', message: 'TEST_PRIVATE');
    });
    await expectLater(
      const PrinterStatusClient().inspect(),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'PRINTER_STATUS_FAILED')
            .having((e) => e.message, 'message', null),
      ),
    );
  });

  testWidgets('timeout does not turn a late reply into an observation', (
    tester,
  ) async {
    final pending = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (_) => pending.future);
    final check = expectLater(
      const PrinterStatusClient().inspect(),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'PRINTER_STATUS_TIMEOUT',
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 4));
    await check;
    pending.complete({'statusCode': 1, 'paperCode': 0});
    await tester.pump();
  });
}
