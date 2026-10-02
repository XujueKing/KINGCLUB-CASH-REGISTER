import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/item_return_command.dart';
import 'package:kingclub_cash_register/src/live/item_return_journal.dart';
import 'package:kingclub_cash_register/src/live/serving_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as a;
import 'cash_command_test.dart' show Storage;

final identity = a.session({
  ...a.response(),
  'permissions': [
    'workbench.read',
    'orders.create',
    'orders.serve',
    'payment.refund',
  ],
});
Map<String, dynamic> fields() => {
  'tableRef': 'TEST_TABLE',
  'sessionRef': 'H00000000001',
  'orderRef': 'D00000000001',
  'productRef': 'TEST_PRODUCT',
  'expectedQuantity': 3,
  'expectedServedQuantity': 2,
  'expectedServingEpoch': 1,
  'expectedTotalCents': 300,
  'quantity': 1,
  'returnedServedQuantity': 1,
  'physicalReturnConfirmed': true,
};
PendingItemReturn command() => PendingItemReturn.prepare(
  identity: identity,
  fields: fields(),
  unitPriceCents: 100,
  now: a.now,
);
Map<String, dynamic> result(PendingItemReturn c) => {
  'result': {
    ...c.params,
    'remainingQuantity': 2,
    'remainingTotalCents': 200,
    'orderStatus': 'pending',
    'operatedBy': c.employeeRef,
    'operation': 'return_cancel',
    'remainingServedQuantity': 1,
    'servingEpoch': 2,
    'stockReturn': {
      'returnRef': c.requestId,
      'storeRef': c.storeRef,
      'orderRef': c.orderRef,
      'productRef': c.productRef,
      'employeeRef': c.employeeRef,
      'quantity': 1,
      'purpose': 'unpaid_cancel',
      'physicalReturnConfirmed': true,
      'version': 1,
      'allocations': [
        {
          'originalMovementRef': 'M00000000001',
          'batchRef': 'TEST_BATCH',
          'quantity': 1,
          'costCents': '50',
        },
      ],
      'movements': [
        {
          'movementRef': 'M00000000002',
          'batchRef': 'TEST_BATCH',
          'quantity': 1,
          'costCents': '50',
          'onHandBefore': 2,
          'onHandAfter': 3,
        },
      ],
    },
  },
};

class Api extends a.TestApi {
  Api(this.storage);
  final Storage storage;
  final calls = <(String, Map<String, dynamic>)>[];
  Object? saved;
  bool lose = false, notCommitted = false;
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    if (id == 'K260929001904') return super.call(id, params);
    calls.add((id, Map.of(params)));
    final c = PendingItemReturn.decode(
      (jsonDecode(storage.data[ItemReturnJournal.storageKey]!)['entries']
              as List)
          .single,
    );
    expect(params, c.params);
    if (id == 'K261002001970')
      return saved ??
          {
            'result': {'state': 'not_observed', 'requestId': c.requestId},
          };
    expect(id, 'K261002001969');
    if (!notCommitted) saved = result(c);
    if (lose || notCommitted)
      throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    return saved;
  }
}

Future<StaffAuthController> controller(Storage storage, Api api) async {
  storage.data[SessionVault.deviceKey] = a.device;
  final auth = a.TestAuth()
    ..result = {
      ...a.response(),
      'permissions': [
        'workbench.read',
        'orders.create',
        'orders.serve',
        'payment.refund',
      ],
    };
  final c = StaffAuthController(
    vault: SessionVault(storage: storage),
    servingJournal: ServingJournal(storage: storage),
    itemReturnJournal: ItemReturnJournal(storage: storage),
    authFactory: (_) => auth,
    sessionFactory: (_) => api,
    now: () => a.now,
  );
  await c.login(
    base: 'https://service.invalid/prefix',
    storeRef: 'test-store',
    loginName: 'TEST_ONLY',
    password: 'TEST_ONLY',
  );
  return c;
}

