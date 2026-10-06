import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/cashbook_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;

class CashbookAuth extends TableAuth {
  final calls = <Map<String, dynamic>>[];
  bool admin = true;
  @override
  Future<Map<String, dynamic>> cashbook(Map<String, dynamic> command) async {
    calls.add(command);
    return {
      'canReview': admin ? 1 : 0,
      'total': 1,
      'summary': {
        'incomeCents': 1000,
        'expenseCents': 200,
        'advanceCents': 10000,
        'reimbursedCents': 0,
      },
      'entries': [
        {
          'ref': 'test-entry',
          'createdAt': '2026-10-06T02:00:00Z',
          'kind': 'advance',
          'amountCents': 10000,
          'note': '采购临时垫款',
          'person': '测试员工',
          'status': 'pending',
        },
      ],
    };
  }
}

void main() {
  testWidgets('Cashbook and touch entry fit compact screen in four languages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = CashbookAuth();
    addTearDown(auth.dispose);
    for (final lang in UiLanguage.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CashbookPanel(
              key: ValueKey(lang),
              auth: auth,
              language: lang,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$lang page');
      await tester.tap(find.byType(FilledButton).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$lang dialog');
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
    }
  });
  testWidgets('ordinary staff cannot review; touch amount is yuan not cents', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = CashbookAuth()..admin = false;
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CashbookPanel(auth: auth, language: UiLanguage.zh),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('确认已报销'), findsNothing);
    await tester.tap(find.byType(FilledButton).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '零星收入');
    await tester.enterText(find.byType(TextField).at(1), '测试员工');
    for (final key in ['1', '0', '0']) {
      await tester.tap(find.widgetWithText(OutlinedButton, key));
    }
    await tester.tap(find.text('保存登记'));
    await tester.pumpAndSettle();
    expect(
      auth.calls.firstWhere((c) => c['action'] == 'create')['amountCents'],
      10000,
    );
    expect(tester.takeException(), isNull);
  });
}
