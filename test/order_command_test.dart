import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/catalog_snapshot.dart';
import 'package:kingclub_cash_register/src/live/order_command.dart';
import 'package:kingclub_cash_register/src/live/order_journal.dart';
import 'package:kingclub_cash_register/src/live/cart_draft_store.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as a;
import 'catalog_snapshot_test.dart' as c;
import 'order_context_test.dart' as m;

final identity = a.session({
  ...a.response(),
  'permissions': ['workbench.read', 'orders.create'],
});
List<OrderSelection> selection() => [
  OrderSelection(
    CatalogProduct({
      ...c.product(),
      'inventoryKnown': true,
      'available': 10,
      'soldOut': false,
    }),
    2,
  ),
];
PendingOrder command() => PendingOrder.prepare(
  identity: identity,
  context: m.parse(m.contextData()),
  memberRef: 'member-000',
  items: selection(),
  now: a.now,
);
Map<String, dynamic> receipt(Map<String, dynamic> p) => {
  'requestId': p['requestId'],
  'orderRef': 'D00000000001',
  'storeRef': p['storeRef'],
  'tableRef': p['tableRef'],
  'sessionRef': p['sessionRef'],
  'memberRef': p['memberRef'],
  'paymentTiming': p['expectedPaymentTiming'],
  'inventoryState': p['expectedPaymentTiming'] == 'prepay'
      ? 'reserved'
      : 'issued',
  'currency': 'CNY',
  'submissionStatus': 'confirmed',
  'totalCents': (p['items'] as List).fold<int>(
    0,
    (sum, item) =>
        sum + (item['quantity'] as int) * (item['expectedPriceCents'] as int),
  ),
};
Matcher fails(String code) =>
    throwsA(isA<CcsopFailure>().having((e) => e.code, 'code', code));

class Storage extends a.TestStorage {
  bool drop = false, uncertain = false;
  @override
  Future<void> write(String key, String value) async {
    if (key == OrderJournal.storageKey && drop) return;
    await super.write(key, value);
    if (key == OrderJournal.storageKey && uncertain) {
      throw StateError('TEST ONLY storage failure');
    }
  }
}

class Api extends a.TestApi {
  final calls = <(String, Map<String, dynamic>)>[];
  bool failSubmit = false;
  Completer<Object?>? gate;
  final sent = Completer<void>();
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    if (id == 'K260929001904') return super.call(id, params);
    calls.add((id, params));
    if (id == 'K260929001912') {
      if (!sent.isCompleted) sent.complete();
      if (failSubmit) {
        throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
      }
      if (gate != null) return gate!.future;
      return {'result': receipt(params)};
    }
    return {
      'result': {
        'state': id == 'K260929001914' ? 'cancelled' : 'not_observed',
        'requestId': params['requestId'],
      },
    };
  }
}

Future<StaffAuthController> controller(
  Storage storage,
  Api api, {
  DateTime Function()? now,
}) async {
  storage.data[SessionVault.deviceKey] = a.device;
  final auth = a.TestAuth()
    ..result = {
      ...a.response(),
      'permissions': ['workbench.read', 'orders.create'],
    };
  final value = StaffAuthController(
    vault: SessionVault(storage: storage),
    orderJournal: OrderJournal(storage: storage),
    cartDraftStore: CartDraftStore(storage: storage),
    authFactory: (_) => auth,
    sessionFactory: (_) => api,
    now: now ?? () => a.now,
  );
  await value.login(
    base: 'https://service.invalid/prefix',
    storeRef: 'test-store',
    loginName: 'TEST_ONLY',
    password: 'TEST_ONLY',
  );
  return value;
}

Future<OrderRequestResult> submit(
  StaffAuthController auth, {
  bool confirmed = true,
}) => auth.submitOrder(
  context: m.parse(m.contextData()),
  memberRef: 'member-000',
  items: selection(),
  confirmed: confirmed,
);

