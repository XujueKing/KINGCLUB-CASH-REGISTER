import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/live_order_recovery_panel.dart';
import 'package:kingclub_cash_register/src/live/live_tables_panel.dart';
import 'package:kingclub_cash_register/src/live/order_command.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'order_command_test.dart' as fixture;
import 'support/table_fixture.dart';

class RecoveryAuth extends StaffAuthController {
  @override
  StaffSession? session = fixture.identity;
  final command = fixture.command();
  late List<PendingOrder> entries = [command];
  int queries = 0, retries = 0, cancels = 0;
  bool failRead = false, failCall = false;
  String state = 'not_observed';
  Completer<OrderRequestResult>? gate;
  @override
  Future<Object?> readWorkbench({String? afterTable}) async => tableFixture();
  @override
  Future<List<PendingOrder>> pendingOrders() async {
    if (failRead) throw StateError('PRIVATE_STORAGE_ERROR');
    return session == null ? [] : entries;
  }

  OrderRequestResult result(String value) => OrderRequestResult.parse({
    'result': {
      'state': value,
      'requestId': command.requestId,
      if (value == 'confirmed') 'receipt': fixture.receipt(command.params),
    },
  }, command);

  @override
  Future<OrderRequestResult> recoverOrder(
    String requestId, {
    bool retryOriginal = false,
  }) async {
    expect(requestId, command.requestId);
    retryOriginal ? retries++ : queries++;
    if (failCall) throw StateError('PRIVATE_TRANSPORT_ERROR');
    if (gate != null) return gate!.future;
    if (state != 'not_observed') entries = [];
    return result(state);
  }

  @override
  Future<OrderRequestResult> cancelOrder(
    String requestId, {
    required bool confirmed,
  }) async {
    expect(confirmed, isTrue);
    expect(requestId, command.requestId);
    cancels++;
    entries = [];
    return result(state == 'confirmed' ? 'confirmed' : 'cancelled');
  }

  void loseIdentity() {
    session = null;
    notifyListeners();
  }
}

