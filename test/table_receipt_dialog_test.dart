import 'support/lifecycle.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/receipt_document.dart';
import 'package:kingclub_cash_register/src/live/table_receipt_dialog.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'staff_session_test.dart' as staff;
import 'table_receipt_document_test.dart' as receipt;

class TableReceiptAuth extends StaffAuthController {
  TableReceiptAuth() {
    final now = DateTime.now();
    identity = StaffSession.fromServer(
      {
        ...staff.response(),
        'storeRef': 'TEST_STORE',
        'permissions': ['workbench.read', 'orders.read'],
        'expiresAtMs': now
            .add(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
        'refreshExpiresAtMs': now
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      },
      base: 'https://service.invalid',
      deviceId: staff.device,
      expectedStore: 'TEST_STORE',
      now: now,
    );
  }
  StaffSession? identity;
  final pending = <Completer<TableReceiptDocument>>[];
  @override
  StaffSession? get session => identity;
  @override
  Future<TableReceiptDocument> readTableReceiptDocument(String checkoutRef) {
    final next = Completer<TableReceiptDocument>();
    pending.add(next);
    return next.future;
  }

  void invalidate() {
    identity = null;
    notifyListeners();
  }
}

void main() {
  Future<void> mount(
    WidgetTester tester,
    TableReceiptAuth auth, {
    String sessionRef = 'TEST_SESSION',
  }) async {
    await transitionLifecycle(tester, AppLifecycleState.resumed);
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: TableReceiptDialog(
          auth: auth,
          checkoutRef: receipt.checkout,
          tableRef: 'TEST_TABLE',
          sessionRef: sessionRef,
          language: UiLanguage.zh,
        ),
      ),
    );
  }

  Future<void> cleanup(WidgetTester tester, TableReceiptAuth auth) async {
    await tester.pumpWidget(const SizedBox.shrink());
    auth.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  const content = ValueKey('table-receipt-content');
  testWidgets(
    'shows one parent tender then expires without automatic refresh',
    (tester) async {
      final auth = TableReceiptAuth();
      await mount(tester, auth);
      auth.pending.single.complete(
        receipt.parse(receipt.tableReceiptFixture()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(content), findsOneWidget);
      await tester.pump(const Duration(seconds: 31));
      expect(find.byKey(content), findsNothing);
      expect(auth.pending, hasLength(1));
      await cleanup(tester, auth);
    },
  );
  testWidgets('logout discards delayed data', (tester) async {
    final auth = TableReceiptAuth();
    await mount(tester, auth);
    auth.invalidate();
    auth.pending.single.complete(receipt.parse(receipt.tableReceiptFixture()));
    await tester.pumpAndSettle();
    expect(find.byKey(content), findsNothing);
    await cleanup(tester, auth);
  });
  testWidgets('background removes data and resume requires explicit refresh', (
    tester,
  ) async {
    final auth = TableReceiptAuth();
    await mount(tester, auth);
    auth.pending.single.complete(receipt.parse(receipt.tableReceiptFixture()));
    await tester.pumpAndSettle();
    await transitionLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    expect(find.byKey(content), findsNothing);
    await transitionLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(auth.pending, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('table-receipt-refresh')));
    await tester.pump();
    auth.pending.last.complete(receipt.parse(receipt.tableReceiptFixture()));
    await tester.pumpAndSettle();
    expect(find.byKey(content), findsOneWidget);
    await cleanup(tester, auth);
  });
  testWidgets(
    'wrong session and changed scope never retain old financial content',
    (tester) async {
      final auth = TableReceiptAuth();
      await mount(tester, auth, sessionRef: 'OTHER_SESSION');
      auth.pending.single.complete(
        receipt.parse(receipt.tableReceiptFixture()),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(content), findsNothing);
      expect(
        find.text(tr(UiLanguage.zh, 'receiptDocumentFailed')),
        findsOneWidget,
      );
      await mount(tester, auth);
      expect(find.byKey(content), findsNothing);
      expect(auth.pending, hasLength(1));
      await cleanup(tester, auth);
    },
  );
}
