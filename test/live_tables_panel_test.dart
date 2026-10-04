import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/live_tables_panel.dart';
import 'package:kingclub_cash_register/src/live/bar_counter_strip.dart';
import 'package:kingclub_cash_register/src/live/opening_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'package:kingclub_cash_register/src/network/cashier_realtime_client.dart';

import 'support/table_fixture.dart';

class PanelRealtime extends CashierRealtimeClient {
  PanelRealtime(super.session);
  int value = 0;
  bool running = false;
  @override
  int get revision => value;
  @override
  CashierRealtimeState get state =>
      running ? CashierRealtimeState.connected : CashierRealtimeState.offline;
  @override
  void start() {
    running = true;
    notifyListeners();
  }

  @override
  void stop() {
    running = false;
    notifyListeners();
  }

  void changed() {
    value++;
    notifyListeners();
  }
}

class TableAuth extends StaffAuthController {
  int openingReads = 0;
  @override
  Future<OpeningContext> readOpeningContext({required String tableId}) async {
    openingReads++;
    throw StateError('Selection must not open a bar seat');
  }

  Object? reply = tableFixture();
  final requested = <String?>[];
  Completer<Object?>? gate;
  bool fail = false;
  TableAuth({List<String> permissions = const ['workbench.read']})
    : session = StaffSession.fromServer(
        {
          'employee': {
            'employeeRef': 'E00000000001',
            'displayName': 'Test employee',
          },
          'storeRef': 'test-store',
          'sessionId': '00000000-0000-4000-8000-000000000002',
          'apiKeyId': '00000000-0000-4000-8000-000000000003',
          'apiKey': 'a' * 43,
          'refreshToken': 'b' * 43,
          'permissions': permissions,
          'expiresAtMs': DateTime.now()
              .add(const Duration(minutes: 15))
              .millisecondsSinceEpoch,
          'refreshExpiresAtMs': DateTime.now()
              .add(const Duration(hours: 12))
              .millisecondsSinceEpoch,
        },
        base: 'https://service.invalid',
        deviceId: '00000000-0000-4000-8000-000000000001',
        expectedStore: 'test-store',
      );
  @override
  final StaffSession session;
  @override
  Future<Object?> readWorkbench({String? afterTable}) async {
    requested.add(afterTable);
    if (gate != null) return gate!.future;
    if (fail) throw StateError('PRIVATE_ERROR');
    return reply;
  }
}

