import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/cart_draft.dart';
import 'package:kingclub_cash_register/src/live/order_command.dart';
import 'package:kingclub_cash_register/src/live/order_context_snapshot.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_cart_panel_test.dart' as ui;
import 'order_context_test.dart' as m;
import 'order_command_test.dart' as o;
import 'staff_session_test.dart' as a;

// Explicit UI doubles. Production controller and storage sequencing have separate tests.
class DraftAuth extends ui.CartAuth {
  List<CartDraft> drafts = [];
  bool failSave = false, failRestore = false, failRead = false;
  int saves = 0, restores = 0, discards = 0;
  CartDraft? sentDraft;
  Completer<RestoredCart>? restoreGate;
  @override
  Future<List<CartDraft>> cartDrafts() async {
    if (failRead) throw StateError('TEST_ONLY_PRIVATE_FAILURE');
    return drafts;
  }

  @override
  Future<CartDraft> saveCartDraft({
    required OrderContextSnapshot context,
    required String memberRef,
    required List<OrderSelection> items,
    required CartDraft? previous,
  }) async {
    saves++;
    if (failSave) throw StateError('TEST_ONLY_PRIVATE_FAILURE');
    final draft = CartDraft.capture(
      identity: session,
      context: context,
      memberRef: memberRef,
      items: items,
      now: a.now,
    );
    drafts = [draft];
    return draft;
  }

  @override
  Future<RestoredCart> restoreCartDraft(CartDraft draft) async {
    restores++;
    if (failRestore) throw StateError('TEST_ONLY_PRIVATE_FAILURE');
    if (restoreGate != null) return restoreGate!.future;
    final context = m.parse(m.contextData());
    return RestoredCart(
      draft,
      context,
      draft.restore(
        identity: session,
        context: context,
        products: (await readCatalog()).products,
        now: a.now,
      ),
    );
  }

  @override
  Future<void> discardCartDraft(
    CartDraft draft, {
    required bool confirmed,
  }) async {
    expect(confirmed, true);
    discards++;
    drafts = [];
  }

  @override
  Future<OrderRequestResult> submitOrder({
    required OrderContextSnapshot context,
    required String memberRef,
    required List<OrderSelection> items,
    required bool confirmed,
    CartDraft? cartDraft,
  }) {
    sentDraft = cartDraft;
    return super.submitOrder(
      context: context,
      memberRef: memberRef,
      items: items,
      confirmed: confirmed,
      cartDraft: cartDraft,
    );
  }
}

CartDraft seed() => CartDraft.capture(
  identity: o.identity,
  context: m.parse(m.contextData()),
  memberRef: 'member-000',
  items: o.selection(),
  now: a.now,
);

