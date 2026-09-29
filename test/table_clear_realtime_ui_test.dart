import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/live_tables_panel.dart';
import 'package:kingclub_cash_register/src/live/live_table_clear_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show PanelRealtime;
import 'table_clear_ui_test.dart' show ClearAuth;
import 'support/table_fixture.dart';

// Composition tests of production widgets. Transport/auth are explicit test doubles;
// real TLS/WSS coverage is in table_clear_backend_interop_test.dart, not here.
void main() {
  Future<void> start(
    WidgetTester tester,
    ClearAuth auth,
    PanelRealtime realtime,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1366, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(auth.dispose);
    final raw = tableFixture();
    (((raw['result'] as Map)['tables'] as List).single
            as Map)['session']['sessionRef'] =
        'H00000000001';
    auth.reply = raw;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveTablesPanel(
            auth: auth,
            language: UiLanguage.en,
            enableRealtime: true,
            realtimeFactory: (_) => realtime,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> confirmDialog(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('tableClear-table-test-000')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tableClear-open')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  testWidgets(
    'workbench realtime update cancels unsent confirmation and reloads',
    (tester) async {
      final auth = ClearAuth();
      final realtime = PanelRealtime(auth.session);
      await start(tester, auth, realtime);
      await confirmDialog(tester);
      final before = auth.requested.length;
      realtime.changed();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(auth.writes, 0);
      expect(auth.requested.length, greaterThan(before));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'event while clear response is lost retains original and only queries on demand',
    (tester) async {
      final auth = ClearAuth()
        ..sendGate = Completer<void>()
        ..failWrite = true;
      final realtime = PanelRealtime(auth.session);
      await start(tester, auth, realtime);
      await confirmDialog(tester);
      await tester.tap(find.byKey(const ValueKey('tableClear-confirm-submit')));
      await tester.pump();
      expect(auth.writes, 1);
      final id = auth.pending.single.requestId;
      realtime.changed();
      await tester.pump(const Duration(milliseconds: 500));
      auth.sendGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text(tr(UiLanguage.en, 'tableClearConfirmed')), findsNothing);
      expect(auth.pending.single.requestId, id);
      expect(auth.lookups, 0);
      expect(auth.retries, 0);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('tableClear-open')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(ValueKey('tableClear-lookup-$id')));
      await tester.pumpAndSettle();
      expect(auth.lookups, 1);
      expect(auth.writes, 1);
      expect(auth.retries, 0);
      expect(auth.pending.single.requestId, id);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'server has new session while old clear completes; return uses authoritative session',
    (tester) async {
      final auth = ClearAuth()..sendGate = Completer<void>();
      final realtime = PanelRealtime(auth.session);
      await start(tester, auth, realtime);
      await confirmDialog(tester);
      await tester.tap(find.byKey(const ValueKey('tableClear-confirm-submit')));
      await tester.pump();
      final raw = tableFixture();
      (((raw['result'] as Map)['tables'] as List).single
              as Map)['session']['sessionRef'] =
          'H00000000002';
      auth.reply = raw;
      realtime.changed();
      await tester.pump(const Duration(milliseconds: 500));
      auth.sendGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text(tr(UiLanguage.en, 'tableClearConfirmed')), findsNothing);
      await tester.tap(find.text(tr(UiLanguage.en, 'ordersBack')));
      await tester.pumpAndSettle();
      expect(find.byType(LiveTableClearPanel), findsNothing);
      expect(
        find.byKey(const ValueKey('opening-table-test-000')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('tableClear-table-test-000')));
      await tester.pumpAndSettle();
      expect(find.textContaining('H00000000002'), findsOneWidget);
      expect(auth.writes, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
