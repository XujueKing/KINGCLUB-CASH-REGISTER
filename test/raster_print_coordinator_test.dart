import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/escpos_raster.dart';
import 'package:kingclub_cash_register/src/hardware/print_attempt_journal.dart';
import 'package:kingclub_cash_register/src/hardware/raster_print_coordinator.dart';
import 'package:kingclub_cash_register/src/hardware/usb_printer_permission.dart';

import 'balance_refund_command_test.dart' show Storage;
import 'usb_printer_permission_test.dart' show selection;

class Transport implements RasterPrintTransport {
  Transport(this.storage);
  final Storage storage;
  int calls = 0;
  int? accepted;
  bool fail = false;
  @override
  Future<int> send(
    UsbPrinterSelection target,
    Uint8List bytes,
    String id,
  ) async {
    calls++;
    final saved =
        (jsonDecode(storage.data[PrintAttemptJournal.key]!)['entries'] as List)
            .single;
    expect(saved['id'], id);
    expect(saved['state'], 'sending');
    expect(saved['byteCount'], bytes.length);
    expect(() => bytes[0] = 0, throwsUnsupportedError);
    if (fail) throw StateError('PRIVATE_USB_ERROR');
    return accepted ?? bytes.length;
  }
}

void main() {
  final raster = MonochromeRaster.fromStraightRgba(
    width: 8,
    height: 1,
    rgba: Uint8List(32),
  );
  test('disabled coordinator never creates a job or calls transport', () async {
    final storage = Storage(), transport = Transport(storage);
    final service = RasterPrintCoordinator(
      transport: transport,
      journal: PrintAttemptJournal(storage: storage),
    );
    await expectLater(
      service.printRaster(
        raster: raster,
        target: selection(),
        confirmed: true,
        compatibilityVerified: true,
        stillCurrent: () => true,
      ),
      throwsFormatException,
    );
    expect(transport.calls, 0);
    expect(storage.data, isEmpty);
  });
  test('writes send fence before immutable raster reaches transport', () async {
    final storage = Storage(), transport = Transport(storage);
    final service = RasterPrintCoordinator(
      transport: transport,
      journal: PrintAttemptJournal(storage: storage),
      enabled: true,
    );
    final result = await service.printRaster(
      raster: raster,
      target: selection(),
      confirmed: true,
      compatibilityVerified: true,
      stillCurrent: () => true,
    );
    expect(result.state, 'transport_accepted');
    expect(transport.calls, 1);
  });
  test(
    'partial or failed send is unknown and blocks another attempt',
    () async {
      for (final fails in [false, true]) {
        final storage = Storage(),
            transport = Transport(storage)
              ..accepted = 1
              ..fail = fails;
        final service = RasterPrintCoordinator(
          transport: transport,
          journal: PrintAttemptJournal(storage: storage),
          enabled: true,
        );
        final result = await service.printRaster(
          raster: raster,
          target: selection(),
          confirmed: true,
          compatibilityVerified: true,
          stillCurrent: () => true,
        );
        expect(result.state, 'unknown');
        await expectLater(
          service.printRaster(
            raster: raster,
            target: selection(),
            confirmed: true,
            compatibilityVerified: true,
            stillCurrent: () => true,
          ),
          throwsFormatException,
        );
        expect(transport.calls, 1);
      }
    },
  );
  test('storage readback failure prevents transmission', () async {
    final storage = Storage()..discardWrite = true,
        transport = Transport(storage);
    final service = RasterPrintCoordinator(
      transport: transport,
      journal: PrintAttemptJournal(storage: storage),
      enabled: true,
    );
    await expectLater(
      service.printRaster(
        raster: raster,
        target: selection(),
        confirmed: true,
        compatibilityVerified: true,
        stillCurrent: () => true,
      ),
      throwsFormatException,
    );
    expect(transport.calls, 0);
  });
}