void main() {
  test(
    'special batch receipt validates each price group and survives persistence',
    () {
      final p = selection().first.product;
      final pending = PendingOrder.prepare(
        identity: identity,
        context: m.parse(m.contextData()),
        memberRef: 'member-000',
        now: a.now,
        items: [
          OrderSelection(p, 1),
          OrderSelection(p, 2, unitPriceCents: 321, selectionRef: 'price-test'),
        ],
      );
      final restored = PendingOrder.decode(jsonDecode(pending.signature));
      expect(restored.totalCents, p.priceCents + 642);
      final valid = {
        ...receipt(pending.params),
        'totalCents': p.priceCents,
        'batchTotalCents': p.priceCents + 642,
        'batchOrders': [
          {'orderRef': 'D00000000001', 'totalCents': p.priceCents},
          {'orderRef': 'D00000000002', 'totalCents': 642},
        ],
      };
      expect(
        () => OrderRequestResult.parse(
          {'result': valid},
          restored,
          submission: true,
        ),
        returnsNormally,
      );
      for (final patch in [
        {'batchTotalCents': p.priceCents + 643},
        {
          'batchOrders': [
            {'orderRef': 'D00000000001', 'totalCents': p.priceCents},
            {'orderRef': 'D00000000001', 'totalCents': 642},
          ],
        },
        {
          'batchOrders': [
            {'orderRef': 'D00000000001', 'totalCents': p.priceCents},
            {'orderRef': 'D00000000002', 'totalCents': 643},
          ],
        },
      ]) {
        expect(
          () => OrderRequestResult.parse(
            {
              'result': {...valid, ...patch},
            },
            restored,
            submission: true,
          ),
          throwsA(anything),
        );
      }
    },
  );
  test(
    'table order without member survives persistence and binds its receipt',
    () {
      final context = m.parse({...m.contextData(), 'tableOrderAllowed': true});
      final pending = PendingOrder.prepare(
        identity: identity,
        context: context,
        memberRef: null,
        items: selection(),
        now: a.now,
      );
      final restored = PendingOrder.decode(
        jsonDecode(jsonEncode(pending.encode())),
      );
      expect(restored.memberRef, isNull);
      expect(restored.signature, pending.signature);
      expect(
        OrderRequestResult.parse(
          {'result': receipt(restored.params)},
          restored,
          submission: true,
        ).state,
        OrderRequestState.confirmed,
      );
      expect(
        () => PendingOrder.prepare(
          identity: identity,
          context: m.parse(m.contextData()),
          memberRef: null,
          items: selection(),
          now: a.now,
        ),
        fails('ORDERING_CONTEXT_CHANGED'),
      );
    },
  );
  test(
    'prepay selection ignores inventory snapshots but retains quantity limits',
    () {
      final product = CatalogProduct(c.product());
      expect(OrderSelection(product, 2, paymentTiming: 'prepay').quantity, 2);
      for (final quantity in [0, 1001]) {
        expect(
          () => OrderSelection(product, quantity, paymentTiming: 'prepay'),
          fails('ORDERING_OUT_OF_STOCK'),
        );
      }
      expect(
        () => OrderSelection(product, 2, paymentTiming: 'postpay'),
        fails('ORDERING_OUT_OF_STOCK'),
      );
    },
  );

  test('prepay receipt accepts payment-time allocation and historical reservations only', () {
    final context = m.contextData();
    (context['session'] as Map)['paymentTiming'] = 'prepay';
    final pending = PendingOrder.prepare(
      identity: identity,
      context: m.parse(context),
      memberRef: 'member-000',
      items: selection(),
      now: a.now,
    );
    for (final state in ['unallocated', 'reserved']) {
      expect(
        OrderRequestResult.parse(
          {
            'result': {...receipt(pending.params), 'inventoryState': state},
          },
          pending,
          submission: true,
        ).state,
        OrderRequestState.confirmed,
      );
    }
    for (final state in ['issued', 'released']) {
      expect(
        () => OrderRequestResult.parse(
          {
            'result': {...receipt(pending.params), 'inventoryState': state},
          },
          pending,
          submission: true,
        ),
        fails('ORDER_RECEIPT_MISMATCH'),
      );
    }
    final postpay = command();
    for (final state in ['unallocated', 'reserved', 'issued']) {
      expect(
        OrderRequestResult.parse(
          {
            'result': {...receipt(postpay.params), 'inventoryState': state},
          },
          postpay,
          submission: true,
        ).state,
        OrderRequestState.confirmed,
      );
    }
    for (final state in ['partial', 'released']) {
      expect(
        () => OrderRequestResult.parse(
          {
            'result': {...receipt(postpay.params), 'inventoryState': state},
          },
          postpay,
          submission: true,
        ),
        fails('ORDER_RECEIPT_MISMATCH'),
      );
    }
  });
  test('command has immutable nested items, stable UUID, exact prices and no authentication material', () {
    final p = command();
    expect(p.totalCents, 2468);
    expect(PendingOrder.decode(jsonDecode(p.signature)).signature, p.signature);
    expect(() => p.params['items'][0]['quantity'] = 9, throwsUnsupportedError);
    expect(() => (p.params['items'] as List).clear(), throwsUnsupportedError);
    for (final secret in ['apiKey', 'refreshToken', 'nickname', 'password']) {
      expect(p.signature, isNot(contains(secret)));
    }
    expect(command().requestId, isNot(p.requestId));
  });
  test('rejects ineligible consumers, unknown inventory, duplicate items and total overflow', () {
    expect(
      () => PendingOrder.prepare(
        identity: identity,
        context: m.parse(m.contextData()),
        memberRef: 'member-001',
        items: selection(),
        now: a.now,
      ),
      fails('ORDERING_CONTEXT_CHANGED'),
    );
    expect(
      () => OrderSelection(CatalogProduct(c.product()), 1),
      fails('ORDERING_OUT_OF_STOCK'),
    );
    final p = command(), raw = jsonDecode(p.signature) as Map<String, dynamic>;
    final params = raw['params'] as Map<String, dynamic>;
    params['items'] = [...params['items'], ...params['items']];
    expect(() => PendingOrder.decode(raw), fails('ORDER_COMMAND_INVALID'));
    params['items'] = [
      {
        'productRef': 'TEST',
        'quantity': 2,
        'expectedRevision': 1,
        'expectedPriceCents': 100000000,
      },
    ];
    expect(() => PendingOrder.decode(raw), fails('ORDER_COMMAND_INVALID'));
  });
  test('receipt validates original member, mode, amount, scope and rejects payment hints', () {
    final p = command(), original = receipt(p.params);
    expect(
      OrderRequestResult.parse({'result': original}, p, submission: true).state,
      OrderRequestState.confirmed,
    );
    for (final patch in [
      {'totalCents': 1},
      {'memberRef': 'other'},
      {'sessionRef': 'H00000000002'},
      {'storeRef': 'other'},
      {'requestId': command().requestId},
      {'inventoryState': 'partial'},
      {'submissionStatus': 'paid'},
      {'orderRef': 'bad'},
    ]) {
      expect(
        () => OrderRequestResult.parse(
          {
            'result': {...original, ...patch},
          },
          p,
          submission: true,
        ),
        fails('ORDER_RECEIPT_MISMATCH'),
      );
    }
  });
  test(
    'journal survives restart and never acknowledges not_observed',
    () async {
      final storage = Storage(),
          p = command(),
          journal = OrderJournal(storage: storage);
      await journal.save(p, identity);
      await journal.save(p, identity);
      expect(
        (await OrderJournal(storage: storage).load(identity)).single.signature,
        p.signature,
      );
      final result = OrderRequestResult.parse({
        'result': {'state': 'not_observed', 'requestId': p.requestId},
      }, p);
      await expectLater(
        journal.acknowledge(identity, result),
        fails('ORDER_RESULT_UNCONFIRMED'),
      );
      await expectLater(
        journal.save(command(), identity),
        fails('ORDER_ALREADY_PENDING'),
      );
      expect(await journal.load(identity), hasLength(1));
    },
  );
  test('lost write blocks; uncertain write remains recoverable; corrupt journal is not purged', () async {
    final storage = Storage()..drop = true,
        p = command(),
        journal = OrderJournal(storage: storage);
    await expectLater(
      journal.save(p, identity),
      fails('ORDER_JOURNAL_UNAVAILABLE'),
    );
    storage.drop = false;
    storage.uncertain = true;
    await expectLater(
      journal.save(p, identity),
      fails('ORDER_JOURNAL_UNAVAILABLE'),
    );
    expect((await journal.load(identity)).single.requestId, p.requestId);
    storage.data[OrderJournal.storageKey] = 'bad';
    await expectLater(
      journal.load(identity),
      fails('ORDER_JOURNAL_UNAVAILABLE'),
    );
    expect(storage.data[OrderJournal.storageKey], 'bad');
  });
  test('journal isolates identity and terminal receipts cannot clear another command', () async {
    final storage = Storage(),
        journal = OrderJournal(storage: storage),
        p = command(),
        other = command();
    await journal.save(p, identity);
    final otherIdentity = a.session({
      ...a.response(),
      'employee': {'employeeRef': 'E00000000002', 'displayName': 'TEST'},
      'permissions': ['workbench.read', 'orders.create'],
    });
    expect(await journal.load(otherIdentity), isEmpty);
    final result = OrderRequestResult.parse({
      'result': {'state': 'cancelled', 'requestId': p.requestId},
    }, p);
    await expectLater(
      journal.acknowledge(otherIdentity, result),
      fails('ORDER_SCOPE_CHANGED'),
    );
    await journal.acknowledge(
      identity,
      OrderRequestResult.parse({
        'result': {'state': 'cancelled', 'requestId': other.requestId},
      }, other),
    );
    expect(await journal.load(identity), hasLength(1));
    await journal.acknowledge(identity, result);
    expect(await journal.load(identity), isEmpty);
  });
  test('controller stores before sending, and only exact confirmed receipt removes pending request', () async {
    final storage = Storage(),
        api = Api()..gate = Completer(),
        auth = await controller(storage, api);
    final work = submit(auth);
    await api.sent.future;
    expect((await auth.pendingOrders()).single.params, api.calls.single.$2);
    await expectLater(submit(auth), fails('ORDER_IN_PROGRESS'));
    api.gate!.complete({'result': receipt(api.calls.single.$2)});
    expect((await work).state, OrderRequestState.confirmed);
    expect(await auth.pendingOrders(), isEmpty);
    auth.dispose();
  });
  test(
    'failed persistence or missing confirmation sends no order packet',
    () async {
      final storage = Storage()..drop = true,
          api = Api(),
          auth = await controller(storage, api);
      await expectLater(
        submit(auth, confirmed: false),
        fails('ORDER_CONFIRMATION_REQUIRED'),
      );
      await expectLater(submit(auth), fails('ORDER_JOURNAL_UNAVAILABLE'));
      expect(api.calls, isEmpty);
      auth.dispose();
    },
  );
  test('transport ambiguity is retained; lookup is read-only; explicit retry sends identical UUID and items', () async {
    final storage = Storage(),
        api = Api()..failSubmit = true,
        auth = await controller(storage, api);
    await expectLater(submit(auth), fails('TRANSPORT_FAILED'));
    final p = (await auth.pendingOrders()).single;
    expect(
      (await auth.recoverOrder(p.requestId)).state,
      OrderRequestState.notObserved,
    );
    expect(api.calls.map((c) => c.$1), ['K260929001912', 'K260929001913']);
    api.failSubmit = false;
    await auth.recoverOrder(p.requestId, retryOriginal: true);
    expect(api.calls.last.$2, api.calls.first.$2);
    expect(await auth.pendingOrders(), isEmpty);
    auth.dispose();
  });
  test(
    'cancel needs confirmation and uses lookup scope, not changed cart values',
    () async {
      final storage = Storage(),
          api = Api()..failSubmit = true,
          auth = await controller(storage, api);
      await expectLater(submit(auth), fails('TRANSPORT_FAILED'));
      final p = (await auth.pendingOrders()).single;
      await expectLater(
        auth.cancelOrder(p.requestId, confirmed: false),
        fails('ORDER_CONFIRMATION_REQUIRED'),
      );
      expect(
        (await auth.cancelOrder(p.requestId, confirmed: true)).state,
        OrderRequestState.cancelled,
      );
      expect(api.calls.last.$1, 'K260929001914');
      expect(api.calls.last.$2, p.lookup);
      expect(await auth.pendingOrders(), isEmpty);
      auth.dispose();
    },
  );
  test('logout rejects a late response and retains original command for the original employee', () async {
    final storage = Storage(),
        api = Api()..gate = Completer(),
        auth = await controller(storage, api);
    final work = submit(auth),
        check = expectLater(work, fails('SESSION_CHANGED'));
    await api.sent.future;
    await auth.logout();
    api.gate!.complete({'result': receipt(api.calls.first.$2)});
    await check;
    expect(await OrderJournal(storage: storage).load(identity), hasLength(1));
    auth.dispose();
  });
  test(
    'expiry while awaiting receipt rejects result without clearing journal',
    () async {
      var now = a.now;
      final storage = Storage(),
          api = Api()..gate = Completer(),
          auth = await controller(storage, api, now: () => now);
      final work = submit(auth),
          check = expectLater(work, fails('SESSION_REQUIRED'));
      await api.sent.future;
      now = now.add(const Duration(minutes: 16));
      api.gate!.complete({'result': receipt(api.calls.first.$2)});
      await check;
      expect(await OrderJournal(storage: storage).load(identity), hasLength(1));
      auth.dispose();
    },
  );
}
