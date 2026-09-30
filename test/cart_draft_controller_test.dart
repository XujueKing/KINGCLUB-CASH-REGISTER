import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/cart_draft.dart';
import 'package:kingclub_cash_register/src/live/cart_draft_store.dart';
import 'package:kingclub_cash_register/src/live/order_command.dart';
import 'package:kingclub_cash_register/src/live/order_journal.dart';

import 'staff_session_test.dart' as a;
import 'order_command_test.dart' as o;
import 'order_context_test.dart' as m;
import 'catalog_snapshot_test.dart' as c;

class Storage extends o.Storage {
  bool blockRemoval = false;
  @override
  Future<void> write(String key, String value) async {
    if (blockRemoval &&
        key == CartDraftStore.storageKey &&
        (jsonDecode(value)['entries'] as List).isEmpty) {
      return;
    }
    await super.write(key, value);
  }
}

class Api extends o.Api {
  final reads = <String>[];
  bool changedPrice = false, memberLeft = false;
  void Function()? afterRead;
  void Function()? beforeSubmit;
  bool paginated = false;
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    if (id == 'K260929001911' || id == 'K260929001910') {
      reads.add(id);
      afterRead?.call();
      if (paginated) {
        final memberPage = params['afterMember'] != null;
        final productPage = params['afterProduct'] != null;
        return {
          'result': id == 'K260929001911'
              ? {
                  ...m.contextData(
                    members: memberPage
                        ? [m.member(60)]
                        : List.generate(50, m.member),
                  ),
                  'nextAfterMember': memberPage ? null : 'member-049',
                }
              : {
                  ...c.catalog(),
                  'products':
                      (productPage
                              ? ['p060']
                              : List.generate(
                                  50,
                                  (i) => 'p${i.toString().padLeft(3, '0')}',
                                ))
                          .map(
                            (ref) => {
                              ...c.product(ref),
                              'inventoryKnown': true,
                              'available': 10,
                              'soldOut': false,
                            },
                          )
                          .toList(),
                  'nextAfterProduct': productPage ? null : 'p049',
                },
        };
      }
      return {
        'result': id == 'K260929001911'
            ? m.contextData(members: memberLeft ? [] : null)
            : {
                ...c.catalog(),
                'products': [
                  {
                    ...c.product(),
                    'priceCents': changedPrice ? 1235 : 1234,
                    'inventoryKnown': true,
                    'available': 10,
                    'soldOut': false,
                  },
                ],
              },
      };
    }
    if (id == 'K260929001912') beforeSubmit?.call();
    return super.call(id, params);
  }
}

Future<CartDraft> save(StaffAuthController auth, {CartDraft? previous}) =>
    auth.saveCartDraft(
      context: m.parse(m.contextData()),
      memberRef: 'member-000',
      items: o.selection(),
      previous: previous,
    );
Future<OrderRequestResult> submit(StaffAuthController auth, CartDraft? draft) =>
    auth.submitOrder(
      context: m.parse(m.contextData()),
      memberRef: 'member-000',
      items: o.selection(),
      confirmed: true,
      cartDraft: draft,
    );

