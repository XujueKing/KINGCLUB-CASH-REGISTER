import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/cash_command.dart';
import 'package:kingclub_cash_register/src/live/live_cash_recovery_panel.dart';
import 'package:kingclub_cash_register/src/live/live_tables_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'cash_command_test.dart' as c;
import 'support/table_fixture.dart';

class CashAuth extends StaffAuthController {
  @override
  StaffSession? session = c.identity;
  PendingCash command = c.bound(c.command());
  late List<PendingCash> entries = [command];
  int queries = 0, confirms = 0, closes = 0;
  bool failRead = false, failCall = false;
  Completer<CashResult>? gate;
  @override
  Future<Object?> readWorkbench({String? afterTable}) async => tableFixture();
  @override
  Future<List<PendingCash>> pendingCash() async {
    if (failRead) throw StateError('PRIVATE_STORAGE');
    return session == null ? [] : entries;
  }

  CashResult observation() => CashResult.parse(
    {'result': c.observed(command)},
    command,
    response: CashResponse.lookup,
  );
  @override
  Future<CashResult> recoverCash(
    String id, {
    bool retryOriginalPreparation = false,
  }) async {
    expect(id, command.requestId);
    queries++;
    if (failCall) throw StateError('PRIVATE_TRANSPORT');
    return gate?.future ?? observation();
  }

  @override
  Future<CashResult> confirmCash(
    String id, {
    required int receivedCents,
    required bool cashReceivedConfirmed,
  }) async {
    expect(id, command.requestId);
    expect(cashReceivedConfirmed, true);
    expect(receivedCents, 200);
    confirms++;
    command = command.recordConfirmation(
      receivedCents,
      cashReceivedConfirmed: true,
    );
    entries = [command];
    if (failCall) throw StateError('PRIVATE_TRANSPORT');
    entries = [];
    return CashResult.parse(
      {'result': c.receipt(command)},
      command,
      response: CashResponse.confirm,
    );
  }

  @override
  Future<CashResult> closeCash(
    String id, {
    bool noCashCollectedConfirmed = false,
    bool cashReturnedConfirmed = false,
  }) async {
    expect(id, command.requestId);
    expect(noCashCollectedConfirmed != cashReturnedConfirmed, true);
    closes++;
    command = command.recordClosure(
      noCashCollectedConfirmed: noCashCollectedConfirmed,
      cashReturnedConfirmed: cashReturnedConfirmed,
    );
    entries = [];
    return CashResult.parse(
      {'result': c.closure(command)},
      command,
      response: CashResponse.close,
    );
  }

  void loseIdentity() {
    session = null;
    notifyListeners();
  }
}

