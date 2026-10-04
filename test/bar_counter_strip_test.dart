import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/bar_counter_strip.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';

import 'support/table_fixture.dart';

void main() {
  testWidgets(
    'B2+B3+B4 replaces three seats with one wide button and sums only their amounts',
    (tester) async {
      final fixture = tableFixture();
      final table =
          Map<String, dynamic>.from(fixture['result']['tables'][0] as Map)
            ..['maximumSeats'] = 8
            ..['session'] = null;
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              child: BarCounterStrip(
                table: LiveTable(table),
                groups: const [
                  [2, 3, 4],
                ],
                seatAmounts: const {1: 100, 2: 200, 3: 300, 4: 400},
                onSeat: (n) => selected = n,
              ),
            ),
          ),
        ),
      );
      expect(find.text('B2+B3+B4'), findsOneWidget);
      expect(find.byKey(const ValueKey('bar-seat-3')), findsNothing);
      expect(find.byKey(const ValueKey('bar-seat-4')), findsNothing);
      expect(find.text('¥ 9.00'), findsOneWidget);
      final merged = tester.getSize(find.byKey(const ValueKey('bar-seat-2')));
      final single = tester.getSize(find.byKey(const ValueKey('bar-seat-1')));
      expect(merged.width, greaterThan(single.width * 2.9));
      await tester.tap(find.text('B2+B3+B4'));
      expect(selected, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
