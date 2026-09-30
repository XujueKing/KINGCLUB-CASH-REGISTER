import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/order_context_snapshot.dart';
import 'package:kingclub_cash_register/src/live/live_order_members_panel.dart';
import 'package:kingclub_cash_register/src/live/live_tables_panel.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'staff_session_test.dart' as a;
import 'support/table_fixture.dart';

const tableRef = 'test-table', sessionRef = 'H00000000001';
Map<String, dynamic> member(int index, {bool eligible = true}) => {
  'memberRef': 'member-${index.toString().padLeft(3, '0')}',
  'nickname': index == 0 ? null : 'TEST member $index',
  'eligible': eligible,
};
Map<String, dynamic> contextData({List<Object?>? members}) => {
  'storeRef': 'test-store',
  'tableRef': tableRef,
  'tableName': 'TEST table',
  'currency': 'CNY',
  'session': {
    'sessionRef': sessionRef,
    'status': 'open',
    'paymentTiming': 'postpay',
    'partySize': null,
  },
  'members': members ?? [member(0), member(1, eligible: false)],
  'nextAfterMember': null,
  'observedAt': '2026-09-29T00:00:00.000Z',
};
OrderContextSnapshot parse(Map<String, dynamic> data, {String? afterMember}) =>
    OrderContextSnapshot.parse(
      {'result': data},
      storeRef: 'test-store',
      tableRef: tableRef,
      sessionRef: sessionRef,
      afterMember: afterMember,
    );

class Api extends a.TestApi {
  String? id;
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) {
    this.id = id;
    return super.call(id, params);
  }
}

a.TestAuth loginChannel() => a.TestAuth()
  ..result = {
    ...a.response(),
    'permissions': ['workbench.read', 'orders.create'],
  };

class MemberAuth extends StaffAuthController {
  @override
  final StaffSession session = a.session({
    ...a.response(),
    'permissions': ['workbench.read', 'orders.create'],
  });
  bool fail = false, paginated = false;
  int reads = 0;
  String? cursor;
  Completer<OrderContextSnapshot>? gate;
  final calls = <List<String?>>[];
  void invalidate() => notifyListeners();
  @override
  Future<OrderContextSnapshot> readOrderContext({
    required String tableRef,
    required String sessionRef,
    String? afterMember,
  }) async {
    reads++;
    calls.add([tableRef, sessionRef, afterMember]);
    cursor = afterMember;
    if (gate != null) return gate!.future;
    if (fail) throw const CcsopFailure('PRIVATE_FAILURE');
    if (paginated && afterMember == null) {
      return parse({
        ...contextData(members: List.generate(50, (i) => member(i))),
        'nextAfterMember': 'member-049',
      });
    }
    return parse(
      contextData(members: afterMember == null ? null : [member(50)]),
      afterMember: afterMember,
    );
  }

  @override
  Future<Object?> readWorkbench({String? afterTable}) async {
    final data = tableFixture();
    final table = data['result']['tables'][0] as Map<String, dynamic>;
    table['tableRef'] = tableRef;
    (table['session'] as Map<String, dynamic>)['sessionRef'] = sessionRef;
    return data;
  }
}