Future<void> show(
  WidgetTester tester,
  CashAuth auth, {
  UiLanguage language = UiLanguage.zh,
  bool tables = false,
}) async {
  tester.view.physicalSize = const Size(1024, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(auth.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: tables
            ? LiveTablesPanel(
                auth: auth,
                language: language,
                enableRealtime: false,
              )
            : LiveCashRecoveryPanel(
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
  testWidgets(
    'recorded cash return requires original lookup and explicit return confirmation',
    (tester) async {
      final auth = CashAuth();
      auth.command = auth.command.recordConfirmation(
        200,
        cashReceivedConfirmed: true,
      );
      auth.entries = [auth.command];
      await show(tester, auth);
      final id = auth.command.requestId;
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(ValueKey('cash-return-$id')))
            .onPressed,
        isNull,
      );
      await tap(tester, 'cash-query-$id');
      await tap(tester, 'cash-return-$id');
      expect(auth.closes, 0);
      expect(find.text(tr(UiLanguage.zh, 'cashReturnNotice')), findsOneWidget);
      await tap(tester, 'cash-decision-confirm');
      expect(auth.closes, 1);
      expect(auth.command.receivedCents, 200);
      expect(auth.command.closeRequested, isTrue);
    },
  );

  for (final lang in UiLanguage.values) {
    testWidgets('cash confirmation layout and exact cents ${lang.name}', (
      tester,
    ) async {
      final auth = CashAuth();
      await show(tester, auth, language: lang);
      final id = auth.command.requestId;
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(ValueKey('cash-pay-$id')))
            .onPressed,
        isNull,
      );
      await tap(tester, 'cash-query-$id');
      await tap(tester, 'cash-pay-$id');
      expect(auth.confirms, 0);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('cash-decision-confirm')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('cash-received-input')),
        '0.99',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('cash-decision-confirm')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const ValueKey('cash-received-input')),
        '2.00',
      );
      await tester.pumpAndSettle();
      expect(find.text('${tr(lang, 'cashChange')}: CNY 1.00'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tap(tester, 'cash-decision-confirm');
      expect(auth.confirms, 1);
      expect(find.text(tr(lang, 'cashEmpty')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'closure requires explicit non-collection dialog and is not a refund',
    (tester) async {
      final auth = CashAuth();
      await show(tester, auth);
      await tap(tester, 'cash-close-${auth.command.requestId}');
      expect(auth.closes, 0);
      expect(find.text(tr(UiLanguage.zh, 'cashCloseNotice')), findsOneWidget);
      await tap(tester, 'cash-decision-confirm');
      expect(auth.closes, 1);
      expect(find.text(tr(UiLanguage.zh, 'cashClosed')), findsOneWidget);
    },
  );
  testWidgets('auth change dismisses old confirmation without sending', (
    tester,
  ) async {
    final auth = CashAuth();
    await show(tester, auth);
    await tap(tester, 'cash-query-${auth.command.requestId}');
    await tap(tester, 'cash-pay-${auth.command.requestId}');
    await tester.enterText(
      find.byKey(const ValueKey('cash-received-input')),
      '2',
    );
    auth.loseIdentity();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(auth.confirms, 0);
    expect(find.text(auth.command.orderRef), findsNothing);
  });
  testWidgets('background dismisses a pending cash decision', (tester) async {
    final auth = CashAuth();
    await show(tester, auth);
    await tap(tester, 'cash-close-${auth.command.requestId}');
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(auth.closes, 0);
    expect(find.text(auth.command.orderRef), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(auth.closes, 0);
  });
  testWidgets('lookup in flight disables every money button', (tester) async {
    final auth = CashAuth()..gate = Completer<CashResult>();
    await show(tester, auth);
    await tester.tap(
      find.byKey(ValueKey('cash-query-${auth.command.requestId}')),
    );
    await tester.pump();
    for (final action in ['query', 'pay', 'close']) {
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(ValueKey('cash-$action-${auth.command.requestId}')),
            )
            .onPressed,
        isNull,
      );
    }
    auth.gate!.complete(auth.observation());
    await tester.pumpAndSettle();
    expect(auth.confirms + auth.closes, 0);
  });
  testWidgets(
    'failed confirmation keeps local receipt status and exposes no private error',
    (tester) async {
      final auth = CashAuth();
      await show(tester, auth);
      final id = auth.command.requestId;
      await tap(tester, 'cash-query-$id');
      await tap(tester, 'cash-pay-$id');
      await tester.enterText(
        find.byKey(const ValueKey('cash-received-input')),
        '2.00',
      );
      await tester.pumpAndSettle();
      auth.failCall = true;
      await tap(tester, 'cash-decision-confirm');
      expect(
        find.text(tr(UiLanguage.zh, 'cashDecisionReceived')),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey('cash-close-$id')), findsNothing);
      expect(find.textContaining('PRIVATE_'), findsNothing);
    },
  );
  testWidgets('load error never pretends to be empty', (tester) async {
    final auth = CashAuth()..failRead = true;
    await show(tester, auth);
    expect(find.text(tr(UiLanguage.zh, 'cashLoadFailed')), findsOneWidget);
    expect(find.text(tr(UiLanguage.zh, 'cashEmpty')), findsNothing);
  });
  testWidgets(
    'authorized workbench opens recovery without any payment command',
    (tester) async {
      final auth = CashAuth();
      await show(tester, auth, tables: true);
      await tester.tap(find.byKey(const ValueKey('table-tools')));
      await tester.pumpAndSettle();
      await tap(tester, 'cash-recovery-open');
      expect(find.byType(LiveCashRecoveryPanel), findsOneWidget);
      expect(auth.queries + auth.confirms + auth.closes, 0);
    },
  );
}
