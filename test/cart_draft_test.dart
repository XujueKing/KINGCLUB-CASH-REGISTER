import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/cart_draft.dart';
import 'package:kingclub_cash_register/src/live/cart_draft_store.dart';
import 'package:kingclub_cash_register/src/live/catalog_snapshot.dart';

import 'staff_session_test.dart' as a;
import 'order_command_test.dart' as o;
import 'order_context_test.dart' as m;
import 'catalog_snapshot_test.dart' as c;

CartDraft draft() => CartDraft.capture(
  identity: o.identity,
  context: m.parse(m.contextData()),
  memberRef: 'member-000',
  items: o.selection(),
  now: a.now,
);
Map<String, dynamic> copy(CartDraft value) =>
    jsonDecode(value.signature) as Map<String, dynamic>;
CatalogProduct product([Map<String, dynamic> changes = const {}]) =>
    CatalogProduct({
      ...c.product(),
      'inventoryKnown': true,
      'available': 10,
      'soldOut': false,
      ...changes,
    });

class Storage extends a.TestStorage {
  bool drop = false, uncertain = false;
  @override
  Future<void> write(String key, String value) async {
    if (drop) return;
    await super.write(key, value);
    if (uncertain) throw StateError('TEST_ONLY_PRIVATE_ERROR');
  }
}

