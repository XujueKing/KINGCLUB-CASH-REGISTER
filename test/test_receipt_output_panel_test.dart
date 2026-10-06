import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/escpos_raster.dart';
import 'package:kingclub_cash_register/src/hardware/native_raster_print_transport.dart';
import 'package:kingclub_cash_register/src/hardware/print_attempt_journal.dart';
import 'package:kingclub_cash_register/src/hardware/raster_print_coordinator.dart';
import 'package:kingclub_cash_register/src/hardware/test_receipt_output_panel.dart';
import 'package:kingclub_cash_register/src/hardware/test_receipt_renderer.dart';
import 'package:kingclub_cash_register/src/hardware/usb_printer_permission.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'usb_printer_permission_test.dart' show selection;

class Coordinator extends RasterPrintCoordinator {
  Coordinator()
    : super(transport: const NativeRasterPrintTransport(), enabled: true);
  int calls = 0;
  final pending = Completer<PrintAttempt>();
  bool Function()? current;
  MonochromeRaster? received;
  @override
  Future<PrintAttempt> printRaster({
    required MonochromeRaster raster,
    required UsbPrinterSelection target,
    required bool confirmed,
    required bool compatibilityVerified,
    required bool Function() stillCurrent,
  }) {
    expect(confirmed && compatibilityVerified && stillCurrent(), isTrue);
    calls++;
    current = stillCurrent;
    received = raster;
    return pending.future;
  }
}

PrintAttempt result(String state) => PrintAttempt.decode({
  'id': 'a' * 32,
  'contentHash': 'b' * 64,
  'targetHash': 'c' * 64,
  'byteCount': 9,
  'state': state,
});

void main() {
  final receipt = RenderedTestReceipt(
    MonochromeRaster.fromStraightRgba(width: 8, height: 1, rgba: Uint8List(32)),
    Uint8List(0),
  );
  Future<void> mount(
    WidgetTester tester, {
    RasterPrintCoordinator? coordinator,
  }) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestReceiptOutputPanel(
            receipt: receipt,
            target: selection(),
            language: UiLanguage.zh,
            coordinator: coordinator,
          ),
        ),
      ),
    );
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('test-print-compatible')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('test-print-consent')));
    await tester.pump();
  }

  testWidgets('disabled output has no send action', (tester) async {
    await mount(
      tester,
      coordinator: RasterPrintCoordinator(
        transport: const NativeRasterPrintTransport(enabled: false),
        enabled: false,
      ),
    );
    expect(find.byKey(const ValueKey('test-print-send')), findsNothing);
    expect(
      find.text(tr(UiLanguage.zh, 'printerOutputDisabled')),
      findsOneWidget,
    );
  });
  for (final state in ['transport_accepted', 'unknown']) {
    testWidgets('explicit confirmation sends exact raster once: $state', (
      tester,
    ) async {
      final coordinator = Coordinator();
      await mount(tester, coordinator: coordinator);
      final button = find.byKey(const ValueKey('test-print-send'));
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await confirm(tester);
      await tester.tap(button);
      await tester.pump();
      expect(coordinator.calls, 1);
      expect(identical(coordinator.received, receipt.raster), isTrue);
      expect(find.byKey(const ValueKey('test-print-send')), findsNothing);
      coordinator.pending.complete(result(state));
      await tester.pumpAndSettle();
      expect(
        find.text(
          tr(
            UiLanguage.zh,
            state == 'transport_accepted'
                ? 'printerOutputAccepted'
                : 'printerOutputReview',
          ),
        ),
        findsOneWidget,
      );
      expect(coordinator.calls, 1);
    });
  }
  testWidgets(
    'background invalidates send context; late result does not replace review',
    (tester) async {
      final coordinator = Coordinator();
      await mount(tester, coordinator: coordinator);
      await confirm(tester);
      await tester.tap(find.byKey(const ValueKey('test-print-send')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(coordinator.current!(), isFalse);
      coordinator.pending.complete(result('transport_accepted'));
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(
        find.text(tr(UiLanguage.zh, 'printerOutputReview')),
        findsOneWidget,
      );
      expect(coordinator.calls, 1);
    },
  );
}
