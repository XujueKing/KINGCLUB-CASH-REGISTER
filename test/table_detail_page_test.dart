import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/live_order_members_panel.dart';
import 'package:kingclub_cash_register/src/live/table_detail_snapshot.dart';
import 'package:kingclub_cash_register/src/live/table_bill_panel.dart';
import 'package:kingclub_cash_register/src/live/live_catalog_panel.dart';
import 'package:kingclub_cash_register/src/live/catalog_snapshot.dart';
import 'package:kingclub_cash_register/src/live/cart_draft.dart';
import 'package:kingclub_cash_register/src/live/order_command.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart';
import 'support/order_fixture.dart';
import 'order_context_test.dart' as ctx;
import 'catalog_snapshot_test.dart' as catalog;

class DetailAuth extends TableAuth {
  DetailAuth()
    : super(permissions: ['workbench.read', 'orders.read', 'orders.create']);
  int detailReads = 0;
  int catalogReads = 0;
  Completer<List<PendingOrder>>? pendingGate;
  var detailGate = Completer<TableDetailSnapshot>();
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
  Future<List<PendingOrder>> pendingOrders() async =>
      pendingGate == null ? [] : pendingGate!.future;

  @override
  Future<CatalogSnapshot> readCatalog({
    String? categoryRef,
    String? afterProduct,
  }) async {
    catalogReads++;
    throw StateError('Catalog must not be read until ordering is opened');
  }
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
    'products': [
      {
        ...catalog.product('test-product'),
        'priceCents': 600,
        'inventoryKnown': true,
        'available': 3,
        'soldOut': false,
      },
    ],
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
      expect(auth.catalogReads, 0);
      expect(find.byType(LiveCatalogPanel, skipOffstage: false), findsNothing);
      expect(
        find.byKey(const ValueKey('stored-wine-bottle-one')),
        findsOneWidget,
      );
      expect(find.byType(TableBillPanel), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Adding an existing bill product uses the product already in the page
      // response; neither another catalog request nor a grey busy frame.
      final plus = find.byKey(const ValueKey('cart-plus-test-product'));
      await tester.tap(plus);
      await tester.pump();
      expect(tester.widget<IconButton>(plus).onPressed, isNotNull);
      expect(
        tester.widget<TableBillPanel>(find.byType(TableBillPanel)).draftCents,
        600,
      );
      expect(auth.catalogReads, 0);
      await tester.tap(find.byKey(const ValueKey('cart-minus-test-product')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-toggle-menu')));
      await tester.pumpAndSettle();
      expect(auth.catalogReads, 1);
      expect(find.byType(LiveCatalogPanel), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('workspace-toggle-menu')));
      await tester.pumpAndSettle();
      expect(find.byType(LiveCatalogPanel, skipOffstage: false), findsNothing);
      expect(auth.detailReads, 1);
      await tester.pumpWidget(const SizedBox());
      // Returning to the same table paints its cached bill without waiting for
      // either the fresh snapshot or an invisible product catalog.
      auth.detailGate = Completer<TableDetailSnapshot>();
      auth.pendingGate = Completer<List<PendingOrder>>();
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
      await tester.pump();
      expect(auth.detailGate.isCompleted, isFalse);
      expect(auth.detailReads, 2);
      expect(auth.catalogReads, 1);
      expect(
        find.byKey(const ValueKey('stored-wine-bottle-one')),
        findsOneWidget,
      );
      expect(find.byType(LiveCatalogPanel, skipOffstage: false), findsNothing);
      expect(tester.takeException(), isNull);
      expect(tester.widget<IconButton>(plus).onPressed, isNotNull);
      await tester.tap(plus);
      await tester.pump();
      expect(
        tester.widget<TableBillPanel>(find.byType(TableBillPanel)).draftCents,
        0,
      );
      auth.pendingGate!.complete([]);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TableBillPanel>(find.byType(TableBillPanel)).draftCents,
        600,
      );
      // Cached stock permits local selection, never submission before validation.
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('cart-submit')))
            .onPressed,
        isNull,
      );
      expect(auth.catalogReads, 1);
      expect(auth.detailReads, 2);
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
