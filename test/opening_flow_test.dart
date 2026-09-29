import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/opening_journal.dart';
import 'package:kingclub_cash_register/src/live/opening_snapshot.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as auth;
import 'opening_snapshot_test.dart' as fixture;

class FlowApi implements SessionChannel {
  final calls = <({String id, Map<String, dynamic> params})>[];
  Future<Object?> Function(String, Map<String, dynamic>)? handler;
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    calls.add((id: id, params: params));
    if (id == 'K260929001904') {
      return {
        'result': {'loggedOut': true},
      };
    }
    return handler!(id, params);
  }

  @override
  void close() {}
}

class GateStorage extends auth.TestStorage {
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> write(String key, String value) async {
    if (key == OpeningJournal.storageKey) {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    }
    await super.write(key, value);
  }
}

StaffAuthController controller(auth.TestStorage storage, FlowApi api) =>
    StaffAuthController(
      vault: SessionVault(storage: storage),
      openingJournal: OpeningJournal(storage: storage),
      authFactory: (_) => auth.TestAuth()
        ..result = {
          ...auth.response(),
          'permissions': ['workbench.read', 'table.open'],
        },
      sessionFactory: (_) => api,
      now: () => auth.now,
    );
Future<OpeningLookup> submit(StaffAuthController c) => c.submitOpening(
  context: fixture.parseContext({...fixture.context(), 'openingEnabled': true}),
  partySize: 2,
  memberRefs: ['test-member'],
  arrivalConfirmed: true,
  reservationChecked: true,
);
Object response() => {'result': fixture.receipt()};
Object lookup(Map<String, dynamic> params, bool confirmed) => {
  'result': {
    'state': confirmed ? 'confirmed' : 'not_observed',
    'requestId': params['requestId'],
    if (confirmed) 'receipt': fixture.receipt(),
  },
};