void main() {
  testWidgets('floor tabs separate dining and KTV rooms from ground tables', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = TableAuth();
    final reply = tableFixture(count: 5);
    final tables = reply['result']['tables'] as List;
    for (var i = 0; i < 5; i++) {
      tables[i]['tableName'] = ['V1', 'C1', 'C2', 'K1', 'K2'][i];
      tables[i]['session'] = null;
    }
    auth.reply = reply;
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
    expect(find.text('V1'), findsOneWidget);
    expect(find.text('C1'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('table-floor-2')));
    await tester.pumpAndSettle();
    expect(find.text('V1'), findsNothing);
    for (final name in ['C1', 'C2', 'K1', 'K2']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty bar selection shows an empty bill without opening', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = TableAuth(permissions: ['workbench.read', 'orders.read']);
    final reply = tableFixture(count: 2);
    final tables = reply['result']['tables'] as List;
    tables[0]['tableName'] = '吧台';
    tables[0]['maximumSeats'] = 8;
    tables[0]['session'] = null;
    tables[1]['parentBarRef'] = tables[0]['tableRef'];
    tables[1]['barSeatNumber'] = 2;
    tables[1]['session'] = null;
    auth.reply = reply;
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
    await tester.tap(find.byKey(const ValueKey('bar-seat-2')));
    await tester.pumpAndSettle();
    expect(auth.openingReads, 0);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('empty-bar-member')), findsOneWidget);
    expect(find.byKey(const ValueKey('table-bill-total')), findsOneWidget);
    expect(find.byKey(const ValueKey('table-bill-paid')), findsOneWidget);
    expect(find.byKey(const ValueKey('table-bill-pending')), findsOneWidget);
    expect(find.byKey(const ValueKey('table-bill-print')), findsOneWidget);
    expect(find.byKey(const ValueKey('bill-filter')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'ordering menu automatically selects an unused bar seat without opening',
    (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = TableAuth(permissions: ['workbench.read', 'orders.read']);
      final reply = tableFixture(count: 2);
      final tables = reply['result']['tables'] as List;
      tables[0]['tableName'] = '吧台';
      tables[0]['maximumSeats'] = 8;
      tables[0]['session'] = null;
      tables[1]['parentBarRef'] = tables[0]['tableRef'];
      tables[1]['barSeatNumber'] = 2;
      tables[1]['session'] = null;
      auth.reply = reply;
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
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveTablesPanel(
              auth: auth,
              language: UiLanguage.zh,
              enableRealtime: false,
              menuVisible: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(auth.openingReads, 0);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('empty-bar-member')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-bill-total')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-bill-paid')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-bill-pending')), findsOneWidget);
      expect(find.byKey(const ValueKey('table-bill-print')), findsOneWidget);
      expect(find.byKey(const ValueKey('bill-filter')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('counter is below ordinary cards with eight avatar places', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = TableAuth();
    final reply = tableFixture(count: 2);
    final tables = (reply['result'] as Map)['tables'] as List;
    tables[1]['tableName'] = '吧台';
    tables[1]['maximumSeats'] = 8;
    tables[1]['session'] = null;
    auth.reply = reply;
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
    expect(find.byKey(const ValueKey('live-table-test-001')), findsNothing);
    expect(find.byType(BarCounterStrip), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(BarCounterStrip),
        matching: find.byType(AspectRatio),
      ),
      findsNWidgets(8),
    );
    expect(
      tester.getTopLeft(find.byType(BarCounterStrip)).dy,
      greaterThan(
        tester
            .getBottomLeft(find.byKey(const ValueKey('live-table-test-000')))
            .dy,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('bar-seat-2')));
    await tester.pumpAndSettle();
    expect(find.text('B2'), findsNWidgets(2));
    expect(find.byType(VerticalDivider), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
  Future<void> show(
    WidgetTester tester,
    TableAuth auth, {
    UiLanguage language = UiLanguage.zh,
    PanelRealtime? realtime,
  }) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveTablesPanel(
            auth: auth,
            language: language,
            enableRealtime: realtime != null,
            realtimeFactory: realtime == null ? null : (_) => realtime,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'table card shows occupied and empty seats with readable opening time',
    (tester) async {
      final auth = TableAuth(), data = tableFixture();
      data['result']['tables'][0]['maximumSeats'] = 10;
      data['result']['tables'][0]['tableMode'] = 'aa';
      final session = data['result']['tables'][0]['session'];
      session['partySize'] = 5;
      session['openedAt'] = '2026-09-29T07:35:00.000Z';
      session['elapsedMinutes'] = 25;
      auth.reply = data;
      await show(tester, auth, language: UiLanguage.en);
      for (var i = 0; i < 10; i++) {
        final cell = tester.widget<Container>(
          find.byKey(ValueKey('table-seat-test-000-$i')),
        );
        expect(cell.constraints!.maxWidth, cell.constraints!.maxHeight);
        expect(cell.color!.a, closeTo(i < 5 ? 0.9 : 0.18, 0.01));
      }
      expect(find.byIcon(Icons.person), findsNothing);
      expect(find.text('5/10'), findsNothing);
      expect(find.text(' (AA)'), findsOneWidget);
      expect(
        tester.getTopLeft(find.textContaining('(25min)')).dy,
        greaterThan(tester.getTopLeft(find.text('Test table 0')).dy),
      );
      expect(
        find.byKey(const ValueKey('table-total-test-000')),
        findsOneWidget,
      );
      expect(find.textContaining('Today'), findsNWidgets(2));
      expect(find.textContaining('(25min)'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Temporary hold stays distinct until server releases the table', (
    tester,
  ) async {
    final auth = TableAuth();
    final data = tableFixture();
    final session = data['result']['tables'][0]['session'];
    session['temporaryHold'] = true;
    session['paymentTiming'] = 'prepay';
    session['paidCents'] = 0;
    session['paidOrders'] = 0;
    auth.reply = data;
    await show(tester, auth);
    expect(find.text('临时占座'), findsOneWidget);
    expect(find.text('有未付订单'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('live-table-test-000')));
    await tester.pumpAndSettle();
    expect(find.text('临时占座'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('table-detail-back')));
    await tester.pumpAndSettle();
    // An expired local timer must not invent release while server still holds it.
    await tester.pump(const Duration(minutes: 11));
    expect(find.text('临时占座'), findsOneWidget);
    data['result']['tables'][0]['session'] = null;
    await tester.tap(find.byKey(const ValueKey('table-tools')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('live-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('临时占座'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('live-table-test-000')));
    await tester.pumpAndSettle();
    expect(find.text('有未付订单'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets(
    'Realtime hints coalesce, query again after an in-flight read, and stop in background',
    (tester) async {
      final auth = TableAuth();
      final realtime = PanelRealtime(auth.session);
      await show(tester, auth, realtime: realtime);
      expect(realtime.running, isTrue);
      expect(auth.requested.length, 1);
      final card = find.byKey(const ValueKey('live-table-test-000'));
      final cardRect = tester.getRect(card);
      auth.gate = Completer<Object?>();
      for (var i = 0; i < 5; i++) {
        realtime.changed();
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(auth.requested.length, 2);
      expect(tester.getRect(card), cardRect);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      for (var i = 0; i < 5; i++) {
        realtime.changed();
      }
      await tester.pump(const Duration(milliseconds: 400));
      expect(auth.requested.length, 2);
      auth.gate!.complete(tableFixture());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(auth.requested.length, 3);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(realtime.running, isFalse);
      final count = auth.requested.length;
      realtime.changed();
      await tester.pump(const Duration(seconds: 1));
      expect(auth.requested.length, count);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(realtime.running, isTrue);
      expect(auth.requested.length, count + 1);
      await tester.pumpWidget(const SizedBox());
      expect(realtime.running, isFalse);
      auth.dispose();
    },
  );

  testWidgets(
    'Displays server money, no pay actions, failure removes old records',
    (tester) async {
      final auth = TableAuth()..reply = tableFixture(count: 2);
      await show(tester, auth);
      expect(find.text('Test table 0'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('live-table-test-000')));
      await tester.pumpAndSettle();
      expect(find.textContaining('CNY 12.01'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('table-detail-test-000')),
          matching: find.textContaining('CNY 78.00'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('live-table-test-001')), findsOneWidget);
      expect(find.byKey(const ValueKey('real-payment')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('table-detail-back')));
      await tester.pumpAndSettle();
      auth.fail = true;
      await tester.tap(find.byKey(const ValueKey('table-tools')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('live-refresh')));
      await tester.pumpAndSettle();
      expect(find.text('Test table 0'), findsNothing);
      expect(find.textContaining('桌台读取失败'), findsOneWidget);
      expect(find.textContaining('PRIVATE_ERROR'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'background mount neither reads tables nor starts realtime until resumed',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      final auth = TableAuth();
      final realtime = PanelRealtime(auth.session);
      await show(tester, auth, realtime: realtime);
      expect(auth.requested, isEmpty);
      expect(realtime.running, isFalse);
      expect(find.text('Test table 0'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(auth.requested, [null]);
      expect(realtime.running, isTrue);
      expect(find.text('Test table 0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'background invalidates an in-flight table read and resume fetches again',
    (tester) async {
      final auth = TableAuth();
      await show(tester, auth);
      final pending = Completer<Object?>();
      auth.gate = pending;
      await tester.tap(find.byKey(const ValueKey('table-tools')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('live-refresh')));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      pending.complete(tableFixture());
      await tester.pump();
      expect(find.text('Test table 0'), findsNothing);
      final reads = auth.requested.length;
      auth.gate = null;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(auth.requested.length, reads + 1);
      expect(find.text('Test table 0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets('refresh retains the grid until the replacement arrives', (
    tester,
  ) async {
    final auth = TableAuth();
    await show(tester, auth);
    auth.gate = Completer<Object?>();
    await tester.tap(find.byKey(const ValueKey('table-tools')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('live-refresh')));
    await tester.pump();
    expect(find.text('Test table 0'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.tap(find.byKey(const ValueKey('live-table-test-000')));
    await tester.pump();
    expect(find.byKey(const ValueKey('table-detail-back')), findsNothing);
    auth.gate!.complete(tableFixture(count: 0));
    await tester.pumpAndSettle();
    expect(find.text('Test table 0'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
  testWidgets(
    'Next page requests server cursor and replaces rather than sums snapshots',
    (tester) async {
      final auth = TableAuth()
        ..reply = tableFixture(count: 100, next: 'test-099');
      await show(tester, auth);
      auth.reply = tableFixture(count: 0);
      for (var i = 0; i < 30 && auth.requested.length == 1; i++) {
        await tester.drag(
          find.byKey(const ValueKey('swipe-pages')),
          const Offset(-500, 0),
        );
        await tester.pumpAndSettle();
      }
      await tester.pumpAndSettle();
      expect(auth.requested, [null, 'test-099']);
      expect(find.text('Test table 0'), findsNothing);
      expect(find.text('服务器返回本页无桌台'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'Four languages fit; a response after disposal cannot update UI',
    (tester) async {
      final auth = TableAuth();
      for (final language in UiLanguage.values) {
        await show(tester, auth, language: language);
        expect(tester.takeException(), isNull);
      }
      auth.gate = Completer<Object?>();
      await tester.tap(find.byKey(const ValueKey('table-tools')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('live-refresh')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      auth.gate!.complete(tableFixture());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      auth.dispose();
    },
  );
}
