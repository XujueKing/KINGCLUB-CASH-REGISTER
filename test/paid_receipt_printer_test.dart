import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kingclub_cash_register/src/hardware/paid_receipt_printer.dart';
import 'package:kingclub_cash_register/src/hardware/native_raster_print_transport.dart';
import 'package:kingclub_cash_register/src/live/receipt_document.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'table_checkout_dialog_test.dart' show CheckoutDialogAuth;
import 'table_receipt_document_test.dart' show tableReceiptFixture, checkout;
import 'printer_discovery_test.dart' show observation;
import 'usb_printer_descriptor_test.dart' show descriptor;

class ReceiptAuth extends CheckoutDialogAuth {
  bool wrongScope = false;
  @override
  Future<TableReceiptDocument> readTableReceiptDocument(String ref) async {
    final raw = tableReceiptFixture();
    raw['result']['storeRef'] = session.storeRef;
    if (wrongScope) raw['result']['tableRef'] = 'OTHER_TABLE';
    return TableReceiptDocument.parse(
      raw,
      storeRef: session.storeRef,
      checkoutRef: ref,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const discovery = MethodChannel('cn.kingclub.cashier/printer-discovery');
  var sends = 0;
  var available = true;
  var shortWrite = false;
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    sends = 0;
    available = true;
    shortWrite = false;
    messenger.setMockMethodCallHandler(
      discovery,
      (_) async => {
        ...observation(),
        'usbPrinterCandidates': available ? 1 : 0,
        'usbPrinters': available
            ? [
                {
                  ...descriptor(),
                  'vendorId': 1155,
                  'productId': 22339,
                  'hasPermission': true,
                },
              ]
            : [],
      },
    );
    messenger.setMockMethodCallHandler(NativeRasterPrintTransport.channel, (
      call,
    ) async {
      sends++;
      return {
        'attemptId': call.arguments['attemptId'],
        'acceptedBytes': shortWrite
            ? 0
            : (call.arguments['bytes'] as Uint8List).length,
      };
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(discovery, null);
    messenger.setMockMethodCallHandler(
      NativeRasterPrintTransport.channel,
      null,
    );
  });
  Future<String> print(ReceiptAuth auth) => printPaidTableReceipt(
    auth: auth,
    checkoutRef: checkout,
    tableRef: 'TEST_TABLE',
    sessionRef: 'TEST_SESSION',
    language: UiLanguage.zh,
    stillCurrent: () => true,
  );
  testWidgets(
    'verified receipt prints once; reopening does not send duplicate',
    (tester) async {
      final auth = ReceiptAuth();
      addTearDown(auth.dispose);
      expect(await tester.runAsync(() => print(auth)), 'checkoutPrintSent');
      final firstSends = sends;
      expect(firstSends, greaterThan(0));
      expect(await tester.runAsync(() => print(auth)), 'checkoutPrintFailed');
      expect(sends, firstSends);
    },
  );
  testWidgets('wrong table and missing printer never write USB', (
    tester,
  ) async {
    final auth = ReceiptAuth()..wrongScope = true;
    addTearDown(auth.dispose);
    expect(await tester.runAsync(() => print(auth)), 'checkoutPrintFailed');
    auth.wrongScope = false;
    available = false;
    expect(
      await tester.runAsync(() => print(auth)),
      'checkoutPrintUnavailable',
    );
    expect(sends, 0);
  });
  testWidgets('uncertain write is reported and never automatically retried', (
    tester,
  ) async {
    final auth = ReceiptAuth();
    addTearDown(auth.dispose);
    shortWrite = true;
    expect(await tester.runAsync(() => print(auth)), 'checkoutPrintFailed');
    expect(sends, 1);
    expect(await tester.runAsync(() => print(auth)), 'checkoutPrintFailed');
    expect(sends, 1);
  });
  testWidgets('explicit copy resolves its previous unknown output', (tester) async {
    final auth = ReceiptAuth(); addTearDown(auth.dispose); shortWrite = true;
    expect(await tester.runAsync(() => print(auth)), 'checkoutPrintFailed');
    shortWrite = false;
    expect(await tester.runAsync(() => printPaidTableReceipt(auth: auth,
      checkoutRef: checkout, tableRef: 'TEST_TABLE', sessionRef: 'TEST_SESSION',
      language: UiLanguage.zh, stillCurrent: () => true, reprint: true)), 'checkoutPrintSent');
    expect(sends, greaterThan(1));
  });

}
