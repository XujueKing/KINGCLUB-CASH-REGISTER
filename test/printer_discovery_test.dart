import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/printer_discovery.dart';

Map<String, Object?> observation() => {
  'serviceInstalled': true,
  'serviceEnabled': true,
  'serviceResolvable': true,
  'serviceVersion': 'TEST_ONLY_1.0',
  'usbPrinterCandidates': 0,
  'usbPrinters': <Object?>[],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cn.kingclub.cashier/printer-discovery');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'valid discovery reports capabilities without a ready or printed claim',
    () {
      final result = PrinterDiscovery.parse(observation());
      expect(result.serviceResolvable, true);
      expect(result.usbPrinterCandidates, 0);
      expect(result.serviceVersion, 'TEST_ONLY_1.0');
      final absent = PrinterDiscovery.parse({
        'serviceInstalled': false,
        'serviceEnabled': false,
        'serviceResolvable': false,
        'serviceVersion': null,
        'usbPrinterCandidates': 0,
        'usbPrinters': <Object?>[],
      });
      expect(absent.serviceInstalled, false);
      expect(absent.usbPrinterCandidates, 0);
    },
  );

  test(
    'strict discovery parser rejects forged readiness and inconsistent states',
    () {
      for (final value in [
        null,
        {},
        {...observation(), 'printed': true},
        {...observation(), 'serviceInstalled': false},
        {...observation(), 'serviceEnabled': false},
        {...observation(), 'serviceVersion': 'bad\nversion'},
        {...observation(), 'serviceVersion': 3},
        {...observation(), 'usbPrinterCandidates': -1},
        {...observation(), 'usbPrinterCandidates': 0.0},
        {...observation(), 'usbPrinterCandidates': 257},
      ]) {
        expect(() => PrinterDiscovery.parse(value), throwsFormatException);
      }
    },
  );

  test('bridge sends only argument-free inspect; never any print or drawer command', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return observation();
    });
    final result = await const PrinterDiscoveryClient().inspect();
    expect(result.serviceEnabled, true);
    expect(calls.single.method, 'inspect');
    expect(calls.single.arguments, null);
  });

  test(
    'unsupported platforms fail explicitly instead of reporting no printer',
    () async {
      await expectLater(
        const PrinterDiscoveryClient().inspect(),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'PRINTER_DISCOVERY_UNSUPPORTED',
          ),
        ),
      );
    },
  );

  test('native details and malformed replies are not exposed', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'PRIVATE',
        message: 'TEST_PRIVATE_DEVICE_DATA',
      );
    });
    await expectLater(
      const PrinterDiscoveryClient().inspect(),
      throwsA(
        isA<PlatformException>()
            .having((e) => e.code, 'code', 'PRINTER_DISCOVERY_FAILED')
            .having((e) => e.message, 'message', null),
      ),
    );
    messenger.setMockMethodCallHandler(channel, (_) async => {'ready': true});
    await expectLater(
      const PrinterDiscoveryClient().inspect(),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'PRINTER_DISCOVERY_FAILED',
        ),
      ),
    );
  });
}
