import 'support/lifecycle.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/receipt_document.dart';
import 'package:kingclub_cash_register/src/live/receipt_document_dialog.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'receipt_document_test.dart' show document, parse;
import 'staff_session_test.dart' as staff;

class ReceiptAuth extends StaffAuthController {
  ReceiptAuth() {
    final now = DateTime.now();
    identity = StaffSession.fromServer({...staff.response(), 'storeRef': 'TEST_STORE',
      'permissions': ['workbench.read', 'orders.read'], 'expiresAtMs': now.add(const Duration(minutes: 5)).millisecondsSinceEpoch,
      'refreshExpiresAtMs': now.add(const Duration(hours: 1)).millisecondsSinceEpoch},
      base: 'https://service.invalid', deviceId: staff.device, expectedStore: 'TEST_STORE', now: now);
  }
  StaffSession? identity;
  final pending = <Completer<ReceiptDocument>>[];
  @override StaffSession? get session => identity;
  @override Future<ReceiptDocument> readReceiptDocument(String orderRef) {
    final next = Completer<ReceiptDocument>(); pending.add(next); return next.future;
  }
  void invalidate() { identity = null; notifyListeners(); }
}
void main() {
  Future<void> mount(WidgetTester tester, ReceiptAuth auth) async {
    await transitionLifecycle(tester, AppLifecycleState.resumed);
    tester.view.physicalSize = const Size(1366, 768); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(auth.dispose);
    await tester.pumpWidget(MaterialApp(home: ReceiptDocumentDialog(auth: auth,
      orderRef: 'D00000000001', tableRef: 'TEST_TABLE', sessionRef: 'TEST_SESSION', language: UiLanguage.zh)));
  }
  testWidgets('reads server document and expires without automatic reread', (tester) async {
    final auth = ReceiptAuth(); await mount(tester, auth);
    auth.pending.single.complete(parse(document(channel: 'member_balance', refund: true)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('receipt-document-content')), findsOneWidget);
    expect(find.text('退款后净收款: CNY 0.00'), findsOneWidget);
    expect(find.text('原扣本金: CNY 0.80'), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    expect(find.byKey(const ValueKey('receipt-document-content')), findsNothing);
    expect(auth.pending, hasLength(1));
  });
  testWidgets('session change discards in-flight financial content', (tester) async {
    final auth = ReceiptAuth(); await mount(tester, auth);
    auth.invalidate(); auth.pending.single.complete(parse(document()));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('receipt-document-content')), findsNothing);
  });
  testWidgets('background clears content and resume requires explicit refresh', (tester) async {
    final auth = ReceiptAuth(); await mount(tester, auth);
    auth.pending.single.complete(parse(document())); await tester.pumpAndSettle();
    await transitionLifecycle(tester, AppLifecycleState.paused); await tester.pump();
    expect(find.byKey(const ValueKey('receipt-document-content')), findsNothing);
    await transitionLifecycle(tester, AppLifecycleState.resumed); await tester.pump();
    expect(auth.pending, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('receipt-document-refresh'))); await tester.pump();
    expect(auth.pending, hasLength(2));
    auth.pending.last.complete(parse(document())); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('receipt-document-content')), findsOneWidget);
  });
  testWidgets('wrong table/session never displays a financial record', (tester) async {
    final auth = ReceiptAuth(); await mount(tester, auth);
    final raw = document()..['sessionRef'] = 'OTHER_SESSION';
    auth.pending.single.complete(parse(raw)); await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('receipt-document-content')), findsNothing);
    expect(find.text(tr(UiLanguage.zh, 'receiptDocumentFailed')), findsOneWidget);
  });
}
