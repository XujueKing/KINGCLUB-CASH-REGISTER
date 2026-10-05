import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/business_report_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;

class ReportAuth extends TableAuth {
  ReportAuth() : super(permissions: ['workbench.read', 'report.read']);
  final queries = <Map<String, String>>[];
  bool reportUnavailable = false;
  @override
  Future<Map<String, dynamic>> readBusinessReport({
    required String from,
    required String to,
  }) async {
    queries.add({'from': from, 'to': to});
    if (reportUnavailable) throw Exception('offline');
    return {
      'from': from,
      'to': to,
      'previousFrom': '2026-09-01',
      'previousTo': '2026-09-30',
      'summaries': [
        for (var i = 0; i < 2; i++)
          {
            'period': i,
            'netSalesCents': 12000,
            'settledCents': 12500,
            'giftCents': 500,
            'refunds': 0,
            'refundCents': 0,
            'refundPrincipalCents': 0,
            'couponCents': 0,
            'collections': 5,
            'averageCollectionCents': 2400,
            'guests': 12,
            'openings': 3,
            'anonymousBarSessions': 1,
            'knownCostCents': 3000,
            'unknownCostBatches': 1,
            'unissuedUnits': 0,
            'grossProfitCents': null,
          },
      ],
      'trend': [
        for (var i = 0; i < 24; i++)
          {
            'index': i,
            'label': '$i:00',
            'cents': i == 6 ? -200 : 1200,
            'orders': 2,
          },
      ],
      'channels': [
        {'channel': 'wechat', 'cents': 12000, 'transactions': 5},
      ],
      'products': [
        {
          'productRef': 'test-product',
          'names': {'zh-CN': '测试酒品'},
          'specifications': {'zh-CN': '500ML'},
          'quantity': 5,
          'cents': 12000,
          'orders': 3,
        },
      ],
      'categories': [
        {
          'names': {'zh-CN': '洋酒'},
          'cents': 12000,
          'quantity': 5,
        },
      ],
      'tables': [
        {'name': 'V1', 'cents': 12000, 'collections': 5},
      ],
      'recharge': [
        {
          'channel': 'cash',
          'principalCents': 10000,
          'giftCents': 1000,
          'transactions': 1,
        },
      ],
      'vouchers': [],
      'pendingOrders': 1,
      'pendingCents': 1000,
      'waivedOrders': 0,
    };
  }
}

void main() {
  for (final lang in UiLanguage.values) {
    testWidgets(
      'report fits cashier display in $lang and tabs reuse snapshot',
      (tester) async {
        tester.view.physicalSize = const Size(1274, 710);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final auth = ReportAuth();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BusinessReportPanel(auth: auth, language: lang),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(auth.queries.length, 1);
        expect(tester.takeException(), isNull);
        final labels = [
          ['收入', '商品', '客流', '成本'],
          ['Income', 'Products', 'Guests', 'Costs'],
          ['收入', '商品', '客流', '成本'],
          ['รายรับ', 'สินค้า', 'ลูกค้า', 'ต้นทุน'],
        ][lang.index];
        for (final label in labels) {
          await tester.tap(find.widgetWithText(FilledButton, label).first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(auth.queries.length, 1);
        }
      },
    );
  }
  testWidgets(
    'unknown cost stays unknown and date failure does not mislabel old data',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 710);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = ReportAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BusinessReportPanel(auth: auth, language: UiLanguage.zh),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('待补成本'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '本周'));
      await tester.pumpAndSettle();
      expect(
        DateTime.parse(auth.queries.last['from']!).weekday,
        DateTime.monday,
      );
      auth.reportUnavailable = true;
      await tester.tap(find.widgetWithText(FilledButton, '昨日'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前显示上次结果'), findsOneWidget);
      expect(find.text('报表未能更新，请重试。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
