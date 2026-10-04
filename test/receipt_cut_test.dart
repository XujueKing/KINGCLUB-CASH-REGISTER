import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/escpos_raster.dart';
import 'package:kingclub_cash_register/src/hardware/raster_print_coordinator.dart';
import 'package:kingclub_cash_register/src/hardware/print_attempt_journal.dart';
import 'package:kingclub_cash_register/src/hardware/usb_printer_permission.dart';

import 'balance_refund_command_test.dart' show Storage;
import 'usb_printer_permission_test.dart' show selection;

class Capture implements RasterPrintTransport {
  final pages = <Uint8List>[];
  bool fail = false;
  @override
  Future<int> send(
    UsbPrinterSelection target,
    Uint8List bytes,
    String id,
  ) async {
    pages.add(bytes);
    return fail ? 0 : bytes.length;
  }
}

void main() {
  final raster = MonochromeRaster.fromStraightRgba(
    width: 8,
    height: 1,
    rgba: Uint8List(32),
  );
  for (final fail in [false, true]) {
    test(
      'final cut is fenced and only follows all successful pages: failure=$fail',
      () async {
        final transport = Capture()..fail = fail;
        final storage = Storage();
        final result =
            await RasterPrintCoordinator(
              transport: transport,
              journal: PrintAttemptJournal(storage: storage),
              enabled: true,
            ).printRasters(
              rasters: [raster, raster],
              target: selection(),
              cutAtEnd: true,
              confirmed: true,
              compatibilityVerified: true,
              stillCurrent: () => true,
            );
        expect(transport.pages.first, encodeGsV0(raster));
        expect(transport.pages.length, fail ? 1 : 2);
        if (!fail) {
          expect(
            transport.pages.last.sublist(transport.pages.last.length - 4),
            [29, 86, 66, 0],
          );
          expect(result.state, 'transport_accepted');
          final entry =
              (jsonDecode(storage.data[PrintAttemptJournal.key]!)['entries']
                      as List)
                  .single;
          expect(
            entry['byteCount'],
            transport.pages.fold<int>(0, (v, p) => v + p.length),
          );
        } else {
          expect(result.state, isNot('transport_accepted'));
        }
      },
    );
  }
}
