import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/live_table_clear_panel.dart';
import 'package:kingclub_cash_register/src/live/live_tables_panel.dart';
import 'package:kingclub_cash_register/src/live/table_clear_command.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;
import 'support/table_fixture.dart';
import 'staff_session_test.dart' as a;
import 'table_clear_command_test.dart' as c;

class ClearAuth extends TableAuth {
  bool allowed = true, expired = false, failRead = false, failWrite = false;
  final identity = a.session({
    ...a.response(),
    'permissions': ['workbench.read', 'table.clear'],
    'expiresAtMs': DateTime.now()
        .add(const Duration(hours: 1))
        .millisecondsSinceEpoch,
    'refreshExpiresAtMs': DateTime.now()
        .add(const Duration(hours: 12))
        .millisecondsSinceEpoch,
  });
  @override
  StaffSession get session => expired
      ? c.identity
      : allowed
      ? identity
      : a.session();
  int writes = 0, lookups = 0, retries = 0;
  List<PendingTableClear> pending = [];
  Completer<void>? sendGate;
  @override
  Future<List<PendingTableClear>> pendingTableClear() async {
    if (failRead) throw StateError('private error');
    return pending;
  }

  @override
  Future<TableClearResult> confirmTableClear({
    required String tableRef,
    required String sessionRef,
    required bool confirmed,
  }) async {
    expect(confirmed, true);
    writes++;
    final command = PendingTableClear.prepare(
      now: DateTime.now(),
      identity: identity,
      tableRef: tableRef,
      sessionRef: sessionRef,
      confirmed: confirmed,
    );
    pending = [command];
    if (sendGate != null) await sendGate!.future;
    if (failWrite) throw StateError('private transport error');
    pending = [];
    return TableClearResult.parse(c.result(command), command);
  }

  @override
  Future<TableClearResult> recoverTableClear(
    String requestId, {
    bool retryOriginal = false,
  }) async {
    lookups++;
    final command = pending.single;
    expect(requestId, command.requestId);
    if (retryOriginal) {
      retries++;
      pending = [];
      return TableClearResult.parse(c.result(command), command);
    }
    return TableClearResult.parse({
      'result': {'state': 'not_observed', 'requestId': requestId},
    }, command);
  }
}

LiveTable table() {
  final row =
      ((tableFixture()['result'] as Map)['tables'] as List).first
          as Map<String, dynamic>;
  (row['session'] as Map)['sessionRef'] = 'H00000000001';
  return LiveTable(row);
}