void main() {
  test('explicit cancellation clears only after server fence, then permits a fresh request', () async {
    final storage = auth.TestStorage(), api = FlowApi();
    final c = controller(storage, api);
    await auth.login(c);
    api.handler = (_, _) async =>
        throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    await expectLater(submit(c), throwsA(isA<CcsopFailure>()));
    final id = (await c.pendingOpenings()).single.requestId;
    await expectLater(
      c.cancelOpening(id, confirmed: false),
      throwsA(isA<CcsopFailure>()),
    );
    expect(api.calls, hasLength(1));
    api.handler = (endpoint, params) async {
      expect(endpoint, 'K260929001909');
      expect(params, {
        'storeRef': 'test-store',
        'tableId': 'test-table',
        'requestId': id,
      });
      return {
        'result': {'state': 'cancelled', 'requestId': id},
      };
    };
    expect(
      (await c.cancelOpening(id, confirmed: true)).state,
      OpeningLookupState.cancelled,
    );
    expect(await c.pendingOpenings(), isEmpty);
    api.handler = (_, _) async => response();
    await submit(c);
    expect(api.calls.last.params['requestId'], isNot(id));
    c.dispose();
  });
  test(
    'cancellation losing race to opening returns the original success',
    () async {
      final storage = auth.TestStorage(), api = FlowApi();
      final c = controller(storage, api);
      await auth.login(c);
      api.handler = (_, _) async =>
          throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
      await expectLater(submit(c), throwsA(isA<CcsopFailure>()));
      final id = (await c.pendingOpenings()).single.requestId;
      api.handler = (_, params) async => lookup(params, true);
      expect(
        (await c.cancelOpening(id, confirmed: true)).state,
        OpeningLookupState.confirmed,
      );
      expect(await c.pendingOpenings(), isEmpty);
      c.dispose();
    },
  );
  test('uncertain cancellation keeps record; recovery of cancelled never retries opening', () async {
    final storage = auth.TestStorage(), api = FlowApi();
    final c = controller(storage, api);
    await auth.login(c);
    api.handler = (_, _) async =>
        throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    await expectLater(submit(c), throwsA(isA<CcsopFailure>()));
    final id = (await c.pendingOpenings()).single.requestId;
    await expectLater(
      c.cancelOpening(id, confirmed: true),
      throwsA(isA<CcsopFailure>()),
    );
    expect(await c.pendingOpenings(), hasLength(1));
    api.handler = (endpoint, params) async {
      expect(endpoint, 'K260929001908');
      return {
        'result': {'state': 'cancelled', 'requestId': id},
      };
    };
    expect(
      (await c.recoverOpening(id, retryOriginal: true)).state,
      OpeningLookupState.cancelled,
    );
    expect(api.calls.where((call) => call.id == 'K260929001906'), hasLength(1));
    expect(await c.pendingOpenings(), isEmpty);
    c.dispose();
  });
  test('unknown or contradictory cancellation response never clears pending request', () async {
    for (final state in ['not_observed', 'cancelled']) {
      final storage = auth.TestStorage(), api = FlowApi();
      final c = controller(storage, api);
      await auth.login(c);
      api.handler = (_, _) async =>
          throw const CcsopFailure('TRANSPORT_FAILED');
      await expectLater(submit(c), throwsA(isA<CcsopFailure>()));
      final id = (await c.pendingOpenings()).single.requestId;
      api.handler = (_, _) async => {
        'result': {
          'state': state,
          'requestId': id,
          if (state == 'cancelled') 'receipt': fixture.receipt(),
        },
      };
      await expectLater(
        c.cancelOpening(id, confirmed: true),
        throwsA(isA<CcsopFailure>()),
      );
      expect(await c.pendingOpenings(), hasLength(1));
      c.dispose();
    }
  });
  test(
    'save completes before command; confirmed receipt clears journal',
    () async {
      final storage = GateStorage(), api = FlowApi();
      final c = controller(storage, api);
      await auth.login(c);
      api.handler = (id, params) async {
        expect(id, 'K260929001906');
        expect(
          storage.data[OpeningJournal.storageKey],
          contains(params['requestId'] as String),
        );
        return response();
      };
      final submitting = submit(c);
      await storage.entered.future;
      expect(api.calls, isEmpty);
      storage.release.complete();
      expect((await submitting).state, OpeningLookupState.confirmed);
      expect(await c.pendingOpenings(), isEmpty);
      c.dispose();
    },
  );
  test('failed persistence sends nothing', () async {
    final storage = auth.TestStorage(), api = FlowApi();
    final c = controller(storage, api);
    await auth.login(c);
    storage.fail = true;
    await expectLater(submit(c), throwsA(isA<CcsopFailure>()));
    expect(api.calls, isEmpty);
    c.dispose();
  });
  test('logout while saving preserves journal but prevents command', () async {
    final storage = GateStorage(), api = FlowApi();
    final c = controller(storage, api);
    await auth.login(c);
    final originalIdentity = c.session!;
    final submitting = submit(c);
    final rejected = expectLater(submitting, throwsA(isA<CcsopFailure>()));
    await storage.entered.future;
    await c.logout();
    storage.release.complete();
    await rejected;
    expect(api.calls.map((c) => c.id), ['K260929001904']);
    expect(
      await OpeningJournal(storage: storage).load(originalIdentity),
      hasLength(1),
    );
    c.dispose();
  });
  test('timeout keeps original params; recovery reads only; explicit retry uses same command', () async {
    final storage = auth.TestStorage(), api = FlowApi();
    var fail = true;
    api.handler = (id, params) async {
      if (id == 'K260929001908') return lookup(params, false);
      if (fail) {
        throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
      }
      return response();
    };
    final c = controller(storage, api);
    await auth.login(c);
    await expectLater(submit(c), throwsA(isA<CcsopFailure>()));
    final original = api.calls.single.params;
    final id = (await c.pendingOpenings()).single.requestId;
    expect((await c.recoverOpening(id)).state, OpeningLookupState.notObserved);
    expect(api.calls.where((c) => c.id == 'K260929001906'), hasLength(1));
    await expectLater(submit(c), throwsA(isA<CcsopFailure>()));
    fail = false;
    expect(
      (await c.recoverOpening(id, retryOriginal: true)).state,
      OpeningLookupState.confirmed,
    );
    expect(api.calls.map((c) => c.id), [
      'K260929001906',
      'K260929001908',
      'K260929001908',
      'K260929001906',
    ]);
    expect(api.calls.last.params, original);
    expect(await c.pendingOpenings(), isEmpty);
    c.dispose();
  });
  test(
    'restart recovers committed receipt without repeating command',
    () async {
      final storage = auth.TestStorage(), api = FlowApi();
      api.handler = (_, params) async =>
          throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
      final old = controller(storage, api);
      await auth.login(old);
      await expectLater(submit(old), throwsA(isA<CcsopFailure>()));
      final request = (await old.pendingOpenings()).single.requestId;
      old.dispose();
      final nextApi = FlowApi()
        ..handler = (_, params) async => lookup(params, true);
      final c = controller(storage, nextApi);
      await auth.login(c);
      expect(
        (await c.recoverOpening(request, retryOriginal: true)).state,
        OpeningLookupState.confirmed,
      );
      expect(nextApi.calls.map((c) => c.id), ['K260929001908']);
      expect(await c.pendingOpenings(), isEmpty);
      c.dispose();
    },
  );
  test('concurrent submit rejected; logout discards late success but retains recovery', () async {
    final storage = auth.TestStorage(), api = FlowApi();
    final sent = Completer<void>(), result = Completer<Object?>();
    api.handler = (_, _) {
      sent.complete();
      return result.future;
    };
    final c = controller(storage, api);
    await auth.login(c);
    final identity = c.session!;
    final first = submit(c);
    final rejected = expectLater(first, throwsA(isA<CcsopFailure>()));
    await sent.future;
    await expectLater(submit(c), throwsA(isA<CcsopFailure>()));
    await c.logout();
    result.complete(response());
    await rejected;
    expect(await OpeningJournal(storage: storage).load(identity), hasLength(1));
    c.dispose();
  });
  test(
    'malformed or mismatched successful response does not clear recovery',
    () async {
      for (final raw in [
        <String, dynamic>{'result': {}},
        {
          'result': {
            ...fixture.receipt(),
            'memberRefs': ['other'],
          },
        },
      ]) {
        final storage = auth.TestStorage(),
            api = FlowApi()..handler = (_, _) async => raw;
        final c = controller(storage, api);
        await auth.login(c);
        await expectLater(submit(c), throwsA(isA<CcsopFailure>()));
        expect(await c.pendingOpenings(), hasLength(1));
        c.dispose();
      }
    },
  );
}
