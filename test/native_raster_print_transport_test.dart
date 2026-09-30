
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/native_raster_print_transport.dart';

import 'usb_printer_permission_test.dart' show selection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final bytes = Uint8List.fromList([29, 118, 48, 0, 1, 0, 1, 0, 0]);
  final id = 'a' * 32;
  tearDown(
    () => messenger.setMockMethodCallHandler(
      NativeRasterPrintTransport.channel,
      null,
    ),
  );
  test('default-off transport never invokes native output', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(NativeRasterPrintTransport.channel, (
      call,
    ) async {
      calls++;
      return null;
    });
    await expectLater(
      const NativeRasterPrintTransport().send(selection(), bytes, id),
      throwsFormatException,
    );
    expect(calls, 0);
  });
  test(
    'sends exact selected descriptor and accepts only matching response',
    () async {
      final target = selection();
      messenger.setMockMethodCallHandler(NativeRasterPrintTransport.channel, (
        call,
      ) async {
        expect(call.method, 'send');
        final args = call.arguments as Map;
        expect(args['deviceId'], target.device.deviceId);
        expect(args['endpointAddress'], target.endpoint.address);
        expect(args['bytes'], bytes);
        expect(args['attemptId'], id);
        return {'attemptId': id, 'acceptedBytes': bytes.length};
      });
      expect(
        await const NativeRasterPrintTransport(enabled: true)
            .send(target, bytes, id),
        bytes.length,
      );
    },
  );
  test('mismatch and native failures never become accepted output', () async {
    for (final reply in [
      {'attemptId': 'b' * 32, 'acceptedBytes': 9},
      {'attemptId': id, 'acceptedBytes': 10},
      null,
    ]) {
      messenger.setMockMethodCallHandler(
        NativeRasterPrintTransport.channel,
        (call) async => reply,
      );
      await expectLater(
        const NativeRasterPrintTransport(enabled: true)
            .send(selection(), bytes, id),
        throwsFormatException,
      );
    }
    messenger.setMockMethodCallHandler(
      NativeRasterPrintTransport.channel,
      (call) async => throw PlatformException(code: 'PRIVATE_USB'),
    );
    await expectLater(
      const NativeRasterPrintTransport(enabled: true)
          .send(selection(), bytes, id),
      throwsFormatException,
    );
  });
}