void main() {
  testWidgets('confirmed old session does not clear the next server session', (
    tester,
  ) async {
    final auth = ClearAuth();
    addTearDown(auth.dispose);
    await tester.binding.setSurfaceSize(const Size(1366, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final raw = tableFixture();
    final row = ((raw['result'] as Map)['tables'] as List).single as Map;
    (row['session'] as Map)['sessionRef'] = 'H00000000001';
    auth.reply = raw;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveTablesPanel(
            auth: auth,
            language: UiLanguage.en,
            enableRealtime: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tableClear-table-test-000')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tableClear-open')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tableClear-confirm-submit')));
    await tester.pumpAndSettle();
    expect(auth.writes, 1);
    (row['session'] as Map)['sessionRef'] = 'H00000000002';
    final reads = auth.requested.length;
    await tester.tap(find.text(tr(UiLanguage.en, 'ordersBack')));
    await tester.pumpAndSettle();
    expect(auth.requested.length, reads + 1);
    expect(find.byKey(const ValueKey('opening-table-test-000')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('tableClear-table-test-000')));
    await tester.pumpAndSettle();
    expect(find.textContaining('H00000000002'), findsOneWidget);
    expect(auth.writes, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('identity change cancels recovery confirmation without retry', (
    tester,
  ) async {
    final auth = ClearAuth()..pending = [c.command()];
    addTearDown(auth.dispose);
    await tester.binding.setSurfaceSize(const Size(1366, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final id = auth.pending.single.requestId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveTableClearPanel(
            auth: auth,
            language: UiLanguage.en,
            onBack: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('tableClear-lookup-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('tableClear-retry-$id')));
    await tester.pumpAndSettle();
    auth.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(auth.retries, 0);
    expect(find.byKey(ValueKey('tableClear-retry-$id')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  Future<void> show(
    WidgetTester tester,
    ClearAuth auth, {
    UiLanguage language = UiLanguage.en,
    int revision = 0,
    bool recovery = false,
    bool workbench = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1366, 768));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: workbench
              ? LiveTablesPanel(
                  auth: auth,
                  language: language,
                  enableRealtime: false,
                )
              : LiveTableClearPanel(
                  auth: auth,
                  language: language,
                  table: recovery ? null : table(),
                  revision: revision,
                  onBack: () {},
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void cleanup(WidgetTester tester, ClearAuth auth) {
    addTearDown(auth.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  const open = ValueKey('tableClear-open');
  const confirm = ValueKey('tableClear-confirm-submit');
  for (final language in UiLanguage.values) {
    testWidgets('explicit confirmation and single request in $language', (
      tester,
    ) async {
      final auth = ClearAuth();
      cleanup(tester, auth);
      await show(tester, auth, language: language);
      await tester.tap(find.byKey(open));
      await tester.pumpAndSettle();
      expect(auth.writes, 0);
      expect(
        find.textContaining(tr(language, 'tableClearConfirmNotice')),
        findsOneWidget,
      );
      await tester.tap(find.text(tr(language, 'tableClearCancel')));
      await tester.pumpAndSettle();
      expect(auth.writes, 0);
      await tester.tap(find.byKey(open));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(confirm));
      await tester.pumpAndSettle();
      expect(auth.writes, 1);
      expect(auth.lookups, 0);
      expect(find.text(tr(language, 'tableClearConfirmed')), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(open)).onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets(
      'recovery queries first and explicitly retries original in $language',
      (tester) async {
        final auth = ClearAuth()..pending = [c.command()];
        cleanup(tester, auth);
        final id = auth.pending.single.requestId;
        await show(tester, auth, language: language, recovery: true);
        expect(auth.lookups, 0);
        expect(find.byKey(ValueKey('tableClear-retry-$id')), findsNothing);
        await tester.tap(find.byKey(ValueKey('tableClear-lookup-$id')));
        await tester.pumpAndSettle();
        expect(auth.lookups, 1);
        expect(auth.retries, 0);
        await tester.tap(find.byKey(ValueKey('tableClear-retry-$id')));
        await tester.pumpAndSettle();
        expect(auth.retries, 0);
        expect(
          find.textContaining(tr(language, 'tableClearRetryNotice')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('tableClear-retry-confirm')),
        );
        await tester.pumpAndSettle();
        expect(auth.retries, 1);
        expect(auth.writes, 0);
        expect(auth.pending, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final change in ['identity', 'revision', 'background']) {
    testWidgets('$change cancels unsent clear confirmation', (tester) async {
      final auth = ClearAuth();
      cleanup(tester, auth);
      await show(tester, auth);
      await tester.tap(find.byKey(open));
      await tester.pumpAndSettle();
      if (change == 'identity') {
        auth.notifyListeners();
      } else if (change == 'revision') {
        await show(tester, auth, revision: 1);
      } else {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
      }
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(auth.writes, 0);
      if (change == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets(
    'pending, failed storage, no permission and expiry disable new command',
    (tester) async {
      for (final mode in ['pending', 'storage', 'permission', 'expired']) {
        final auth = ClearAuth();
        cleanup(tester, auth);
        if (mode == 'pending') auth.pending = [c.command()];
        if (mode == 'storage') auth.failRead = true;
        if (mode == 'permission') auth.allowed = false;
        if (mode == 'expired') auth.expired = true;
        await show(tester, auth);
        expect(tester.widget<FilledButton>(find.byKey(open)).onPressed, isNull);
        if (mode == 'storage') {
          expect(
            find.text(tr(UiLanguage.en, 'tableClearNoPending')),
            findsNothing,
          );
        }
        expect(auth.writes, 0);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets('lost response retains original and prevents duplicate tap', (
    tester,
  ) async {
    final auth = ClearAuth()
      ..failWrite = true
      ..sendGate = Completer<void>();
    cleanup(tester, auth);
    await show(tester, auth);
    await tester.tap(find.byKey(open));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(confirm));
    await tester.pump();
    expect(auth.writes, 1);
    expect(tester.widget<FilledButton>(find.byKey(open)).onPressed, isNull);
    auth.sendGate!.complete();
    await tester.pumpAndSettle();
    expect(auth.pending, hasLength(1));
    expect(auth.lookups, 0);
    expect(
      find.byKey(
        ValueKey('tableClear-lookup-${auth.pending.single.requestId}'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('private transport'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('late response after identity change does not publish success', (
    tester,
  ) async {
    final auth = ClearAuth()..sendGate = Completer<void>();
    cleanup(tester, auth);
    await show(tester, auth);
    await tester.tap(find.byKey(open));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(confirm));
    await tester.pump();
    auth.notifyListeners();
    await tester.pump();
    auth.sendGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text(tr(UiLanguage.en, 'tableClearConfirmed')), findsNothing);
    expect(auth.writes, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'workbench recovery back re-reads server and does not clear snapshot locally',
    (tester) async {
      final auth = ClearAuth();
      cleanup(tester, auth);
      await show(tester, auth, workbench: true);
      final before = auth.requested.length;
      await tester.tap(find.byKey(const ValueKey('tableClear-recovery-open')));
      await tester.pumpAndSettle();
      expect(find.byType(LiveTableClearPanel), findsOneWidget);
      await tester.tap(find.text(tr(UiLanguage.en, 'ordersBack')));
      await tester.pumpAndSettle();
      expect(auth.requested.length, before + 1);
      expect(find.byType(LiveTableClearPanel), findsNothing);
      expect(auth.writes, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
