import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/test_receipt_preview_dialog.dart';
import 'package:kingclub_cash_register/src/hardware/test_receipt_renderer.dart';
import 'package:kingclub_cash_register/src/strings.dart';

void main() {
  testWidgets(
    'width and language changes clear stale preview while rendering',
    (tester) async {
      final fixture = (await tester.runAsync(
        () => renderTestReceipt(language: UiLanguage.zh, widthDots: 576),
      ))!;
      final requests = <({UiLanguage language, int width})>[];
      final pending = <Completer<RenderedTestReceipt>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: TestReceiptPreviewDialog(
            language: UiLanguage.zh,
            render: ({required language, required widthDots}) {
              requests.add((language: language, width: widthDots));
              final next = Completer<RenderedTestReceipt>();
              pending.add(next);
              return next.future;
            },
          ),
        ),
      );
      pending[0].complete(fixture);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-receipt-image')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('test-receipt-width')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('512').last);
      await tester.pump();
      expect(requests.last, (language: UiLanguage.zh, width: 512));
      expect(find.byKey(const ValueKey('test-receipt-image')), findsNothing);
      pending[1].complete(fixture);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('test-receipt-language')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ไทย').last);
      await tester.pump();
      expect(requests.last, (language: UiLanguage.th, width: 512));
      expect(find.byKey(const ValueKey('test-receipt-image')), findsNothing);
      pending[2].complete(fixture);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-receipt-image')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final language in UiLanguage.values) {
    testWidgets('preview failure is bounded and retryable ${language.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(960, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var calls = 0;
      final pending = Completer<RenderedTestReceipt>();
      await tester.pumpWidget(
        MaterialApp(
          home: TestReceiptPreviewDialog(
            language: language,
            render: ({required language, required widthDots}) {
              calls++;
              expect(widthDots, 576);
              return pending.future;
            },
          ),
        ),
      );
      expect(calls, 1);
      expect(
        tester
            .widget<DropdownButton<int>>(
              find.byKey(const ValueKey('test-receipt-width')),
            )
            .onChanged,
        isNull,
      );
      pending.completeError(StateError('PRIVATE_DIAGNOSTIC'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('test-receipt-error')), findsOneWidget);
      expect(find.textContaining('PRIVATE_DIAGNOSTIC'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('test-receipt-retry')));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('closing pending preview ignores late completion', (
    tester,
  ) async {
    final pending = Completer<RenderedTestReceipt>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => TestReceiptPreviewDialog(
                language: UiLanguage.zh,
                render: ({required language, required widthDots}) =>
                    pending.future,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('test-receipt-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    pending.completeError(StateError('late'));
    await tester.pumpAndSettle();
    expect(find.byType(TestReceiptPreviewDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
