import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_receipt_content.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'table_receipt_document_test.dart' show parse, tableReceiptFixture;

void main() {
  for (final language in UiLanguage.values) {
    testWidgets(
      'shows one parent tender and expandable allocations in ${language.name}',
      (tester) async {
        final document = parse(tableReceiptFixture());
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TableReceiptContent(document: document, language: language),
            ),
          ),
        );
        expect(find.text(tr(language, 'tableReceiptTitle')), findsOneWidget);
        expect(find.text(tr(language, 'tableReceiptNotice')), findsOneWidget);
        expect(
          find.text('${tr(language, 'receiptPrincipal')}: CNY 2.40'),
          findsOneWidget,
        );
        expect(
          find.text('${tr(language, 'receiptGift')}: CNY 0.60'),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.text('D00000000001'), 150,
          scrollable: find.descendant(
            of: find.byType(ListView), matching: find.byType(Scrollable),
          ).first,
        );
        await tester.tap(find.text('D00000000001'));
        await tester.pumpAndSettle();
        final item = document.orders.first.items.first;
        expect(
          find.text('${item.name(language)} · ${item.specification(language)}'),
          findsOneWidget,
        );
        expect(find.text(tr(language, 'print')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