void main() {
  setUp(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
  testWidgets(
    'unreadable saved state blocks new order without deleting records',
    (tester) async {
      final auth = DraftAuth()
        ..drafts = [seed()]
        ..failRead = true;
      await ui.show(tester, auth);
      expect(ui.enabled(tester), false);
      expect(auth.drafts, hasLength(1));
      expect(
        find.text(tr(UiLanguage.zh, 'orderRecoveryFailed')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets(
    'failed refresh of restored draft removes stale editable selection',
    (tester) async {
      final auth = DraftAuth()..drafts = [seed()];
      await ui.show(tester, auth);
      await ui.tap(tester, 'cart-draft-restore');
      expect(ui.enabled(tester), true);
      auth.failRestore = true;
      await ui.tap(tester, 'cart-draft-restore');
      expect(ui.enabled(tester), false);
      expect(find.text('CNY 24.68'), findsNothing);
      expect(auth.drafts, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  testWidgets(
    'explicit save survives page reconstruction and restore still needs order confirmation',
    (tester) async {
      final auth = DraftAuth();
      await ui.show(tester, auth);
      await ui.tap(tester, 'catalog-add-p001');
      await ui.tap(tester, 'cart-draft-save');
      expect(auth.saves, 1);
      expect(auth.submits, 0);
      final original = auth.drafts.single;
      await tester.pumpWidget(const SizedBox());
      await ui.show(tester, auth);
      expect(ui.enabled(tester), false);
      expect(find.text(tr(UiLanguage.zh, 'cartDraftFound')), findsOneWidget);
      await ui.tap(tester, 'cart-draft-restore');
      expect(auth.restores, 1);
      expect(ui.enabled(tester), true);
      expect(auth.submits, 0);
      await ui.tap(tester, 'cart-submit');
      expect(auth.submits, 0);
      await ui.tap(tester, 'cart-confirm');
      expect(auth.sentDraft!.signature, original.signature);
      expect(auth.submits, 1);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets(
    'editing restored draft requires explicit resave before submission',
    (tester) async {
      final auth = DraftAuth()..drafts = [seed()];
      await ui.show(tester, auth);
      await ui.tap(tester, 'cart-draft-restore');
      await ui.tap(tester, 'cart-plus-p001');
      expect(ui.enabled(tester), false);
      expect(find.text(tr(UiLanguage.zh, 'cartDraftResave')), findsOneWidget);
      await ui.tap(tester, 'cart-draft-save');
      expect(ui.enabled(tester), true);
      expect(auth.drafts.single.lines.single['quantity'], 3);
      expect(auth.submits, 0);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets(
    'discard cancellation preserves draft; confirmation clears only local selection',
    (tester) async {
      final auth = DraftAuth()..drafts = [seed()];
      await ui.show(tester, auth);
      await ui.tap(tester, 'cart-draft-discard');
      await tester.tap(find.text(tr(UiLanguage.zh, 'cancel')));
      await tester.pumpAndSettle();
      expect(auth.discards, 0);
      await ui.tap(tester, 'cart-draft-discard');
      await ui.tap(tester, 'cart-draft-discard-confirm');
      expect(auth.discards, 1);
      expect(auth.submits, 0);
      await ui.tap(tester, 'catalog-add-p001');
      expect(ui.enabled(tester), true);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets('save failure blocks submit without claiming persistence', (
    tester,
  ) async {
    final auth = DraftAuth()..failSave = true;
    await ui.show(tester, auth);
    await ui.tap(tester, 'catalog-add-p001');
    await ui.tap(tester, 'cart-draft-save');
    expect(ui.enabled(tester), false);
    expect(find.text(tr(UiLanguage.zh, 'cartDraftFailed')), findsOneWidget);
    expect(find.textContaining('TEST_ONLY_PRIVATE_FAILURE'), findsNothing);
    expect(auth.submits, 0);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets('restore failure retains original and does not enable order', (
    tester,
  ) async {
    final auth = DraftAuth()
      ..drafts = [seed()]
      ..failRestore = true;
    await ui.show(tester, auth);
    await ui.tap(tester, 'cart-draft-restore');
    expect(ui.enabled(tester), false);
    expect(auth.drafts, hasLength(1));
    expect(auth.submits, 0);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets(
    'identity invalidation closes delete dialog without deleting persisted draft',
    (tester) async {
      final auth = DraftAuth()..drafts = [seed()];
      await ui.show(tester, auth);
      await ui.tap(tester, 'cart-draft-discard');
      auth.invalidate();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(auth.discards, 0);
      expect(auth.drafts, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets('late restored data after backgrounding cannot repopulate cart', (
    tester,
  ) async {
    final auth = DraftAuth()
      ..drafts = [seed()]
      ..restoreGate = Completer<RestoredCart>();
    await ui.show(tester, auth);
    await tester.tap(find.byKey(const ValueKey('cart-draft-restore')));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    auth.restoreGate!.complete(
      RestoredCart(auth.drafts.single, m.parse(m.contextData()), o.selection()),
    );
    await tester.pumpAndSettle();
    expect(ui.enabled(tester), false);
    expect(find.text(tr(UiLanguage.zh, 'cartDraftRestored')), findsNothing);
    expect(auth.drafts, hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  for (final language in UiLanguage.values) {
    testWidgets('saved draft controls fit ${language.name}', (tester) async {
      final auth = DraftAuth()..drafts = [seed()];
      await ui.show(tester, auth, language: language);
      expect(tester.takeException(), isNull);
      await ui.tap(tester, 'cart-draft-restore');
      expect(tester.takeException(), isNull);
      await ui.tap(tester, 'cart-plus-p001');
      expect(tester.takeException(), isNull);
      expect(find.text('CNY 37.02'), findsOneWidget);
      expect(ui.enabled(tester), false);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    });
  }
}