Widget panel(
  MemberAuth auth, {
  UiLanguage language = UiLanguage.zh,
  int revision = 0,
  String session = sessionRef,
}) => MaterialApp(
  home: Scaffold(
    body: LiveOrderMembersPanel(
      auth: auth,
      language: language,
      tableRef: tableRef,
      sessionRef: session,
      revision: revision,
      onBack: () {},
    ),
  ),
);
void size(WidgetTester tester) {
  tester.view.physicalSize = const Size(1024, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  test('unknown count and nickname retained; immutable membership, both payment modes', () {
    final value = parse(contextData());
    expect(value.partySize, isNull);
    expect(value.members.first.nickname, isNull);
    expect(value.members.last.eligible, false);
    expect(value.paymentTiming, 'postpay');
    expect(() => value.members.clear(), throwsUnsupportedError);
    final data = contextData();
    (data['session'] as Map)['paymentTiming'] = 'prepay';
    expect(parse(data).paymentTiming, 'prepay');
  });
  test(
    'rejects cross scope, invalid fields and non-canonical observed date',
    () {
      for (final patch in <Map<String, dynamic>>[
        {'storeRef': 'other'},
        {'tableRef': 'other'},
        {'currency': 'cny'},
        {'tableName': '  '},
        {'observedAt': '2026-02-30T00:00:00.000Z'},
        {'nextAfterMember': 'member-001'},
        {
          'members': [member(0), member(0)],
        },
        {
          'members': [member(1), member(0)],
        },
        {
          'members': [
            {...member(0), 'eligible': 'true'},
          ],
        },
        {
          'members': [
            {...member(0), 'nickname': ''},
          ],
        },
      ]) {
        expect(
          () => parse({...contextData(), ...patch}),
          throwsA(isA<CcsopFailure>()),
        );
      }
      for (final patch in <Map<String, dynamic>>[
        {'sessionRef': 'H00000000002'},
        {'status': 'closed'},
        {'status': 'clearing'},
        {'paymentTiming': 'unknown'},
        {'partySize': 0},
        {'partySize': 1.5},
        {'partySize': 65536},
      ]) {
        expect(
          () => parse({
            ...contextData(),
            'session': {...contextData()['session'] as Map, ...patch},
          }),
          throwsA(isA<CcsopFailure>()),
        );
      }
    },
  );
  test('strict member cursor and continuation, empty page does not imply invented members', () {
    final data = {
      ...contextData(members: List.generate(50, (i) => member(i))),
      'nextAfterMember': 'member-049',
    };
    expect(parse(data).nextAfterMember, 'member-049');
    expect(parse(contextData(members: [])).members, isEmpty);
    expect(
      () => parse(data, afterMember: 'member-000'),
      throwsA(isA<CcsopFailure>()),
    );
    expect(
      () => parse({...data, 'nextAfterMember': 'member-050'}),
      throwsA(isA<CcsopFailure>()),
    );
  });
  test(
    '1911 binds staff store and exact selected table/session/cursor',
    () async {
      final api = Api()..pendingRead = Completer<Object?>();
      final auth = a.controller(a.TestStorage(), loginChannel(), api);
      await a.login(auth);
      final pending = auth.readOrderContext(
        tableRef: tableRef,
        sessionRef: sessionRef,
        afterMember: 'member-000',
      );
      expect(api.id, 'K260929001911');
      expect(api.params, {
        'storeRef': 'test-store',
        'tableRef': tableRef,
        'sessionRef': sessionRef,
        'afterMember': 'member-000',
      });
      api.pendingRead!.complete({
        'result': contextData(members: [member(1)]),
      });
      expect((await pending).members.single.reference, 'member-001');
      auth.dispose();
    },
  );
  test('missing orders.create makes no request', () async {
    final api = Api();
    final auth = a.controller(a.TestStorage(), a.TestAuth(), api);
    await a.login(auth);
    await expectLater(
      auth.readOrderContext(tableRef: tableRef, sessionRef: sessionRef),
      throwsA(isA<CcsopFailure>()),
    );
    expect(api.id, isNull);
    auth.dispose();
  });
  test(
    'expiry and logout discard late replies without exposing members',
    () async {
      for (final logout in [true, false]) {
        var now = a.now;
        final api = Api()..pendingRead = Completer<Object?>();
        final auth = StaffAuthController(
          vault: SessionVault(storage: a.TestStorage()),
          authFactory: (_) => loginChannel(),
          sessionFactory: (_) => api,
          now: () => now,
        );
        await a.login(auth);
        final pending = auth.readOrderContext(
          tableRef: tableRef,
          sessionRef: sessionRef,
        );
        final rejected = expectLater(pending, throwsA(isA<CcsopFailure>()));
        if (logout) {
          await auth.logout();
        } else {
          now = now.add(const Duration(minutes: 16));
        }
        api.pendingRead!.complete({'result': contextData()});
        await rejected;
        auth.dispose();
      }
    },
  );
  testWidgets(
    'four languages fit, only eligible members can be selected; failed refresh clears selection',
    (tester) async {
      size(tester);
      final auth = MemberAuth();
      for (final lang in UiLanguage.values) {
        await tester.pumpWidget(panel(auth, language: lang));
        await tester.pumpAndSettle();
        expect(find.text(tr(lang, 'orderMemberUnnamed')), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byKey(const ValueKey('order-member-member-001')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('order-member-selection')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('order-member-member-000')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('order-member-selection')),
        findsOneWidget,
      );
      auth.fail = true;
      await tester.tap(find.byKey(const ValueKey('order-members-refresh')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('order-member-selection')),
        findsNothing,
      );
      expect(find.textContaining('PRIVATE_FAILURE'), findsNothing);
      expect(
        find.text(tr(UiLanguage.th, 'orderMembersFailed')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets('member paging follows exclusive cursor and resets choice', (
    tester,
  ) async {
    size(tester);
    final auth = MemberAuth()..paginated = true;
    await tester.pumpWidget(panel(auth));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('order-member-member-000')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('order-members-next')));
    await tester.pumpAndSettle();
    expect(auth.cursor, 'member-049');
    expect(find.text('TEST member 50'), findsOneWidget);
    expect(find.byKey(const ValueKey('order-member-selection')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('order-members-previous')));
    await tester.pumpAndSettle();
    expect(auth.cursor, isNull);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
  testWidgets(
    'identity, realtime refresh and background invalidate selections and late responses',
    (tester) async {
      size(tester);
      final auth = MemberAuth();
      await tester.pumpWidget(panel(auth));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('order-member-member-000')));
      await tester.pump();
      auth.gate = Completer<OrderContextSnapshot>();
      await tester.pumpWidget(panel(auth, revision: 1));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('order-member-selection')),
        findsNothing,
      );
      auth.invalidate();
      await tester.pump();
      auth.gate!.complete(parse(contextData()));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('order-member-member-000')),
        findsNothing,
      );
      auth.gate = null;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('order-member-member-000')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets('table route opens bound session member list', (tester) async {
    size(tester);
    final auth = MemberAuth();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveTablesPanel(auth: auth, language: UiLanguage.zh),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('live-table-test-table')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('order-members-open-test-table')),
    );
    await tester.pumpAndSettle();
    expect(auth.calls.single, [tableRef, sessionRef, null]);
    expect(find.byType(LiveOrderMembersPanel), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
}
