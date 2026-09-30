import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/voucher_lookup.dart';
import 'package:kingclub_cash_register/src/live/voucher_lookup_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'staff_session_test.dart' as staff;
import 'voucher_lookup_test.dart' as data;
import 'support/lifecycle.dart';

class LookupAuth extends StaffAuthController {
  LookupAuth({
    bool allowed = true,
    Duration lifetime = const Duration(minutes: 5),
  }) {
    final now = DateTime.now();
    identity = StaffSession.fromServer(
      {
        ...staff.response(),
        'permissions': ['workbench.read', if (allowed) 'voucher.douyin'],
        'expiresAtMs': now.add(lifetime).millisecondsSinceEpoch,
        'refreshExpiresAtMs': now
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      },
      base: 'https://service.invalid',
      deviceId: staff.device,
      expectedStore: 'test-store',
      now: now,
    );
  }
  StaffSession? identity;
  @override
  StaffSession? get session => identity;
  final pending = <Completer<VoucherLookup>>[];
  @override
  Future<VoucherLookup> lookupVoucher({
    required String provider,
    required String requestId,
  }) {
    expect(provider, 'douyin');
    expect(requestId, data.requestId);
    final response = Completer<VoucherLookup>();
    pending.add(response);
    return response.future;
  }

  VoucherLookup receipt() => VoucherLookup.parse(
    {
      'result': {...data.fixture(), 'storeRef': 'test-store'},
    },
    storeRef: 'test-store',
    employeeRef: 'E00000000001',
    provider: 'douyin',
    requestId: data.requestId,
  );
}