Future<void> show(
  WidgetTester tester,
  RecoveryAuth auth, {
  UiLanguage language = UiLanguage.zh,
  bool tables = false,
}) async {
  tester.view.physicalSize = const Size(1024, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: tables
            ? LiveTablesPanel(
                auth: auth,
                language: language,
                enableRealtime: false,
              )
            : LiveOrderRecoveryPanel(
                auth: auth,
                language: language,
                onBack: () {},
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('in-flight lookup disables all command actions', (tester) async {
    final auth = RecoveryAuth()..gate = Completer<OrderRequestResult>();
    await show(tester, auth);
    final query = find.byKey(
      ValueKey('order-recovery-query-${auth.command.requestId}'),
    );
    await tester.tap(query);
    await tester.pump();
    for (final action in ['query', 'retry', 'cancel']) {
      final button = tester.widget<OutlinedButton>(
        find.byKey(
          ValueKey('order-recovery-$action-${auth.command.requestId}'),
        ),
      );
      expect(button.onPressed, isNull);
    }
    expect(auth.queries, 1);
    expect(auth.retries + auth.cancels, 0);
    auth.gate!.complete(auth.result('not_observed'));
    await tester.pumpAndSettle();
    expect(tester.widget<OutlinedButton>(query).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets('confirmed termination removes request and is not a refund', (
    tester,
  ) async {
    final auth = RecoveryAuth();
    await show(tester, auth);
    await tap(tester, 'order-recovery-cancel-${auth.command.requestId}');
    await tap(tester, 'order-recovery-confirm');
    expect(auth.cancels, 1);
    expect(
      find.text(tr(UiLanguage.zh, 'orderRecoveryCancelled')),
      findsOneWidget,
    );
    expect(find.text(tr(UiLanguage.zh, 'orderRecoveryEmpty')), findsOneWidget);
    expect(
      find.byKey(ValueKey('order-recovery-query-${auth.command.requestId}')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
  testWidgets('workspace recovery entry and lookup do not resubmit', (
    tester,
  ) async {
    final auth = RecoveryAuth();
    await show(tester, auth, tables: true);
    await tap(tester, 'order-recovery-open');
    expect(auth.queries + auth.retries + auth.cancels, 0);
    await tap(tester, 'order-recovery-query-${auth.command.requestId}');
    expect(auth.queries, 1);
    expect(auth.retries + auth.cancels, 0);
    expect(
      find.text(tr(UiLanguage.zh, 'orderRecoveryUnknown')),
      findsNWidgets(2),
    );
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets(
    'retry requires confirmation and one tap cannot queue two calls',
    (tester) async {
      final auth = RecoveryAuth();
      await show(tester, auth);
      await tap(tester, 'order-recovery-retry-${auth.command.requestId}');
      expect(auth.retries, 0);
      await tester.tap(find.text(tr(UiLanguage.zh, 'cancel')));
      await tester.pumpAndSettle();
      expect(auth.retries, 0);
      await tap(tester, 'order-recovery-retry-${auth.command.requestId}');
      await tap(tester, 'order-recovery-confirm');
      expect(auth.retries, 1);
      expect(auth.entries, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets(
    'termination can return confirmed order, never falsely cancelled or paid',
    (tester) async {
      final auth = RecoveryAuth()..state = 'confirmed';
      await show(tester, auth);
      await tap(tester, 'order-recovery-cancel-${auth.command.requestId}');
      expect(auth.cancels, 0);
      await tap(tester, 'order-recovery-confirm');
      expect(auth.cancels, 1);
      expect(
        find.text(tr(UiLanguage.zh, 'orderRecoveryConfirmed')),
        findsOneWidget,
      );
      expect(
        find.text(tr(UiLanguage.zh, 'orderRecoveryCancelled')),
        findsNothing,
      );
      expect(find.text(auth.command.requestId), findsNothing);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets('network errors retain record and hide private exception text', (
    tester,
  ) async {
    final auth = RecoveryAuth()..failCall = true;
    await show(tester, auth);
    await tap(tester, 'order-recovery-query-${auth.command.requestId}');
    expect(auth.entries, hasLength(1));
    expect(
      find.text(tr(UiLanguage.zh, 'orderRecoveryUnconfirmed')),
      findsOneWidget,
    );
    expect(find.textContaining('PRIVATE_'), findsNothing);
    auth.failRead = true;
    await tap(tester, 'order-recovery-refresh');
    expect(find.text(tr(UiLanguage.zh, 'orderRecoveryFailed')), findsOneWidget);
    expect(find.text(tr(UiLanguage.zh, 'orderRecoveryEmpty')), findsNothing);
    expect(auth.entries, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets('identity change during confirmation prevents request', (
    tester,
  ) async {
    final auth = RecoveryAuth();
    await show(tester, auth);
    await tap(tester, 'order-recovery-retry-${auth.command.requestId}');
    auth.loseIdentity();
    await tester.pump();
    await tap(tester, 'order-recovery-confirm');
    expect(auth.retries, 0);
    expect(find.textContaining(auth.command.requestId), findsNothing);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets('backgrounded confirmation is invalid even after resume', (
    tester,
  ) async {
    final auth = RecoveryAuth();
    await show(tester, auth);
    await tap(tester, 'order-recovery-cancel-${auth.command.requestId}');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tap(tester, 'order-recovery-confirm');
    expect(auth.cancels, 0);
    expect(auth.entries, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets('late lookup cannot display another identity result', (
    tester,
  ) async {
    final auth = RecoveryAuth()..gate = Completer<OrderRequestResult>();
    await show(tester, auth);
    await tester.tap(
      find.byKey(ValueKey('order-recovery-query-${auth.command.requestId}')),
    );
    await tester.pump();
    expect(auth.queries, 1);
    auth.loseIdentity();
    auth.gate!.complete(auth.result('confirmed'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('order-recovery-result')), findsNothing);
    expect(find.textContaining(auth.command.requestId), findsNothing);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  for (final language in UiLanguage.values) {
    testWidgets('recovery and confirmation fit ${language.name}', (
      tester,
    ) async {
      final auth = RecoveryAuth();
      await show(tester, auth, language: language);
      expect(find.text(tr(language, 'orderRecoveryTitle')), findsOneWidget);
      await tap(tester, 'order-recovery-retry-${auth.command.requestId}');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(tr(language, 'cancel')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    });
  }
}