void main() {
  test('draft capture requires current ordering permission and eligible seated member', () {
    for (final identity in [a.session(), o.identity]) {
      expect(
        () => CartDraft.capture(
          identity: identity,
          context: m.parse(m.contextData()),
          memberRef: identity == o.identity ? 'member-001' : 'member-000',
          items: o.selection(),
          now: a.now,
        ),
        o.fails('CART_DRAFT_CONTEXT_CHANGED'),
      );
    }
  });

  test(
    '100-draft cap does not evict old sessions; existing slot can still update',
    () async {
      final storage = Storage(), value = draft();
      final store = CartDraftStore(storage: storage);
      final entries = List.generate(
        100,
        (i) =>
            CartDraft.decode({...copy(value), 'memberRef': 'test-member-$i'}),
      );
      storage.data[CartDraftStore.storageKey] = jsonEncode({
        'version': 1,
        'entries': entries.map((e) => e.encode()).toList(),
      });
      final before = storage.data[CartDraftStore.storageKey];
      await expectLater(
        store.save(value, o.identity, previous: null),
        o.fails('CART_DRAFT_STORAGE_FULL'),
      );
      expect(storage.data[CartDraftStore.storageKey], before);
      final replacement = CartDraft.decode({
        ...copy(draft()),
        'memberRef': entries.first.memberRef,
      });
      await store.save(replacement, o.identity, previous: entries.first);
      expect((await store.load(o.identity)).length, 100);
    },
  );

  test(
    'saving and removing own draft preserves another employee record',
    () async {
      final storage = Storage(), value = draft();
      final other = CartDraft.decode({
        ...copy(value),
        'employeeRef': 'E00000000002',
      });
      storage.data[CartDraftStore.storageKey] = jsonEncode({
        'version': 1,
        'entries': [other.encode()],
      });
      final store = CartDraftStore(storage: storage);
      await store.save(value, o.identity, previous: null);
      await store.remove(value, o.identity);
      final raw = jsonDecode(storage.data[CartDraftStore.storageKey]!);
      expect(
        CartDraft.decode(raw['entries'].single).signature,
        other.signature,
      );
    },
  );

  test(
    'cross-slot compare-and-swap and oversize envelopes fail closed',
    () async {
      final storage = Storage(), value = draft();
      final store = CartDraftStore(storage: storage);
      final otherSlot = CartDraft.decode({
        ...copy(value),
        'tableRef': 'other-table',
      });
      await expectLater(
        store.save(value, o.identity, previous: otherSlot),
        o.fails('CART_DRAFT_CONTEXT_CHANGED'),
      );
      storage.data[CartDraftStore.storageKey] = ' ' * 1000001;
      await expectLater(
        store.load(o.identity),
        o.fails('CART_DRAFT_STORAGE_UNAVAILABLE'),
      );
      expect(storage.data[CartDraftStore.storageKey]!.length, 1000001);
    },
  );

  test('roundtrip is canonical, immutable and contains no receipt, names or auth secrets', () {
    final value = draft();
    expect(CartDraft.decode(copy(value)).signature, value.signature);
    expect(value.savedAt, a.now);
    expect(value.encode().keys, isNot(contains('requestId')));
    expect(value.signature, isNot(contains(a.response()['apiKey'] as String)));
    expect(value.signature, isNot(contains('TEST product')));
    expect(() => value.encode()['memberRef'] = 'other', throwsUnsupportedError);
    expect(() => value.lines.clear(), throwsUnsupportedError);
    expect(() => value.lines.single['quantity'] = 9, throwsUnsupportedError);
    final next = draft();
    expect(next.slot, value.slot);
    expect(next.signature, isNot(value.signature));
  });

  test('exact fresh scope and catalogue restore selections but do not make commands', () {
    final value = draft();
    final rows = value.restore(
      identity: o.identity,
      context: m.parse(m.contextData()),
      products: [product()],
      now: a.now,
    );
    expect(rows.single.quantity, 2);
    expect(rows.single.product.available, 10);
    expect(() => rows.clear(), throwsUnsupportedError);
  });

  test('missing, repriced, revised, insufficient and unknown stock never partially restore', () {
    for (final products in <List<CatalogProduct>>[
      [],
      [
        product({'priceCents': 1200}),
      ],
      [
        product({'revision': 2}),
      ],
      [
        product({'available': 1}),
      ],
      [
        product({'inventoryKnown': false, 'available': 0, 'soldOut': true}),
      ],
    ]) {
      expect(
        () => draft().restore(
          identity: o.identity,
          context: m.parse(m.contextData()),
          products: products,
          now: a.now,
        ),
        o.fails('CART_DRAFT_CATALOG_CHANGED'),
      );
    }
  });

  test(
    'scope, session, payment timing, permissions and expiry reject restore',
    () {
      final value = draft();
      for (final field in <String, Object>{
        'employeeRef': 'E00000000002',
        'deviceId': '00000000-0000-4000-8000-000000000099',
        'base': 'https://other.invalid',
        'storeRef': 'other-store',
        'tableRef': 'other-table',
        'sessionRef': 'H00000000099',
        'memberRef': 'other-member',
        'paymentTiming': 'prepay',
      }.entries) {
        final changed = CartDraft.decode({
          ...copy(value),
          field.key: field.value,
        });
        expect(
          () => changed.restore(
            identity: o.identity,
            context: m.parse(m.contextData()),
            products: [product()],
            now: a.now,
          ),
          o.fails('CART_DRAFT_CONTEXT_CHANGED'),
        );
      }
      for (final identity in [a.session(), o.identity]) {
        expect(
          () => value.restore(
            identity: identity,
            context: m.parse(m.contextData()),
            products: [product()],
            now: identity == o.identity
                ? a.now.add(const Duration(hours: 1))
                : a.now,
          ),
          o.fails('CART_DRAFT_CONTEXT_CHANGED'),
        );
      }
      expect(
        () => value.restore(
          identity: o.identity,
          context: m.parse(m.contextData()),
          products: [product(), product()],
          now: a.now,
        ),
        o.fails('CART_DRAFT_CONTEXT_CHANGED'),
      );
    },
  );

  test(
    'strict bounded schema rejects malformed or secret-bearing draft data',
    () {
      final value = copy(draft());
      for (final raw in [
        {...value, 'apiKey': 'TEST_ONLY'},
        {...value, 'currency': 'USD'},
        {...value, 'base': 'http://service.invalid'},
        {...value, 'savedAt': '2026-02-30T00:00:00.000Z'},
        {...value, 'editVersion': 'bad'},
        {...value, 'lines': []},
        {
          ...value,
          'lines': [value['lines'][0], value['lines'][0]],
        },
        for (final bad in [0, 1.5, 1001])
          {
            ...value,
            'lines': [
              {...value['lines'][0] as Map<String, dynamic>, 'quantity': bad},
            ],
          },
        {
          ...value,
          'lines': [
            {
              ...value['lines'][0] as Map<String, dynamic>,
              'priceCents': 100000000,
            },
          ],
        },
      ]) {
        expect(() => CartDraft.decode(raw), o.fails('CART_DRAFT_INVALID'));
      }
    },
  );

  test('encrypted-store abstraction survives reinstantiation and isolates employees', () async {
    final storage = Storage(), value = draft();
    final store = CartDraftStore(storage: storage);
    await store.save(value, o.identity, previous: null);
    expect(
      (await CartDraftStore(storage: storage).load(o.identity))
          .single
          .signature,
      value.signature,
    );
    final other = a.session({
      ...a.response(),
      'employee': {'employeeRef': 'E00000000002', 'displayName': 'TEST ONLY'},
    });
    expect(await store.load(other), isEmpty);
    await expectLater(
      store.remove(value, other),
      o.fails('CART_DRAFT_CONTEXT_CHANGED'),
    );
    expect(storage.data.keys, [CartDraftStore.storageKey]);
  });

  test('compare-and-swap prevents stale writes and removal; old session remains separate', () async {
    final store = CartDraftStore(storage: Storage());
    final first = draft(), next = draft();
    await store.save(first, o.identity, previous: null);
    await expectLater(
      store.save(next, o.identity, previous: null),
      o.fails('CART_DRAFT_EDIT_CONFLICT'),
    );
    await store.save(next, o.identity, previous: first);
    await expectLater(
      store.remove(first, o.identity),
      o.fails('CART_DRAFT_EDIT_CONFLICT'),
    );
    final nextSession = CartDraft.decode({
      ...copy(first),
      'sessionRef': 'H00000000099',
    });
    await store.save(nextSession, o.identity, previous: null);
    await store.remove(next, o.identity);
    await store.remove(next, o.identity);
    expect(
      (await store.load(o.identity)).single.signature,
      nextSession.signature,
    );
  });

  test(
    'two store instances serialize competing edits without last-writer loss',
    () async {
      final storage = Storage();
      final first = CartDraftStore(storage: storage),
          second = CartDraftStore(storage: storage);
      final value = draft();
      await first.save(value, o.identity, previous: null);
      final results = await Future.wait([
        first
            .save(draft(), o.identity, previous: value)
            .then((_) => true, onError: (_) => false),
        second
            .save(draft(), o.identity, previous: value)
            .then((_) => true, onError: (_) => false),
      ]);
      expect(results.where((e) => e).length, 1);
      expect((await first.load(o.identity)).length, 1);
    },
  );

  test('corrupt envelope refuses overwrite and is not purged', () async {
    final storage = Storage(), value = draft();
    final store = CartDraftStore(storage: storage);
    for (final raw in [
      '{',
      jsonEncode({'version': 2, 'entries': []}),
      jsonEncode({
        'version': 1,
        'entries': [value.encode(), value.encode()],
      }),
    ]) {
      storage.data[CartDraftStore.storageKey] = raw;
      await expectLater(
        store.save(value, o.identity, previous: null),
        o.fails('CART_DRAFT_STORAGE_UNAVAILABLE'),
      );
      expect(storage.data[CartDraftStore.storageKey], raw);
    }
  });

  test(
    'failed readback or ambiguous write never claims saved; reload is explicit',
    () async {
      final storage = Storage()..drop = true;
      final store = CartDraftStore(storage: storage), value = draft();
      await expectLater(
        store.save(value, o.identity, previous: null),
        o.fails('CART_DRAFT_STORAGE_UNAVAILABLE'),
      );
      expect(await store.load(o.identity), isEmpty);
      storage
        ..drop = false
        ..uncertain = true;
      await expectLater(
        store.save(value, o.identity, previous: null),
        o.fails('CART_DRAFT_STORAGE_UNAVAILABLE'),
      );
      expect((await store.load(o.identity)).single.signature, value.signature);
    },
  );
}
