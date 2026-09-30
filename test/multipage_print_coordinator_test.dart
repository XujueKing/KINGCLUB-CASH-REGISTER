import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/escpos_raster.dart';
import 'package:kingclub_cash_register/src/hardware/print_attempt_journal.dart';
import 'package:kingclub_cash_register/src/hardware/raster_print_coordinator.dart';
import 'package:kingclub_cash_register/src/hardware/usb_printer_permission.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_print_identity.dart';
import 'balance_refund_command_test.dart' show Storage;
import 'usb_printer_permission_test.dart' show selection;

class PageTransport implements RasterPrintTransport {
  PageTransport(this.storage);
  final Storage storage;
  final ids = <String>[], counts = <int>[];
  int? failAt;
  void Function()? afterPage;
  @override Future<int> send(UsbPrinterSelection target, Uint8List bytes, String id) async {
    final rows = jsonDecode(storage.data[PrintAttemptJournal.key]!)['entries'] as List;
    expect(rows, hasLength(1)); expect(rows.single['state'], 'sending');
    ids.add(id); counts.add(bytes.length);
    expect(() => bytes[0] = 0, throwsUnsupportedError);
    afterPage?.call();
    return failAt == ids.length ? 1 : bytes.length;
  }
}
void main() {
  MonochromeRaster page([int width = 8, int height = 1]) => MonochromeRaster.fromStraightRgba(
    width: width, height: height, rgba: Uint8List(width * height * 4));
  test('reopening the same order with different pixels cannot bypass a durable completed attempt', () async {
    final storage = Storage(), transport = PageTransport(storage);
    final identity = ReceiptPrintIdentity(base: 'https://service.invalid', storeRef: 'TEST_STORE', orderRef: 'D00000000001');
    final journal = PrintAttemptJournal(storage: storage);
    final first = RasterPrintCoordinator(transport: transport, journal: journal, enabled: true);
    final result = await first.printRasters(rasters: [page()], documentIdentity: identity, target: selection(),
      confirmed: true, compatibilityVerified: true, stillCurrent: () => true);
    expect(result.documentHash, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(storage.data[PrintAttemptJournal.key], isNot(contains('TEST_STORE')));
    expect(storage.data[PrintAttemptJournal.key], isNot(contains('D00000000001')));
    final reopened = RasterPrintCoordinator(transport: transport,
      journal: PrintAttemptJournal(storage: storage), enabled: true);
    await expectLater(reopened.printRasters(rasters: [page(16)], documentIdentity: identity, target: selection(),
      confirmed: true, compatibilityVerified: true, stillCurrent: () => true), throwsFormatException);
    expect(transport.ids, hasLength(1));
    expect(await journal.load(), hasLength(1));
  });
  test('legacy diagnostic entries remain readable; malformed optional identity fails closed', () {
    final row = {'id': 'a'*32, 'contentHash': 'b'*64, 'targetHash': 'c'*64,
      'byteCount': 9, 'state': 'transport_accepted'};
    expect(PrintAttempt.decode(row).documentHash, isNull);
    for (final value in [null, '', 'bad', 12]) {
      expect(() => PrintAttempt.decode({...row, 'documentHash': value}), throwsFormatException);
    }
    final entry = PrintAttempt.decode({...row, 'documentHash': 'd'*64});
    expect(PrintAttempt.decode(entry.encode()).documentHash, 'd'*64);
  });
  test('all pages share one journal task with unique native page IDs and combined byte count', () async {
    final storage = Storage(), journal = PrintAttemptJournal(storage: storage), transport = PageTransport(storage);
    final coordinator = RasterPrintCoordinator(transport: transport, journal: journal, enabled: true);
    final result = await coordinator.printRasters(rasters: [page(), page()], target: selection(),
      confirmed: true, compatibilityVerified: true, stillCurrent: () => true);
    expect(result.state, 'transport_accepted');
    expect(transport.ids.toSet(), hasLength(2));
    expect(result.byteCount, transport.counts.reduce((a,b) => a+b));
    expect(await journal.load(), hasLength(1));
  });
  test('second page short write stops third page and blocks a new document', () async {
    final storage = Storage(), journal = PrintAttemptJournal(storage: storage), transport = PageTransport(storage)..failAt = 2;
    final coordinator = RasterPrintCoordinator(transport: transport, journal: journal, enabled: true);
    final result = await coordinator.printRasters(rasters: [page(), page(), page()], target: selection(),
      confirmed: true, compatibilityVerified: true, stillCurrent: () => true);
    expect(result.state, 'unknown'); expect(transport.ids, hasLength(2));
    await expectLater(coordinator.printRaster(raster: page(), target: selection(), confirmed: true,
      compatibilityVerified: true, stillCurrent: () => true), throwsFormatException);
    expect(transport.ids, hasLength(2));
  });
  test('context loss between pages stops the whole document without retry', () async {
    final storage = Storage(), journal = PrintAttemptJournal(storage: storage), transport = PageTransport(storage);
    var current = true; transport.afterPage = () => current = false;
    final coordinator = RasterPrintCoordinator(transport: transport, journal: journal, enabled: true);
    final result = await coordinator.printRasters(rasters: [page(), page()], target: selection(),
      confirmed: true, compatibilityVerified: true, stillCurrent: () => current);
    expect(result.state, 'unknown'); expect(transport.ids, hasLength(1));
  });
  test('invalid page counts, mixed widths and oversize pages never create output', () async {
    final storage = Storage(), transport = PageTransport(storage);
    final coordinator = RasterPrintCoordinator(transport: transport, journal: PrintAttemptJournal(storage: storage), enabled: true);
    for (final pages in <List<MonochromeRaster>>[[], List.filled(33, page()), [page(), page(16)], [page(), page(8, 2049)]]) {
      await expectLater(coordinator.printRasters(rasters: pages, target: selection(),
        confirmed: true, compatibilityVerified: true, stillCurrent: () => true), throwsFormatException);
    }
    expect(transport.ids, isEmpty); expect(storage.data, isEmpty);
  });
  test('document journal byte limit is bounded without changing saved record shape', () {
    final row = {'id': 'a'*32, 'contentHash': 'b'*64, 'targetHash': 'c'*64,
      'byteCount': PrintAttempt.maxDocumentBytes, 'state': 'prepared'};
    expect(PrintAttempt.decode(row).byteCount, 5000000);
    expect(() => PrintAttempt.decode({...row, 'byteCount': 5000001}), throwsFormatException);
  });
}
