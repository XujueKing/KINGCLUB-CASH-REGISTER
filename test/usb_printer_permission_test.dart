import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/usb_printer_descriptor.dart';
import 'package:kingclub_cash_register/src/hardware/usb_printer_permission.dart';

import 'usb_printer_descriptor_test.dart' as u;

UsbPrinterSelection selection() {
  final d = UsbPrinterDescriptor.parse(u.descriptor());
  return UsbPrinterSelection.choose(
    d,
    d.interfaces.single,
    d.interfaces.single.endpoints.single,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cn.kingclub.cashier/usb-printer-permission');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'selection must use the exact observed interface and output endpoint',
    () {
      final d = UsbPrinterDescriptor.parse(u.descriptor());
      final other = UsbPrinterDescriptor.parse(u.descriptor());
      expect(
        () => UsbPrinterSelection.choose(
          d,
          other.interfaces.single,
          other.interfaces.single.endpoints.single,
        ),
        throwsFormatException,
      );
      final input = UsbPrinterDescriptor.parse({
        ...u.descriptor(),
        'interfaces': [
          {
            ...u.usbInterface(),
            'endpoints': [
              {...u.endpoint(), 'address': 129},
            ],
          },
        ],
      });
      expect(
        () => UsbPrinterSelection.choose(
          input,
          input.interfaces.single,
          input.interfaces.single.endpoints.single,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'confirmation required, exact attachment sent, request cannot replay',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {
          'requestId': (call.arguments as Map)['requestId'],
          'granted': true,
        };
      });
      final request = UsbPrinterPermissionRequest(selection());
      await expectLater(
        request.request(confirmed: false),
        throwsA(isA<PlatformException>()),
      );
      expect(calls, isEmpty);
      expect(await request.request(confirmed: true), true);
      expect(calls.single.method, 'request');
      final payload = calls.single.arguments as Map;
      expect(payload.length, 10);
      expect(payload['deviceId'], 100);
      expect(payload['interfaceId'], 0);
      expect(payload['endpointAddress'], 1);
      expect(payload['vendorId'], 0x1234);
      expect(payload['requestId'], matches(RegExp(r'^[a-f0-9]{32}$')));
      await expectLater(
        request.request(confirmed: true),
        throwsA(isA<PlatformException>()),
      );
      expect(calls.length, 1);
    },
  );

  test('OS refusal remains refusal and does not cause retry', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return {
        'requestId': (call.arguments as Map)['requestId'],
        'granted': false,
      };
    });
    expect(
      await UsbPrinterPermissionRequest(selection()).request(confirmed: true),
      false,
    );
    expect(calls, 1);
  });

  test('malformed, mismatched and private responses fail closed', () async {
    for (final raw in [
      null,
      {},
      {'requestId': 'wrong', 'granted': true},
    ]) {
      messenger.setMockMethodCallHandler(channel, (_) async => raw);
      await expectLater(
        UsbPrinterPermissionRequest(selection()).request(confirmed: true),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'USB_PERMISSION_FAILED',
          ),
        ),
      );
    }
    messenger.setMockMethodCallHandler(
      channel,
      (_) async =>
          throw PlatformException(code: 'PRIVATE', message: 'TEST_PRIVATE'),
    );
    await expectLater(
      UsbPrinterPermissionRequest(selection()).request(confirmed: true),
      throwsA(
        isA<PlatformException>().having((e) => e.message, 'message', null),
      ),
    );
  });

  test('cancel targets only its request and ignores late grant', () async {
    final pending = Completer<Object?>();
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return call.method == 'request' ? pending.future : Future.value(null);
    });
    final request = UsbPrinterPermissionRequest(selection());
    final done = expectLater(
      request.request(confirmed: true),
      throwsA(isA<PlatformException>()),
    );
    await request.cancel();
    await request.cancel();
    expect(calls.map((c) => c.method), ['request', 'cancel']);
    expect(calls.last.arguments, request.requestId);
    pending.complete({'requestId': request.requestId, 'granted': true});
    await done;
  });

  test('cancel before start never requests OS permission', () async {
    final request = UsbPrinterPermissionRequest(selection());
    await request.cancel();
    await expectLater(
      request.request(confirmed: true),
      throwsA(isA<PlatformException>()),
    );
  });

  testWidgets(
    'bounded timeout cancels observation without claiming revoked access',
    (tester) async {
      final pending = Completer<Object?>();
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        return call.method == 'request' ? pending.future : Future.value(null);
      });
      final request = UsbPrinterPermissionRequest(selection());
      final done = expectLater(
        request.request(confirmed: true),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'USB_PERMISSION_TIMEOUT',
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 65));
      await done;
      await tester.pump();
      expect(calls.map((c) => c.method), ['request', 'cancel']);
      pending.complete({'requestId': request.requestId, 'granted': true});
      await tester.pump();
    },
  );
}
