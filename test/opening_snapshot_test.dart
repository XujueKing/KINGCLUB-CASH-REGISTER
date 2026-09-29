import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/opening_snapshot.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as auth;

const request = '00000000-0000-4000-8000-000000000009';

class OpeningApi extends auth.TestApi {
  String? interfaceId;
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) {
    interfaceId = id;
    return super.call(id, params);
  }
}

Map<String, dynamic> context() => {
  'storeRef': 'test-store',
  'tableId': 'test-table',
  'tableName': 'Test table',
  'tableStatus': 'active',
  'paymentTiming': 'postpay',
  'businessDate': '2026-09-29',
  'minimumSeats': 1,
  'maximumSeats': 4,
  'ruleSource': 'configured',
  'rule': {
    'revision': 1,
    'businessDate': '2026-09-29',
    'rule': {'mode': 'manual'},
  },
  'activeSession': null,
  'openingEnabled': false,
  'requiresStaffConfirmation': true,
  'automaticReservationCheck': false,
  'observedAt': '2026-09-29T00:00:00.000Z',
};
Map<String, dynamic> receipt() => {
  'storeRef': 'test-store',
  'tableId': 'test-table',
  'sessionRef': 'H00000000001',
  'businessDate': '2026-09-29',
  'paymentTiming': 'postpay',
  'memberRefs': ['test-member'],
};
OpeningContext parseContext(Map<String, dynamic> value) => OpeningContext.parse(
  {'result': value},
  storeRef: 'test-store',
  tableId: 'test-table',
);
OpeningLookup parseLookup(Map<String, dynamic> value) => OpeningLookup.parse(
  {'result': value},
  storeRef: 'test-store',
  tableId: 'test-table',
  requestId: request,
);