void main() {
  void expiryTests() {
    for (final pendingAtExpiry in [false, true]) {
      testWidgets('session expiry clears lookup, pending=$pendingAtExpiry', (
        tester,
      ) async {
        final auth = LookupAuth(lifetime: const Duration(seconds: 30));
        addTearDown(auth.dispose);
        await transitionLifecycle(tester, AppLifecycleState.resumed);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: VoucherLookupPanel(
                auth: auth,
                language: UiLanguage.en,
                onBack: () {},
              ),
            ),
          ),
        );
        await tester.tap(find.byType(ChoiceChip));
        await tester.enterText(find.byType(TextField), data.requestId);
        await tester.pump();
        await tester.tap(
          find.widgetWithText(
            OutlinedButton,
            tr(UiLanguage.en, 'voucherLookupRead'),
          ),
        );
        await tester.pump();
        if (!pendingAtExpiry) {
          auth.pending.single.complete(auth.receipt());
          await tester.pumpAndSettle();
          expect(find.textContaining('TEST_CERT'), findsOneWidget);
        }
        await tester.pump(const Duration(seconds: 31));
        if (pendingAtExpiry) {
          auth.pending.single.complete(auth.receipt());
          await tester.pumpAndSettle();
        }
        expect(find.textContaining('TEST_CERT'), findsNothing);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(auth.pending, hasLength(1));
      });
    }
  }

  expiryTests();
  Future<void> mount(WidgetTester tester, LookupAuth auth) async {
    await transitionLifecycle(tester, AppLifecycleState.resumed);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoucherLookupPanel(
            auth: auth,
            language: UiLanguage.en,
            onBack: () {},
          ),
        ),
      ),
    );
  }

  Finder read() => find.widgetWithText(
    OutlinedButton,
    tr(UiLanguage.en, 'voucherLookupRead'),
  );
  Future<void> select(WidgetTester tester) async {
    await tester.tap(find.byType(ChoiceChip));
    await tester.enterText(find.byType(TextField), data.requestId);
    await tester.pump();
  }

  Future<void> query(WidgetTester tester) async {
    await select(tester);
    await tester.tap(read());
    await tester.pump();
  }

  testWidgets(
    'permission, UUID and explicit click are required; Enter never queries',
    (tester) async {
      final denied = LookupAuth(allowed: false);
      await mount(tester, denied);
      expect(find.byType(ChoiceChip), findsNothing);
      await tester.enterText(find.byType(TextField), data.requestId);
      await tester.pump();
      expect(tester.widget<OutlinedButton>(read()).onPressed, isNull);
      expect(denied.pending, isEmpty);
      final auth = LookupAuth();
      await mount(tester, auth);
      expect(auth.pending, isEmpty);
      await tester.tap(find.byType(ChoiceChip));
      await tester.enterText(
        find.byType(TextField),
        'TEST_COUPON_NOT_REQUEST_UUID',
      );
      await tester.pump();
      expect(tester.widget<OutlinedButton>(read()).onPressed, isNull);
      await select(tester);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(auth.pending, isEmpty);
      await tester.tap(read());
      await tester.pump();
      expect(auth.pending, hasLength(1));
      expect(tester.widget<OutlinedButton>(read()).onPressed, isNull);
      auth.pending.single.complete(auth.receipt());
      await tester.pumpAndSettle();
      expect(
        find.text(tr(UiLanguage.en, 'voucherLookupSuccess')),
        findsOneWidget,
      );
      expect(
        find.text(tr(UiLanguage.en, 'voucherLookupNotSuccess')),
        findsOneWidget,
      );
      expect(find.text('1208'), findsOneWidget);
    },
  );
  testWidgets('logout clears locator and rejects a late receipt', (
    tester,
  ) async {
    final auth = LookupAuth();
    await mount(tester, auth);
    await query(tester);
    auth.identity = null;
    auth.notifyListeners();
    auth.pending.single.complete(auth.receipt());
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(find.textContaining('TEST_CERT'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(auth.pending, hasLength(1));
  });
  testWidgets(
    'replacing auth rejects old responses and detaches old listener',
    (tester) async {
      final old = LookupAuth();
      await mount(tester, old);
      await query(tester);
      final current = LookupAuth();
      await mount(tester, current);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await query(tester);
      old.notifyListeners();
      old.pending.single.complete(old.receipt());
      await tester.pump();
      expect(find.textContaining('TEST_CERT'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        data.requestId,
      );
      current.pending.single.complete(current.receipt());
      await tester.pumpAndSettle();
      expect(find.textContaining('TEST_CERT'), findsOneWidget);
      expect(current.pending, hasLength(1));
    },
  );
  testWidgets('leaving panel safely ignores a late query failure', (
    tester,
  ) async {
    final auth = LookupAuth();
    await mount(tester, auth);
    await query(tester);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    auth.pending.single.completeError(StateError('TEST_PRIVATE_ERROR'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(auth.pending, hasLength(1));
  });
  testWidgets('background discards late receipt; resume does not query again', (
    tester,
  ) async {
    final auth = LookupAuth();
    await mount(tester, auth);
    await query(tester);
    await transitionLifecycle(tester, AppLifecycleState.paused);
    auth.pending.single.complete(auth.receipt());
    await tester.pump();
    await transitionLifecycle(tester, AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.textContaining('TEST_CERT'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(auth.pending, hasLength(1));
    expect(tester.widget<OutlinedButton>(read()).onPressed, isNull);
  });
  testWidgets(
    'failed refresh removes old results without leaking errors or auto retry',
    (tester) async {
      final auth = LookupAuth();
      await mount(tester, auth);
      await query(tester);
      auth.pending.single.complete(auth.receipt());
      await tester.pumpAndSettle();
      expect(find.textContaining('TEST_CERT'), findsOneWidget);
      await tester.tap(read());
      await tester.pump();
      expect(find.textContaining('TEST_CERT'), findsNothing);
      auth.pending.last.completeError(StateError('TEST_PRIVATE_ERROR'));
      await tester.pumpAndSettle();
      expect(
        find.text(tr(UiLanguage.en, 'voucherReportFailed')),
        findsOneWidget,
      );
      expect(find.textContaining('TEST_PRIVATE_ERROR'), findsNothing);
      expect(auth.pending, hasLength(2));
    },
  );
}
