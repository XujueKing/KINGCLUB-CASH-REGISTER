import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/member_identity.dart';
import 'package:kingclub_cash_register/src/live/member_seating_panel.dart';
import 'package:kingclub_cash_register/src/live/live_order_members_panel.dart';
import 'package:kingclub_cash_register/src/live/order_context_snapshot.dart';
import 'package:kingclub_cash_register/src/live/seating_command.dart';
import 'package:kingclub_cash_register/src/live/seating_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'staff_session_test.dart' as a;
import 'live_tables_panel_test.dart' show TableAuth;
import 'member_identity_test.dart' as member;

OrderContextSnapshot contextSnapshot({bool seated = false}) =>
    OrderContextSnapshot.parse(
      {
        'result': {
          'storeRef': 'test-store',
          'tableRef': 'test-table',
          'tableName': 'TEST table',
          'currency': 'CNY',
          'session': {
            'sessionRef': 'H00000000001',
            'status': 'open',
            'paymentTiming': 'postpay',
            'partySize': 4,
          },
          'members': seated
              ? [
                  {
                    'memberRef': 'test-member',
                    'nickname': 'TEST guest',
                    'eligible': true,
                  },
                ]
              : [],
          'nextAfterMember': null,
          'observedAt': '2026-10-01T00:00:00.000Z',
        },
      },
      storeRef: 'test-store',
      tableRef: 'test-table',
      sessionRef: 'H00000000001',
    );
final permissions = ['workbench.read', 'orders.create', 'table.open'];
PendingSeating command() => PendingSeating.prepare(
  session: a.session({...a.response(), 'permissions': permissions}),
  context: contextSnapshot(),
  member: member.identity(),
  now: a.now,
  arrivalConfirmed: true,
  reservationChecked: true,
);
Map<String, dynamic> reply(PendingSeating c, [String state = 'confirmed']) => {
  'result': state == 'confirmed'
      ? {
          'state': state,
          'receipt': {
            ...c.lookup,
            'memberRef': c.memberRef,
            'seatedBy': c.employeeRef,
            'alreadySeated': false,
            'seatingStatus': 'seated',
          },
        }
      : {'state': state, 'requestId': c.requestId},
};

class SeatApi extends a.TestApi {
  final calls = <String>[];
  final called = Completer<void>();
  PendingSeating? expected;
  bool unknown = false, lookupConfirmed = false;
  Completer<Object?>? gate;
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    if (id == 'K260929001904') return super.call(id, params);
    calls.add(id);
    if (!called.isCompleted) called.complete();
    this.params = params;
    if (gate != null) return gate!.future;
    if (id == 'K261001001952' && unknown) {
      throw const CcsopFailure('NETWORK_UNCERTAIN', deliveryUncertain: true);
    }
    return reply(
      expected!,
      id == 'K261001001953' && !lookupConfirmed
          ? 'not_observed'
          : id == 'K261001001954'
          ? 'cancelled'
          : 'confirmed',
    );
  }
}

class SeatViewAuth extends TableAuth {
  SeatViewAuth() : super(permissions: permissions);
  bool seated = false;
  int confirms = 0, reads = 0;
  final rows = <PendingSeating>[];
  Completer<void>? submissionGate;
  @override
  Future<MemberIdentity> readMemberIdentity(String code) async =>
      member.identity();
  @override
  Future<List<PendingSeating>> pendingSeating() async => List.of(rows);
  @override
  Future<OrderContextSnapshot> readOrderContext({
    required String tableRef,
    required String sessionRef,
    String? afterMember,
  }) async {
    reads++;
    return contextSnapshot(seated: seated);
  }

  @override
  Future<SeatingResult> confirmSeating(
    PendingSeating command,
    String code, {
    required bool confirmed,
    required bool Function() stillCurrent,
  }) async {
    expect(stillCurrent(), true);
    expect(confirmed, true);
    confirms++;
    if (submissionGate != null) await submissionGate!.future;
    seated = true;
    return SeatingResult.parse(reply(command), command);
  }
}