void main() {
  test(
    'expiry during a read rejects the result and prevents another query',
    () async {
      var clock = auth.now;
      final channel = OpeningApi()..pendingRead = Completer<Object?>();
      final loginChannel = auth.TestAuth()
        ..result = {
          ...auth.response(),
          'permissions': ['workbench.read', 'table.open'],
        };
      final c = StaffAuthController(
        vault: SessionVault(storage: auth.TestStorage()),
        authFactory: (_) => loginChannel,
        sessionFactory: (_) => channel,
        now: () => clock,
      );
      await auth.login(c);
      final pending = c.readOpeningContext(tableId: 'test-table');
      final rejected = expectLater(pending, throwsA(isA<CcsopFailure>()));
      clock = clock.add(const Duration(minutes: 16));
      channel.pendingRead!.complete({'result': context()});
      await rejected;
      channel.interfaceId = null;
      await expectLater(
        c.readOpeningReceipt(tableId: 'test-table', requestId: request),
        throwsA(isA<CcsopFailure>()),
      );
      expect(channel.interfaceId, isNull);
      c.dispose();
    },
  );
  test('all daily rules retain amounts/counts and explicit manual default', () {
    for (final rule in [
      {'mode': 'manual'},
      {'mode': 'aa', 'reservationRequired': true},
      {'mode': 'minimum_people', 'minimumPeople': 3},
      {'mode': 'minimum_spend', 'minimumSpendCents': 2147483647},
    ]) {
      final value = parseContext({
        ...context(),
        'rule': {'revision': 1, 'businessDate': '2026-09-29', 'rule': rule},
      });
      expect(value.mode, rule['mode']);
      expect(value.minimumSpendCents, rule['minimumSpendCents']);
      expect(value.minimumPeople, rule['minimumPeople']);
      expect(value.openingEnabled, isFalse);
    }
    expect(
      parseContext({
        ...context(),
        'ruleSource': 'manual_default',
        'rule': {
          'revision': 0,
          'businessDate': '2026-09-29',
          'rule': {'mode': 'manual'},
        },
      }).revision,
      0,
    );
  });
  test('disabled tables and existing clearing sessions remain explicit', () {
    final value = parseContext({
      ...context(),
      'tableStatus': 'disabled',
      'minimumSeats': null,
      'activeSession': {'sessionRef': 'H00000000001', 'status': 'clearing'},
    });
    expect(value.minimumSeats, isNull);
    expect(value.activeSessionStatus, 'clearing');
  });
  test('rejects mismatched scope, invalid date, flags, capacity and rule', () {
    for (final patch in <Map<String, dynamic>>[
      {'storeRef': 'other'},
      {'tableId': 'other'},
      {'businessDate': '2026-02-30'},
      {'minimumSeats': 5},
      {'maximumSeats': 0},
      {'openingEnabled': 'true'},
      {'requiresStaffConfirmation': false},
      {'automaticReservationCheck': true},
      {'observedAt': '2026-02-30T00:00:00.000Z'},
      {'ruleSource': 'manual_default'},
      {
        'rule': {
          'revision': 0,
          'businessDate': '2026-09-29',
          'rule': {'mode': 'manual'},
        },
      },
      {
        'rule': {
          'revision': 1,
          'businessDate': '2026-09-28',
          'rule': {'mode': 'aa'},
        },
      },
      {
        'rule': {
          'revision': 1,
          'businessDate': '2026-09-29',
          'rule': {'mode': 'aa', 'minimumPeople': 1},
        },
      },
      {
        'rule': {
          'revision': 1,
          'businessDate': '2026-09-29',
          'rule': {'mode': 'minimum_spend', 'minimumSpendCents': 0},
        },
      },
    ]) {
      expect(
        () => parseContext({...context(), ...patch}),
        throwsA(isA<CcsopFailure>()),
      );
    }
  });
  test('not observed never becomes failure; later query may be confirmed', () {
    expect(
      parseLookup({'state': 'not_observed', 'requestId': request}).state,
      OpeningLookupState.notObserved,
    );
    final found = parseLookup({
      'state': 'confirmed',
      'requestId': request,
      'receipt': receipt(),
    });
    expect(found.state, OpeningLookupState.confirmed);
    expect(found.receipt!.sessionRef, 'H00000000001');
    expect(
      () => found.receipt!.memberRefs.add('another'),
      throwsUnsupportedError,
    );
  });
  test(
    'rejects contradictory, cross-scope, malformed and duplicate receipts',
    () {
      for (final patch in <Map<String, dynamic>>[
        {'storeRef': 'other'},
        {'tableId': 'other'},
        {'sessionRef': 'test'},
        {'businessDate': '2026-02-30'},
        {
          'memberRefs': ['same', 'same'],
        },
        {'paymentTiming': 'unknown'},
        {
          'memberRefs': ['bad/ref'],
        },
      ]) {
        expect(
          () => parseLookup({
            'state': 'confirmed',
            'requestId': request,
            'receipt': {...receipt(), ...patch},
          }),
          throwsA(isA<CcsopFailure>()),
        );
      }
      for (final value in [
        {'state': 'confirmed', 'requestId': request},
        {'state': 'not_observed', 'requestId': request, 'receipt': receipt()},
        {'state': 'failed', 'requestId': request},
        {'state': 'not_observed', 'requestId': auth.device},
      ]) {
        expect(() => parseLookup(value), throwsA(isA<CcsopFailure>()));
      }
    },
  );
  test(
    'employee opening reads bind store and parse confirmed server shapes',
    () async {
      final channel = OpeningApi()..pendingRead = Completer<Object?>();
      final c = auth.controller(
        auth.TestStorage(),
        auth.TestAuth()
          ..result = {
            ...auth.response(),
            'permissions': ['workbench.read', 'table.open'],
          },
        channel,
      );
      await auth.login(c);
      final reading = c.readOpeningContext(tableId: 'test-table');
      expect(channel.interfaceId, 'K260929001907');
      expect(channel.params, {
        'storeRef': 'test-store',
        'tableId': 'test-table',
      });
      channel.pendingRead!.complete({'result': context()});
      expect((await reading).tableId, 'test-table');
      channel.pendingRead = Completer<Object?>();
      final recovering = c.readOpeningReceipt(
        tableId: 'test-table',
        requestId: request,
      );
      expect(channel.interfaceId, 'K260929001908');
      expect(channel.params, {
        'storeRef': 'test-store',
        'tableId': 'test-table',
        'requestId': request,
      });
      channel.pendingRead!.complete({
        'result': {'state': 'not_observed', 'requestId': request},
      });
      expect((await recovering).state, OpeningLookupState.notObserved);
      c.dispose();
    },
  );
  test('no opening permission sends no query', () async {
    final channel = auth.TestApi();
    final c = auth.controller(auth.TestStorage(), auth.TestAuth(), channel);
    await auth.login(c);
    await expectLater(
      c.readOpeningContext(tableId: 'test-table'),
      throwsA(isA<CcsopFailure>()),
    );
    await expectLater(
      c.readOpeningReceipt(tableId: 'test-table', requestId: request),
      throwsA(isA<CcsopFailure>()),
    );
    expect(channel.params, isNull);
    c.dispose();
  });
  test('logout discards late context and receipt responses', () async {
    for (final recovery in [false, true]) {
      final channel = auth.TestApi()..pendingRead = Completer<Object?>();
      final c = auth.controller(
        auth.TestStorage(),
        auth.TestAuth()
          ..result = {
            ...auth.response(),
            'permissions': ['workbench.read', 'table.open'],
          },
        channel,
      );
      await auth.login(c);
      final pending = recovery
          ? c.readOpeningReceipt(tableId: 'test-table', requestId: request)
          : c.readOpeningContext(tableId: 'test-table');
      final rejected = expectLater(pending, throwsA(isA<CcsopFailure>()));
      await c.logout();
      channel.pendingRead!.complete({
        'result': recovery
            ? {'state': 'confirmed', 'requestId': request, 'receipt': receipt()}
            : context(),
      });
      await rejected;
      c.dispose();
    }
  });
}
