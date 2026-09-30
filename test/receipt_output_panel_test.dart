import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/native_raster_print_transport.dart';
import 'package:kingclub_cash_register/src/hardware/printer_discovery.dart';
import 'package:kingclub_cash_register/src/hardware/raster_print_coordinator.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_document_renderer.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_output_panel.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_print_identity.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'receipt_document_test.dart' show document, parse;
import 'printer_discovery_test.dart' show observation;
import 'usb_printer_descriptor_test.dart' show descriptor;

void main() {
  testWidgets(
    'new document clears old discovery error and ignores late discovery',
    (tester) async {
      final plan = ReceiptRasterPlan.create(
        parse(document()),
        language: UiLanguage.en,
        widthDots: 576,
      );
      final coordinator = RasterPrintCoordinator(
        transport: const NativeRasterPrintTransport(),
        enabled: true,
      );
      var discovery = Completer<PrinterDiscovery>();
      Widget panel(String order) => MaterialApp(
        home: Scaffold(
          body: ReceiptOutputPanel(
            plan: plan,
            language: UiLanguage.en,
            coordinator: coordinator,
            identity: ReceiptPrintIdentity(
              base: 'https://service.invalid',
              storeRef: 'TEST_STORE',
              orderRef: order,
            ),
            inspect: () => discovery.future,
          ),
        ),
      );
      await tester.pumpWidget(panel('D00000000001'));
      await tester.tap(find.byKey(const ValueKey('receipt-output-discover')));
      discovery.completeError(StateError('TEST_DISCOVERY_FAILURE'));
      await tester.pumpAndSettle();
      expect(
        find.text(tr(UiLanguage.en, 'printerInspectFailed')),
        findsOneWidget,
      );
      await tester.pumpWidget(panel('D00000000002'));
      expect(find.byKey(const ValueKey('receipt-output-status')), findsNothing);
      discovery = Completer<PrinterDiscovery>();
      await tester.tap(find.byKey(const ValueKey('receipt-output-discover')));
      await tester.pumpWidget(panel('D00000000003'));
      discovery.complete(
        PrinterDiscovery.parse({
          ...observation(),
          'usbPrinterCandidates': 1,
          'usbPrinters': [
            {...descriptor(), 'hasPermission': true},
          ],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining(RegExp(r'^USB ')), findsNothing);
      expect(find.byKey(const ValueKey('receipt-output-send')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  Future<void> mount(
    WidgetTester tester, {
    bool enabled = false,
    bool permission = true,
  }) async {
    tester.view.physicalSize = const Size(1366, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final plan = ReceiptRasterPlan.create(
      parse(document()),
      language: UiLanguage.en,
      widthDots: 576,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReceiptOutputPanel(
            plan: plan,
            language: UiLanguage.en,
            identity: ReceiptPrintIdentity(
              base: 'https://service.invalid',
              storeRef: 'TEST_STORE',
              orderRef: 'D00000000001',
            ),
            coordinator: RasterPrintCoordinator(
              transport: const NativeRasterPrintTransport(),
              enabled: enabled,
            ),
            inspect: () async => PrinterDiscovery.parse({
              ...observation(),
              'usbPrinterCandidates': 1,
              'usbPrinters': [
                {...descriptor(), 'hasPermission': permission},
              ],
            }),
          ),
        ),
      ),
    );
  }

  testWidgets('default disabled never discovers or offers output', (
    tester,
  ) async {
    await mount(tester);
    expect(find.byKey(const ValueKey('receipt-output-discover')), findsNothing);
    expect(find.byKey(const ValueKey('receipt-output-send')), findsNothing);
    expect(
      find.text(tr(UiLanguage.en, 'printerOutputDisabled')),
      findsOneWidget,
    );
  });
  testWidgets('no permission does not request permission or offer a printer', (
    tester,
  ) async {
    await mount(tester, enabled: true, permission: false);
    await tester.tap(find.byKey(const ValueKey('receipt-output-discover')));
    await tester.pumpAndSettle();
    expect(
      find.text(tr(UiLanguage.en, 'receiptPrinterUnavailable')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('receipt-output-send')), findsNothing);
  });
  testWidgets('selection is explicit and background clears both confirmations', (
    tester,
  ) async {
    await mount(tester, enabled: true);
    expect(find.byKey(const ValueKey('receipt-output-send')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('receipt-output-discover')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('receipt-output-send')), findsNothing);
    await tester.tap(find.textContaining(RegExp(r'^USB ')));
    await tester.pump();
    final send = find.byKey(const ValueKey('receipt-output-send'));
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('receipt-output-compatible')));
    await tester.pump();
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('receipt-output-consent')));
    await tester.pump();
    expect(tester.widget<FilledButton>(send).onPressed, isNotNull);
    // Never tap send: this test covers gating, not actual rendering/USB output.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(send, findsNothing);
  });
}