void main() {
  testWidgets(
    'submitted seating can finish after displayed QR expires without requiring a second request',
    (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = SeatViewAuth()..submissionGate = Completer<void>();
      var completions = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MemberSeatingPanel(
              auth: auth,
              language: UiLanguage.zh,
              orderContext: contextSnapshot(),
              onSeated: () => completions++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('member-identity-code')),
        'KC:M:${'A' * 32}',
      );
      await tester.tap(find.byKey(const ValueKey('member-identity-scan')));
      await tester.pumpAndSettle();
      for (final key in ['seating-confirm']) {
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pump();
      }
      expect(auth.confirms, 1);
      await tester.pump(const Duration(seconds: 59));
      expect(
        find.byKey(const ValueKey('member-identity-result')),
        findsNothing,
      );
      auth.submissionGate!.complete();
      await tester.pumpAndSettle();
      expect(completions, 1);
      expect(auth.confirms, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  test('persisted command excludes QR; terminal results strictly bind original member, employee and scope', () {
    final c = command();
    expect(jsonEncode(c.encode()), isNot(contains('identityCode')));
    expect(
      PendingSeating.decode(jsonDecode(jsonEncode(c.encode()))).signature,
      c.signature,
    );
    expect(SeatingResult.parse(reply(c), c).confirmed, true);
    expect(SeatingResult.parse(reply(c, 'cancelled'), c).terminal, true);
    expect(SeatingResult.parse(reply(c, 'not_observed'), c).terminal, false);
    for (final patch in [
      {'memberRef': 'other'},
      {'seatedBy': 'E00000000002'},
      {'sessionRef': 'H00000000002'},
      {'seatingStatus': 'departed'},
    ]) {
      final raw = reply(c);
      (raw['result']['receipt'] as Map).addAll(patch);
      expect(() => SeatingResult.parse(raw, c), throwsA(isA<CcsopFailure>()));
    }
    final encoded = c.encode();
    encoded['params'] = {...c.params, 'identityCode': 'KC:M:${'A' * 32}'};
    expect(() => PendingSeating.decode(encoded), throwsA(isA<CcsopFailure>()));
  });
  test('journal survives restart, refuses duplicate member requests and only removes a verified terminal result', () async {
    final storage = a.TestStorage(),
        journal = SeatingJournal(storage: a.TestStorage());
    final j = SeatingJournal(storage: storage),
        c = command(),
        owner = a.session({...a.response(), 'permissions': permissions});
    await j.save(c, owner);
    expect(
      (await SeatingJournal(storage: storage).load(owner)).single.signature,
      c.signature,
    );
    await expectLater(j.save(command(), owner), throwsA(isA<CcsopFailure>()));
    await expectLater(
      j.acknowledge(owner, SeatingResult.parse(reply(c, 'not_observed'), c)),
      throwsA(isA<CcsopFailure>()),
    );
    expect(await journal.load(owner), isEmpty);
    await j.acknowledge(owner, SeatingResult.parse(reply(c, 'cancelled'), c));
    expect(await j.load(owner), isEmpty);
  });
  test('controller saves before send, retains unknown, then queries before cancellation and clears only terminal', () async {
    final storage = a.TestStorage(), api = SeatApi(), c = command();
    api.expected = c;
    api.unknown = true;
    final controller = StaffAuthController(
      vault: SessionVault(
        storage: a.TestStorage()..data[SessionVault.deviceKey] = a.device,
      ),
      authFactory: (_) =>
          a.TestAuth()..result = {...a.response(), 'permissions': permissions},
      sessionFactory: (_) => api,
      now: () => a.now,
      seatingJournal: SeatingJournal(storage: storage),
    );
    await a.login(controller);
    await expectLater(
      controller.confirmSeating(
        c,
        'KC:M:${'A' * 32}',
        confirmed: true,
        stillCurrent: () => true,
      ),
      throwsA(isA<CcsopFailure>()),
    );
    expect((await controller.pendingSeating()).single.requestId, c.requestId);
    expect(storage.data.values.join(), isNot(contains('KC:M:')));
    expect(
      (await controller.recoverSeating(c.requestId)).state,
      'not_observed',
    );
    expect((await controller.pendingSeating()).length, 1);
    expect(
      (await controller.recoverSeating(
        c.requestId,
        cancelUnsent: true,
        stillCurrent: () => true,
      )).state,
      'cancelled',
    );
    expect(api.calls, [
      'K261001001952',
      'K261001001953',
      'K261001001953',
      'K261001001954',
    ]);
    expect(await controller.pendingSeating(), isEmpty);
    controller.dispose();
  });
  test('secure write failure prevents send; loss of caller confirmation during save prevents admission', () async {
    for (final fail in [true, false]) {
      final storage = a.TestStorage()..fail = fail,
          api = SeatApi()..expected = command();
      final controller = StaffAuthController(
        vault: SessionVault(
          storage: a.TestStorage()..data[SessionVault.deviceKey] = a.device,
        ),
        authFactory: (_) =>
            a.TestAuth()
              ..result = {...a.response(), 'permissions': permissions},
        sessionFactory: (_) => api,
        now: () => a.now,
        seatingJournal: SeatingJournal(storage: storage),
      );
      await a.login(controller);
      var checks = 0;
      await expectLater(
        controller.confirmSeating(
          api.expected!,
          'KC:M:${'A' * 32}',
          confirmed: true,
          stillCurrent: () => ++checks == 1,
        ),
        throwsA(isA<CcsopFailure>()),
      );
      expect(api.calls, isEmpty);
      controller.dispose();
    }
  });
  test(
    'late success after logout cannot acknowledge a pending original command',
    () async {
      final storage = a.TestStorage(),
          api = SeatApi()..gate = Completer<Object?>(),
          c = command();
      api.expected = c;
      final controller = StaffAuthController(
        vault: SessionVault(
          storage: a.TestStorage()..data[SessionVault.deviceKey] = a.device,
        ),
        authFactory: (_) =>
            a.TestAuth()
              ..result = {...a.response(), 'permissions': permissions},
        sessionFactory: (_) => api,
        now: () => a.now,
        seatingJournal: SeatingJournal(storage: storage),
      );
      await a.login(controller);
      final owner = controller.session!;
      final pending = controller.confirmSeating(
        c,
        'KC:M:${'A' * 32}',
        confirmed: true,
        stillCurrent: () => true,
      );
      final rejected = expectLater(pending, throwsA(isA<CcsopFailure>()));
      await api.called.future.timeout(const Duration(seconds: 2));
      await controller.logout();
      api.gate!.complete(reply(c));
      await rejected;
      expect(
        (await SeatingJournal(storage: storage).load(owner)).single.signature,
        c.signature,
      );
      controller.dispose();
    },
  );
  testWidgets(
    'table scan uses one confirmation and rereads current members after seating',
    (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = SeatViewAuth();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveOrderMembersPanel(
              auth: auth,
              language: UiLanguage.zh,
              tableRef: 'test-table',
              sessionRef: 'H00000000001',
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('order-members-seat')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('member-identity-code')),
        'KC:M:${'A' * 32}',
      );
      await tester.tap(find.byKey(const ValueKey('member-identity-scan')));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(auth.confirms, 0);
      await tester.ensureVisible(find.byKey(const ValueKey('seating-confirm')));
      await tester.tap(find.byKey(const ValueKey('seating-confirm')));
      await tester.pumpAndSettle();
      expect(auth.confirms, 1);
      expect(auth.reads, greaterThanOrEqualTo(2));
      expect(
        find.byKey(const ValueKey('order-member-test-member')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets('seating screen and recoverable request fit all languages', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = SeatViewAuth()..rows.add(command());
    for (final language in UiLanguage.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MemberSeatingPanel(
              auth: auth,
              language: language,
              orderContext: contextSnapshot(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });
}
