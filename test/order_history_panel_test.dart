import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/order_history_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;

class HistoryAuth extends TableAuth {
  HistoryAuth() : super(permissions: ['workbench.read', 'orders.read']);
  final queries = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> readOrderHistory({
    required String from,
    required String to,
    String search = '',
    String status = 'all',
    int page = 0,
  }) async {
    queries.add({
      'from': from,
      'to': to,
      'search': search,
      'status': status,
      'page': page,
    });
    return {
      'storeName': 'Test store',
      'totalCount': 2,
      'totalCents': 3000,
      'orders': [
        for (var i = 1; i <= 2; i++)
          {
            'orderRef': 'D0000000000$i',
            'tableName': 'V$i',
            'totalCents': i * 1000,
            'paidCents': i * 1000,
            'dueCents': 0,
            'refundCents': 0,
            'status': 'paid',
            'origin': 'app',
            'cashierName': '',
            'partySize': 2,
            'paymentMethod': 'wechat',
            'createdAt': '2026-10-06T02:00:00Z',
            'paidAt': '2026-10-06T02:01:00Z',
            'items': [
              {
                'quantity': 1,
                'priceCents': i * 1000,
                'subtotalCents': i * 1000,
                'snapshot': {
                  'names': {'zh-CN': '测试商品$i'},
                  'specifications': {'zh-CN': '500ML'},
                },
              },
            ],
          },
      ],
    };
  }
}

void main() {
  testWidgets(
    'switching historical rows is local and read-only at cashier resolution',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = HistoryAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OrderHistoryPanel(auth: auth, language: UiLanguage.zh),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('测试商品1'), findsOneWidget);
      expect(auth.queries.length, 1);
      await tester.tap(find.text('V2'));
      await tester.pumpAndSettle();
      expect(find.text('测试商品2'), findsOneWidget);
      expect(find.text('测试商品1'), findsNothing);
      expect(auth.queries.length, 1);
      expect(find.text('补打小票'), findsOneWidget);
      expect(find.text('整桌结账'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('昨日'));
      await tester.pumpAndSettle();
      expect(auth.queries.length, 2);
      expect(auth.queries.last['from'], auth.queries.last['to']);
      await tester.enterText(find.byType(TextField), 'V1');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(auth.queries.last['search'], 'V1');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('自选日期'));
      await tester.pumpAndSettle();
      expect(find.text('确定'), findsOneWidget);
      expect(find.text('Save'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
