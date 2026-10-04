import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/voucher_group_admission_card.dart';
import 'package:kingclub_cash_register/src/strings.dart';

void main() {
  testWidgets(
    'touch selection uses server portion, never silently chooses package or party size',
    (tester) async {
      final data = {
        'portions': [
          {
            'variantRef': 'A',
            'people': 5,
            'portion': 'half',
            'configured': true,
            'lines': [
              {'name': 'Whisky500', 'quantity': 1},
            ],
          },
          {
            'variantRef': 'A',
            'people': 6,
            'portion': 'full',
            'configured': true,
            'lines': [
              {'name': 'Whisky500', 'quantity': 2},
            ],
          },
          {
            'variantRef': 'B',
            'people': 6,
            'portion': 'full',
            'configured': false,
            'lines': [
              {'name': 'Strawberry700', 'quantity': 4},
            ],
          },
        ],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: VoucherGroupAdmissionCard(
                data: data,
                language: UiLanguage.en,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Whisky500 × 1'), findsNothing);
      await tester.tap(find.text('Package A'));
      await tester.tap(find.byKey(const ValueKey('admission-people-5')));
      await tester.pump();
      expect(find.text('Whisky500 × 1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('admission-people-6')));
      await tester.pump();
      expect(find.text('Whisky500 × 2'), findsOneWidget);
      expect(find.text('Whisky500 × 1'), findsNothing);
      await tester.tap(find.text('Package B'));
      await tester.pump();
      expect(find.text('Strawberry700 × 4'), findsOneWidget);
      expect(
        find.text('Product variants need binding before serving'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
