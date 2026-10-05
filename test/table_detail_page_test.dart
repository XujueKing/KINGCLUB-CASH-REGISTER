import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/live_order_members_panel.dart';
import 'package:kingclub_cash_register/src/live/table_detail_snapshot.dart';
import 'package:kingclub_cash_register/src/live/table_bill_panel.dart';
import 'package:kingclub_cash_register/src/live/cart_draft.dart';
import 'package:kingclub_cash_register/src/live/order_command.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart';
import 'support/order_fixture.dart';
import 'order_context_test.dart' as ctx;

class DetailAuth extends TableAuth {
  DetailAuth()
    : super(permissions: ['workbench.read', 'orders.read', 'orders.create']);
  int detailReads = 0;
  final detailGate = Completer<TableDetailSnapshot>();
  @override
  Future<TableDetailSnapshot> readTableDetail({
    required String tableRef,
    required String sessionRef,
  }) {
    detailReads++;
    return detailGate.future;
  }

  @override
  Future<List<CartDraft>> cartDrafts() async => [];
  @override
  Future<List<PendingOrder>> pendingOrders() async => [];
}

Map<String, dynamic> detailFixture() {
  final value = orderFixture();
  (value['result']['session'] as Map)['sessionRef'] = 'H00000000001';
  (value['result'] as Map)['workspace'] = {
    'context': {
      ...ctx.contextData(),
      'tableRef': 'test-000',
      'tableName': 'V1',
      'session': <String, dynamic>{
        ...ctx.contextData()['session'] as Map<String, dynamic>,
        'sessionRef': 'H00000000001',
      },
      'tableOrderAllowed': true,
    },
    'members': [
      {
        'userAccount': 'KM00000000001',
        'nickname': 'Test member',
        'avatarBase64': null,
      },
    ],
    'storedWine': [
      {
        'itemRef': 'bottle-one',
        'name': 'Stored wine',
        'remainingPercent': 25,
        'served': false,
      },
    ],
    'products': [],
  };
  return value;
}

void main() {
  testWidgets(
    'one page request supplies context, bill, stored bottles and member badge',
    (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = DetailAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveOrderMembersPanel(
              auth: auth,
              language: UiLanguage.zh,
              tableRef: 'test-000',
              sessionRef: 'H00000000001',
              onBack: () {},
              tablePanel: const SizedBox(),
            ),
          ),
        ),
      );
      expect(auth.detailReads, 1);
      auth.detailGate.complete(
        TableDetailSnapshot.parse(
          detailFixture(),
          storeRef: 'test-store',
          tableRef: 'test-000',
          sessionRef: 'H00000000001',
        ),
      );
      await tester.pumpAndSettle();
      expect(auth.detailReads, 1);
      expect(find.text('测试商品'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('stored-wine-bottle-one')),
        findsOneWidget,
      );
      expect(find.byType(TableBillPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  test(
    'page parser rejects another table and accepts more than one legacy page',
    () {
      final raw = detailFixture(), result = raw['result'] as Map;
      final item = (result['orders'] as List).first as Map;
      result.remove('sessionSummary');
      result['orders'] = List.generate(
        21,
        (i) => <String, dynamic>{
          ...Map<String, dynamic>.from(item),
          'orderRef': 'D${i.toString().padLeft(11, '0')}',
        },
      );
      expect(
        TableDetailSnapshot.parse(
          raw,
          storeRef: 'test-store',
          tableRef: 'test-000',
          sessionRef: 'H00000000001',
        ).bill.orders.length,
        21,
      );
      expect(
        () => TableDetailSnapshot.parse(
          raw,
          storeRef: 'another-store',
          tableRef: 'test-000',
          sessionRef: 'H00000000001',
        ),
        throwsFormatException,
      );
    },
  );
}
