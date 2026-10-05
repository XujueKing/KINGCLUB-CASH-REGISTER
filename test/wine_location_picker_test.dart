import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/wine_location_picker.dart';

void main() {
  testWidgets('24 cabinet slots show row six at top and row one at bottom', (
    tester,
  ) async {
    String? selected;
    final locations = [
      for (var r = 1; r <= 6; r++)
        for (var c = 1; c <= 4; c++) 'A$r-$c',
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 430,
            child: WineLocationPicker(
              locations: locations,
              selected: null,
              onSelected: (value) => selected = value,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(OutlinedButton), findsNWidgets(24));
    expect(
      tester.getCenter(find.text('A6-1')).dy,
      lessThan(tester.getCenter(find.text('A1-1')).dy),
    );
    expect(
      tester.getCenter(find.text('A1-1')).dx,
      lessThan(tester.getCenter(find.text('A1-4')).dx),
    );
    await tester.tap(find.text('A4-3'));
    expect(selected, 'A4-3');
    expect(tester.takeException(), isNull);
  });
}
