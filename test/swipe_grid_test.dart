import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/src/live/swipe_grid.dart';

void main() {
  testWidgets('local swipes retain items and fetch only after last viewport', (tester) async {
    var next = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(
      width: 400, height: 300,
      child: SwipeGrid(columns: 2, tileHeight: 100, itemCount: 6,
        itemBuilder: (_, i) => Text('Item $i'), loading: false,
        hasPrevious: false, hasNext: true,
        onPrevious: () => fail('No previous server page'), onNext: () => next++),
    ))));
    expect(find.text('Item 0'), findsOneWidget);
    expect(find.text('Item 4'), findsNothing);
    await tester.drag(find.byKey(const ValueKey('swipe-pages')), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(find.text('Item 4'), findsOneWidget);
    expect(next, 0);
    await tester.drag(find.byKey(const ValueKey('swipe-pages')), const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(find.text('Item 0'), findsOneWidget);
    await tester.drag(find.byKey(const ValueKey('swipe-pages')), const Offset(-200, 0));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('swipe-pages')), const Offset(-200, 0));
    await tester.pumpAndSettle();
    expect(next, 1);
    expect(tester.takeException(), isNull);
  });
}