void main() {
  test(
    'in-memory refresh rereads truth without saving or submitting a draft',
    () async {
      final storage = Storage(), api = Api();
      final auth = await o.controller(storage, api);
      final result = await auth.refreshCartSelection(
        context: m.parse(m.contextData()),
        memberRef: 'member-000',
        items: o.selection(),
      );
      expect(result.items.single.quantity, o.selection().single.quantity);
      expect(api.reads, ['K260929001911', 'K260929001910']);
      expect(api.calls, isEmpty);
      expect(await auth.cartDrafts(), isEmpty);
      expect(await auth.pendingOrders(), isEmpty);
      api.changedPrice = true;
      await expectLater(
        auth.refreshCartSelection(
          context: m.parse(m.contextData()),
          memberRef: 'member-000',
          items: o.selection(),
        ),
        throwsA(anything),
      );
      api.changedPrice = false;
      api.memberLeft = true;
      await expectLater(
        auth.refreshCartSelection(
          context: m.parse(m.contextData()),
          memberRef: 'member-000',
          items: o.selection(),
        ),
        throwsA(anything),
      );
      expect(api.calls, isEmpty);
      auth.dispose();
    },
  );
  test('explicitly discards an old-session departed-member draft without server mutation', () async {
    final storage = Storage(), api = Api();
    final auth = await o.controller(storage, api);
    final current = await save(auth);
    final old = CartDraft.decode({
      ...current.encode(),
      'sessionRef': 'H00000000099',
      'memberRef': 'left-member',
    });
    await CartDraftStore(storage: storage)
        .save(old, o.identity, previous: null);
    await auth.discardCartDraft(old, confirmed: true);
    expect((await auth.cartDrafts()).single.signature, current.signature);
    expect(api.calls, isEmpty);
    expect(api.reads, isEmpty);
    auth.dispose();
  });
  test('restoration follows both member and catalogue cursors', () async {
    final storage = Storage(), api = Api()..paginated = true;
    final auth = await o.controller(storage, api);
    final seed = CartDraft.capture(
      identity: o.identity,
      context: m.parse(m.contextData()),
      memberRef: 'member-000',
      items: o.selection(),
      now: a.now,
    );
    final draft = CartDraft.decode({
      ...seed.encode(),
      'memberRef': 'member-060',
      'lines': [
        {...seed.lines.single, 'productRef': 'p060'},
      ],
    });
    await CartDraftStore(storage: storage)
        .save(draft, o.identity, previous: null);
    final result = await auth.restoreCartDraft(draft);
    expect(result.items.single.product.reference, 'p060');
    expect(result.context.members.single.reference, 'member-060');
    expect(api.reads, [
      'K260929001911',
      'K260929001911',
      'K260929001910',
      'K260929001910',
    ]);
    expect(api.calls, isEmpty);
    auth.dispose();
  });

  test('linked draft must match immutable command lines and remains local metadata', () async {
    final storage = Storage(), api = Api();
    final auth = await o.controller(storage, api);
    final draft = await save(auth);
    final bad = CartDraft.decode({
      ...draft.encode(),
      'lines': [
        {...draft.lines.single, 'quantity': 1},
      ],
    });
    await expectLater(submit(auth, bad), o.fails('ORDER_COMMAND_INVALID'));
    expect(await auth.pendingOrders(), isEmpty);
    expect(api.calls, isEmpty);
    auth.dispose();
  });

  test('discard needs confirmation and rejects stale version', () async {
    final storage = Storage(), api = Api();
    final auth = await o.controller(storage, api);
    final first = await save(auth),
        next = await save(
          auth,
          previous: await auth.cartDrafts().then((d) => d.single),
        );
    await expectLater(
      auth.discardCartDraft(next, confirmed: false),
      o.fails('ORDER_CONFIRMATION_REQUIRED'),
    );
    await expectLater(
      auth.discardCartDraft(first, confirmed: true),
      o.fails('CART_DRAFT_EDIT_CONFLICT'),
    );
    await auth.discardCartDraft(next, confirmed: true);
    expect(await auth.cartDrafts(), isEmpty);
    expect(api.calls, isEmpty);
    auth.dispose();
  });
  test('save is local; restore queries real controller paths and never creates an order', () async {
    final storage = Storage(), api = Api();
    final auth = await o.controller(storage, api);
    final draft = await save(auth);
    expect(api.calls, isEmpty);
    expect(api.reads, isEmpty);
    final restored = await auth.restoreCartDraft(draft);
    expect(restored.context.sessionRef, draft.sessionRef);
    expect(restored.items.single.quantity, 2);
    expect(api.reads, ['K260929001911', 'K260929001910']);
    expect(api.calls, isEmpty);
    expect(await auth.pendingOrders(), isEmpty);
    expect((await auth.cartDrafts()).single.signature, draft.signature);
    auth.dispose();
  });

  test(
    'changed price or departed member blocks restoration and retains draft',
    () async {
      final storage = Storage(), api = Api();
      final auth = await o.controller(storage, api);
      final draft = await save(auth);
      api.changedPrice = true;
      await expectLater(
        auth.restoreCartDraft(draft),
        o.fails('CART_DRAFT_CATALOG_CHANGED'),
      );
      api.memberLeft = true;
      await expectLater(
        auth.restoreCartDraft(draft),
        o.fails('CART_DRAFT_CONTEXT_CHANGED'),
      );
      expect((await auth.cartDrafts()).single.signature, draft.signature);
      expect(api.calls, isEmpty);
      auth.dispose();
    },
  );

  test('expired or disposed session rejects late restoration', () async {
    final storage = Storage(), api = Api();
    var now = a.now;
    final auth = await o.controller(storage, api, now: () => now);
    final draft = await save(auth);
    api.afterRead = () => now = a.now.add(const Duration(hours: 1));
    await expectLater(
      auth.restoreCartDraft(draft),
      o.fails('SESSION_REQUIRED'),
    );
    now = a.now;
    api.afterRead = auth.dispose;
    await expectLater(auth.restoreCartDraft(draft), o.fails('SESSION_CHANGED'));
    expect(
      (await CartDraftStore(storage: storage).load(o.identity))
          .single
          .signature,
      draft.signature,
    );
  });

  test(
    'pending command blocks draft editing, discard and restoration',
    () async {
      final storage = Storage(), api = Api();
      final auth = await o.controller(storage, api);
      final draft = await save(auth);
      await OrderJournal(storage: storage).save(o.command(), o.identity);
      await expectLater(
        save(auth, previous: draft),
        o.fails('ORDER_ALREADY_PENDING'),
      );
      await expectLater(
        auth.discardCartDraft(draft, confirmed: true),
        o.fails('ORDER_ALREADY_PENDING'),
      );
      await expectLater(
        auth.restoreCartDraft(draft),
        o.fails('ORDER_ALREADY_PENDING'),
      );
      expect(api.reads, isEmpty);
      auth.dispose();
    },
  );

  test('successful handoff consumes exact draft and receipt acknowledges original command', () async {
    final storage = Storage(), api = Api();
    final auth = await o.controller(storage, api);
    final draft = await save(auth);
    api.beforeSubmit = () {
      final journal = jsonDecode(storage.data[OrderJournal.storageKey]!);
      expect(
        PendingOrder.decode(journal['entries'].single).cartDraft!.signature,
        draft.signature,
      );
      expect(
        jsonDecode(storage.data[CartDraftStore.storageKey]!)['entries'],
        isEmpty,
      );
    };
    final result = await submit(auth, draft);
    expect(result.state, OrderRequestState.confirmed);
    expect(await auth.cartDrafts(), isEmpty);
    expect(await auth.pendingOrders(), isEmpty);
    expect(api.calls.single.$1, 'K260929001912');
    expect(api.calls.single.$2.containsKey('cartDraft'), false);
    await expectLater(submit(auth, draft), o.fails('CART_DRAFT_EDIT_CONFLICT'));
    expect(api.calls.length, 1);
    auth.dispose();
  });

  test('recovery never removes a newer unrelated edit or acknowledges its original', () async {
    final storage = Storage(), api = Api();
    final auth = await o.controller(storage, api);
    final first = await save(auth);
    storage.blockRemoval = true;
    await expectLater(
      submit(auth, first),
      o.fails('CART_DRAFT_STORAGE_UNAVAILABLE'),
    );
    final command = (await auth.pendingOrders()).single;
    storage.blockRemoval = false;
    // Deliberate storage conflict fixture: normal controller saves are blocked while pending.
    final newer = CartDraft.capture(
      identity: o.identity,
      context: m.parse(m.contextData()),
      memberRef: 'member-000',
      items: o.selection(),
      now: a.now,
    );
    await CartDraftStore(storage: storage)
        .save(newer, o.identity, previous: first);
    await expectLater(
      auth.recoverOrder(command.requestId, retryOriginal: true),
      o.fails('CART_DRAFT_EDIT_CONFLICT'),
    );
    expect(api.calls, isEmpty);
    expect((await auth.pendingOrders()).single.requestId, command.requestId);
    expect((await auth.cartDrafts()).single.signature, newer.signature);
    auth.dispose();
  });

  test(
    'unlinked or outdated draft cannot create a second new request',
    () async {
      final storage = Storage(), api = Api();
      final auth = await o.controller(storage, api);
      final first = await save(auth);
      await expectLater(
        save(auth, previous: null),
        o.fails('CART_DRAFT_EDIT_CONFLICT'),
      );
      await expectLater(
        submit(auth, null),
        o.fails('CART_DRAFT_EDIT_CONFLICT'),
      );
      final updated = await save(auth, previous: first);
      await expectLater(
        submit(auth, first),
        o.fails('CART_DRAFT_EDIT_CONFLICT'),
      );
      expect((await auth.cartDrafts()).single.signature, updated.signature);
      expect(await auth.pendingOrders(), isEmpty);
      expect(api.calls, isEmpty);
      auth.dispose();
    },
  );

  test(
    'failed journal persistence leaves draft intact and sends nothing',
    () async {
      final storage = Storage(), api = Api();
      final auth = await o.controller(storage, api);
      final draft = await save(auth);
      storage.drop = true;
      await expectLater(
        submit(auth, draft),
        o.fails('ORDER_JOURNAL_UNAVAILABLE'),
      );
      expect((await auth.cartDrafts()).single.signature, draft.signature);
      expect(api.calls, isEmpty);
      auth.dispose();
    },
  );

  test('failed draft removal retains recoverable original and sends nothing; restart uses same ID', () async {
    final storage = Storage(), api = Api();
    var auth = await o.controller(storage, api);
    final draft = await save(auth);
    storage.blockRemoval = true;
    await expectLater(
      submit(auth, draft),
      o.fails('CART_DRAFT_STORAGE_UNAVAILABLE'),
    );
    final command = (await auth.pendingOrders()).single;
    expect(command.cartDraft!.signature, draft.signature);
    expect(api.calls, isEmpty);
    auth.dispose();
    storage.blockRemoval = false;
    final restartedApi = Api();
    auth = await o.controller(storage, restartedApi);
    await auth.recoverOrder(command.requestId, retryOriginal: true);
    expect(restartedApi.calls.map((c) => c.$1), [
      'K260929001913',
      'K260929001912',
    ]);
    expect(restartedApi.calls.last.$2['requestId'], command.requestId);
    expect(await auth.cartDrafts(), isEmpty);
    expect(await auth.pendingOrders(), isEmpty);
    auth.dispose();
  });

  test(
    'uncertain delivery has no reusable draft; recovery keeps original request',
    () async {
      final storage = Storage(), api = Api()..failSubmit = true;
      final auth = await o.controller(storage, api);
      final draft = await save(auth);
      await expectLater(submit(auth, draft), o.fails('TRANSPORT_FAILED'));
      expect(await auth.cartDrafts(), isEmpty);
      final pending = (await auth.pendingOrders()).single;
      expect(pending.cartDraft!.signature, draft.signature);
      await auth.recoverOrder(pending.requestId);
      expect((await auth.pendingOrders()).single.requestId, pending.requestId);
      expect(api.calls.length, 2);
      auth.dispose();
    },
  );
}