void main() {
  test('failed durable write prevents network mutation', () async {
    final storage = Storage(),
        api = Api(storage),
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    storage.drop = true;
    await expectLater(
      auth.confirmItemReturn(fields: fields(), unitPriceCents: 100),
      throwsA(isA<CcsopFailure>()),
    );
    expect(api.calls, isEmpty);
  });
  test('served return needs refund permission and actual confirmation', () {
    final staff = a.session({
      ...a.response(),
      'permissions': ['workbench.read', 'orders.create', 'orders.serve'],
    });
    expect(
      () => PendingItemReturn.prepare(
        identity: staff,
        fields: fields(),
        unitPriceCents: 100,
        now: a.now,
      ),
      throwsA(isA<CcsopFailure>()),
    );
  });
  test('numeric receipt fields cannot silently become floating point', () {
    final c = command(), raw = result(command());
    final value = result(c);
    (value['result'] as Map)['expectedQuantity'] = 3.0;
    expect(
      () => ItemReturnResult.parse(value, c),
      throwsA(isA<CcsopFailure>()),
    );
    expect(() => ItemReturnResult.parse(raw, c), throwsA(isA<CcsopFailure>()));
  });
  test('canonical original survives journal restart', () async {
    final c = command(),
        storage = Storage(),
        journal = ItemReturnJournal(storage: storage);
    await journal.save(c, identity);
    expect(
      (await ItemReturnJournal(storage: storage).load(identity))
          .single
          .signature,
      c.signature,
    );
    expect(
      PendingItemReturn.decode(jsonDecode(jsonEncode(c.encode()))).signature,
      c.signature,
    );
    await expectLater(
      journal.save(command(), identity),
      throwsA(isA<CcsopFailure>()),
    );
  });
  test('verified receipt clears only its original operation', () async {
    final c = command(), journal = ItemReturnJournal(storage: Storage());
    await journal.save(c, identity);
    await journal.acknowledge(identity, ItemReturnResult.parse(result(c), c));
    expect(await journal.load(identity), isEmpty);
  });
  for (final key in [
    'remainingQuantity',
    'remainingServedQuantity',
    'remainingTotalCents',
    'servingEpoch',
    'operatedBy',
    'stockReturn',
  ]) {
    test('rejects corrupt $key receipt', () {
      final c = command(), raw = result(c);
      (raw['result'] as Map)[key] = null;
      expect(
        () => ItemReturnResult.parse(raw, c),
        throwsA(isA<CcsopFailure>()),
      );
    });
  }
  test('not observed does not clear the pending operation', () async {
    final c = command(), journal = ItemReturnJournal(storage: Storage());
    await journal.save(c, identity);
    final pending = ItemReturnResult.parse({
      'result': {'state': 'not_observed', 'requestId': c.requestId},
    }, c);
    await expectLater(
      journal.acknowledge(identity, pending),
      throwsA(isA<CcsopFailure>()),
    );
    expect(await journal.load(identity), hasLength(1));
  });
  test('physical confirmation and quantity bounds are mandatory', () {
    for (final edit in [
      {'physicalReturnConfirmed': false},
      {'quantity': 4},
      {'returnedServedQuantity': 3},
      {'expectedServingEpoch': 1000000},
    ]) {
      expect(
        () => PendingItemReturn.prepare(
          identity: identity,
          fields: {...fields(), ...edit},
          unitPriceCents: 100,
          now: a.now,
        ),
        throwsA(isA<CcsopFailure>()),
      );
    }
  });
  test(
    'lost response survives app restart and queries without repeating mutation',
    () async {
      final storage = Storage(),
          api = Api(storage)..lose = true,
          auth = await controller(storage, api);
      await expectLater(
        auth.confirmItemReturn(fields: fields(), unitPriceCents: 100),
        throwsA(isA<CcsopFailure>()),
      );
      final id = (await auth.pendingItemReturns()).single.requestId;
      auth.dispose();
      final nextApi = Api(storage)..saved = api.saved,
          next = await controller(storage, nextApi);
      addTearDown(next.dispose);
      expect((await next.recoverItemReturn(id)).confirmed, true);
      expect(nextApi.calls.single.$1, 'K261002001970');
      expect(await next.pendingItemReturns(), isEmpty);
    },
  );
  test('retry is explicit and uses identical original request', () async {
    final storage = Storage(),
        api = Api(storage)..notCommitted = true,
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    await expectLater(
      auth.confirmItemReturn(fields: fields(), unitPriceCents: 100),
      throwsA(isA<CcsopFailure>()),
    );
    final id = (await auth.pendingItemReturns()).single.requestId;
    expect((await auth.recoverItemReturn(id)).confirmed, false);
    expect(api.calls.map((c) => c.$1), ['K261002001969', 'K261002001970']);
    api.notCommitted = false;
    expect(
      (await auth.recoverItemReturn(id, retryOriginal: true)).confirmed,
      true,
    );
    expect(api.calls.last.$2, api.calls.first.$2);
  });
}
