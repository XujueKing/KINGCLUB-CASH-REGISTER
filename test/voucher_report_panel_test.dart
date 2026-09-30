import 'support/lifecycle.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/voucher_report.dart';
import 'package:kingclub_cash_register/src/live/voucher_report_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'staff_session_test.dart' as staff;

class ReportAuth extends StaffAuthController {
  ReportAuth({
    bool allowed = true,
    Duration lifetime = const Duration(minutes: 10),
  }) {
    final now = DateTime.now();
    identity = StaffSession.fromServer(
      {
        ...staff.response(),
        'permissions': [
          'workbench.read',
          if (allowed) 'report.read' else 'orders.read',
        ],
        'expiresAtMs': now.add(lifetime).millisecondsSinceEpoch,
        'refreshExpiresAtMs': now
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      },
      base: 'https://service.invalid/prefix',
      deviceId: staff.device,
      expectedStore: 'test-store',
      now: now,
    );
  }
  StaffSession? identity;
  @override
  StaffSession? get session => identity;
  int reads = 0;
  bool fail = false;
  Completer<void>? pending;
  @override
  Future<Object?> readVoucherReport({
    required String from,
    required String to,
    String provider = 'all',
    String? afterVoucher,
  }) async {
    reads++;
    await pending?.future;
    if (fail) throw StateError('TEST_PRIVATE_REPORT_ERROR');
    return {
      'result': {
        'storeRef': 'test-store',
        'from': from,
        'to': to,
        'provider': provider,
        'currency': 'CNY',
        'details': <Object?>[],
        'nextAfterVoucher': null,
        for (final key in VoucherReport.amountKeys) key: '0',
        for (final key in VoucherReport.countKeys) key: 0,
        'verifiedCount': 37,
      },
    };
  }
}

void main() {
  Future<void> mount(WidgetTester tester, ReportAuth auth) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: VoucherReportPanel(
          auth: auth,
          language: UiLanguage.en,
          onBack: () {},
        ),
      ),
    ),
  );
  Future<void> cleanup(WidgetTester tester, ReportAuth auth) async {
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
    await transitionLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
  }

  for (final inFlight in [false, true]) {
    testWidgets(
      'session expiry clears report without retry, inFlight=$inFlight',
      (tester) async {
        await transitionLifecycle(tester, AppLifecycleState.resumed);
        final auth = ReportAuth(lifetime: const Duration(seconds: 30));
        if (inFlight) auth.pending = Completer<void>();
        await mount(tester, auth);
        if (inFlight) {
          await tester.pump();
        } else {
          await tester.pumpAndSettle();
          expect(find.text('37'), findsOneWidget);
        }
        await tester.pump(const Duration(seconds: 31));
        if (inFlight) auth.pending!.complete();
        await tester.pumpAndSettle();
        expect(find.text('37'), findsNothing);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(auth.reads, 1);
        await cleanup(tester, auth);
      },
    );
  }

  testWidgets('never queries without report permission', (tester) async {
    final auth = ReportAuth(allowed: false);
    await mount(tester, auth);
    await tester.pumpAndSettle();
    expect(auth.reads, 0);
    expect(find.text('37'), findsNothing);
    expect(find.text(tr(UiLanguage.en, 'voucherReportFailed')), findsOneWidget);
    await cleanup(tester, auth);
  });
  testWidgets(
    'does not query on background mount and resumes with a fresh read',
    (tester) async {
      await transitionLifecycle(tester, AppLifecycleState.paused);
      final auth = ReportAuth();
      await mount(tester, auth);
      await tester.pump();
      expect(auth.reads, 0);
      await transitionLifecycle(tester, AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(auth.reads, 1);
      expect(find.text('37'), findsOneWidget);
      await cleanup(tester, auth);
    },
  );
  testWidgets(
    'background clears displayed totals and ignores an in-flight read',
    (tester) async {
      final auth = ReportAuth()..pending = Completer<void>();
      await mount(tester, auth);
      await tester.pump();
      await transitionLifecycle(tester, AppLifecycleState.paused);
      auth.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('37'), findsNothing);
      auth.pending = null;
      await transitionLifecycle(tester, AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(auth.reads, 2);
      expect(find.text('37'), findsOneWidget);
      await transitionLifecycle(tester, AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(find.text('37'), findsNothing);
      await cleanup(tester, auth);
    },
  );
  testWidgets(
    'session invalidation rejects late results and leaves no old totals',
    (tester) async {
      final auth = ReportAuth()..pending = Completer<void>();
      await mount(tester, auth);
      await tester.pump();
      auth.identity = null;
      auth.notifyListeners();
      auth.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('37'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await cleanup(tester, auth);
    },
  );
  testWidgets(
    'failed refresh removes old results and never exposes raw errors',
    (tester) async {
      final auth = ReportAuth();
      await mount(tester, auth);
      await tester.pumpAndSettle();
      expect(find.text('37'), findsOneWidget);
      auth.fail = true;
      await tester.tap(find.text(tr(UiLanguage.en, 'ordersRefresh')));
      await tester.pumpAndSettle();
      expect(find.text('37'), findsNothing);
      expect(find.textContaining('TEST_PRIVATE_REPORT_ERROR'), findsNothing);
      expect(
        find.text(tr(UiLanguage.en, 'voucherReportFailed')),
        findsOneWidget,
      );
      await cleanup(tester, auth);
    },
  );
}
