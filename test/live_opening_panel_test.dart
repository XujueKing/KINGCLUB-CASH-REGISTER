import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/live_opening_panel.dart';
import 'package:kingclub_cash_register/src/live/live_tables_panel.dart';
import 'package:kingclub_cash_register/src/live/opening_journal.dart';
import 'package:kingclub_cash_register/src/live/opening_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'opening_snapshot_test.dart' as fixture;
import 'staff_session_test.dart' as staff;
import 'support/table_fixture.dart';

class OpeningAuth extends StaffAuthController {
  @override
  Future<Object?> readWorkbench({String? afterTable}) async {
    final result = tableFixture();
    final table = result['result']['tables'][0] as Map<String, dynamic>;
    table['tableRef'] = 'test-table';
    table['session'] = null;
    return result;
  }

  @override
  final StaffSession session = staff.session({
    ...staff.response(),
    'permissions': ['workbench.read', 'table.open'],
  });
  Map<String, dynamic> contextData = {
    ...fixture.context(),
    'openingEnabled': true,
  };
  List<PendingOpening> entries = [];
  int submits = 0, retries = 0, queries = 0, cancels = 0;
  bool fail = false;
  Completer<OpeningContext>? readGate;
  @override
  Future<List<PendingOpening>> pendingOpenings() async => entries;
  @override
  Future<OpeningContext> readOpeningContext({required String tableId}) async {
    if (readGate != null) return readGate!.future;
    return fixture.parseContext(contextData);
  }

  @override
  Future<OpeningLookup> submitOpening({
    required OpeningContext context,
    required int? partySize,
    required List<String> memberRefs,
    required bool arrivalConfirmed,
    required bool reservationChecked,
  }) async {
    submits++;
    expect(partySize, 2);
    expect(arrivalConfirmed && reservationChecked, isTrue);
    final p = PendingOpening.prepare(
      session: session,
      context: context,
      partySize: partySize,
      memberRefs: memberRefs,
      arrivalConfirmed: arrivalConfirmed,
      reservationChecked: reservationChecked,
    );
    if (fail) {
      entries = [p];
      throw StateError('PRIVATE_MESSAGE');
    }
    return OpeningLookup.fromSubmission(
      {
        'result': {...fixture.receipt(), 'memberRefs': []},
      },
      storeRef: p.storeRef,
      tableId: p.tableId,
      requestId: p.requestId,
    );
  }

  @override
  Future<OpeningLookup> recoverOpening(
    String requestId, {
    bool retryOriginal = false,
  }) async {
    retryOriginal ? retries++ : queries++;
    return fixture.parseLookup({
      'state': 'not_observed',
      'requestId': fixture.request,
    });
  }

  @override
  Future<OpeningLookup> cancelOpening(
    String requestId, {
    required bool confirmed,
  }) async {
    expect(confirmed, isTrue);
    cancels++;
    entries = [];
    return OpeningLookup.parse(
      {
        'result': {'state': 'cancelled', 'requestId': requestId},
      },
      storeRef: 'test-store',
      tableId: 'test-table',
      requestId: requestId,
    );
  }
}

Future<void> show(
  WidgetTester tester,
  OpeningAuth auth, {
  UiLanguage language = UiLanguage.zh,
  String? tableId = 'test-table',
}) async {
  tester.view.physicalSize = const Size(1024, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LiveOpeningPanel(
          auth: auth,
          language: language,
          tableId: tableId,
          currency: 'CNY',
          onBack: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

Future<void> fill(WidgetTester tester) async {
  await tester.enterText(find.byKey(const ValueKey('opening-party-size')), '2');
  await tap(tester, const ValueKey('opening-arrival'));
  await tap(tester, const ValueKey('opening-reservation'));
}

void main() {
  testWidgets(
    'table workspace opens the real form and separate recovery entry',
    (tester) async {
      final auth = OpeningAuth();
      await show(tester, auth);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveTablesPanel(
              auth: auth,
              language: UiLanguage.zh,
              enableRealtime: false,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('live-table-test-table')));
      await tester.pumpAndSettle();
      await tap(tester, const ValueKey('opening-table-test-table'));
      expect(find.byKey(const ValueKey('opening-party-size')), findsOneWidget);
      await tester.tap(find.text(tr(UiLanguage.zh, 'ordersBack')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('table-tools')));
      await tester.pumpAndSettle();
      await tap(tester, const ValueKey('opening-pending'));
      expect(find.byKey(const ValueKey('opening-party-size')), findsNothing);
      expect(find.text(tr(UiLanguage.zh, 'openingNoPending')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets('closed server feature and occupied table cannot be submitted', (
    tester,
  ) async {
    for (final patch in [
      <String, dynamic>{'openingEnabled': false},
      {
        'activeSession': {'sessionRef': 'H00000000001', 'status': 'open'},
      },
    ]) {
      final auth = OpeningAuth()
        ..contextData = {
          ...fixture.context(),
          'openingEnabled': true,
          ...patch,
        };
      await show(tester, auth);
      await fill(tester);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('opening-submit')))
            .onPressed,
        isNull,
      );
      expect(auth.submits, 0);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    }
  });
  testWidgets(
    'explicit confirmations and final dialog precede opening; real result displayed',
    (tester) async {
      final auth = OpeningAuth();
      await show(tester, auth);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('opening-submit')))
            .onPressed,
        isNull,
      );
      await fill(tester);
      await tap(tester, const ValueKey('opening-submit'));
      expect(auth.submits, 0);
      await tap(tester, const ValueKey('opening-dialog-confirm'));
      expect(auth.submits, 1);
      expect(find.text(tr(UiLanguage.zh, 'openingConfirmed')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('opening-submit')))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'failed submission displays pending recovery without leaking errors or auto retry',
    (tester) async {
      final auth = OpeningAuth()..fail = true;
      await show(tester, auth);
      await fill(tester);
      await tap(tester, const ValueKey('opening-submit'));
      await tap(tester, const ValueKey('opening-dialog-confirm'));
      expect(auth.submits, 1);
      expect(find.text('PRIVATE_MESSAGE'), findsNothing);
      expect(
        find.text(tr(UiLanguage.zh, 'openingUnconfirmed')),
        findsOneWidget,
      );
      final id = auth.entries.single.requestId;
      await tap(tester, ValueKey('opening-query-$id'));
      expect(auth.queries, 1);
      expect(auth.retries, 0);
      await tap(tester, ValueKey('opening-cancel-$id'));
      expect(auth.cancels, 0);
      await tap(tester, const ValueKey('opening-dialog-confirm'));
      expect(auth.cancels, 1);
      expect(find.text(tr(UiLanguage.zh, 'openingCancelled')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'all four languages fit landscape; AA and disabled submissions remain blocked',
    (tester) async {
      for (final language in UiLanguage.values) {
        final auth = OpeningAuth()
          ..contextData = {
            ...fixture.context(),
            'openingEnabled': true,
            'rule': {
              'revision': 1,
              'businessDate': '2026-09-29',
              'rule': {'mode': 'aa'},
            },
          };
        await show(tester, auth, language: language);
        await fill(tester);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('opening-submit')),
              )
              .onPressed,
          isNull,
        );
        expect(find.text(tr(language, 'openingAaUnavailable')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      }
    },
  );
  testWidgets('identity change clears context and prevents stale submission', (
    tester,
  ) async {
    final auth = OpeningAuth();
    await show(tester, auth);
    await fill(tester);
    auth.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('opening-submit')), findsNothing);
    expect(find.text(tr(UiLanguage.zh, 'openingReadFailed')), findsOneWidget);
    expect(auth.submits, 0);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
}
