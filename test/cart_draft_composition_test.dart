import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/cart_draft_store.dart';
import 'package:kingclub_cash_register/src/live/live_cart_panel.dart';
import 'package:kingclub_cash_register/src/live/order_journal.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'cart_draft_controller_test.dart' as d;
import 'live_cart_panel_test.dart' as ui;
import 'order_command_test.dart' as o;
import 'order_context_test.dart' as m;

Future<void> show(WidgetTester tester, StaffAuthController auth) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LiveCartPanel(
          auth: auth,
          language: UiLanguage.zh,
          orderContext: m.parse(m.contextData()),
          memberRef: 'member-000',
          onBack: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // Only transport and encrypted-storage adapters are test doubles. The widget,
  // controller, scope checks, parsers, draft store and command journal are real.
  // Keep static serialized storage futures in one Flutter fake-async zone.
  // Each scenario still uses a new storage adapter and new controllers.
  testWidgets(
    'UI and controller preserve original handoff for confirmed and uncertain delivery',
    (tester) async {
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
      tester.view.physicalSize = const Size(1024, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final uncertain in [false, true]) {
        final storage = d.Storage();
        var auth = await o.controller(storage, d.Api());
        await show(tester, auth);
        await ui.tap(tester, 'catalog-add-p001');
        await ui.tap(tester, 'cart-draft-save');
        final draft = (await auth.cartDrafts()).single;
        expect(await auth.pendingOrders(), isEmpty);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
        final api = d.Api()..failSubmit = uncertain;
        auth = await o.controller(storage, api);
        await show(tester, auth);
        expect(ui.enabled(tester), false);
        await ui.tap(tester, 'cart-draft-restore');
        expect(ui.enabled(tester), true);
        expect(api.calls, isEmpty);
        api.beforeSubmit = () {
          expect(
            jsonDecode(storage.data[CartDraftStore.storageKey]!)['entries'],
            isEmpty,
          );
          final journal = jsonDecode(storage.data[OrderJournal.storageKey]!);
          expect(journal['entries'].single['cartDraft'], draft.encode());
        };
        await ui.tap(tester, 'cart-submit');
        expect(api.calls.single.$1, 'K260929001912');
        expect(await auth.cartDrafts(), isEmpty);
        expect(ui.enabled(tester), false);
        if (uncertain) {
          final pending = (await auth.pendingOrders()).single;
          expect(pending.requestId, api.calls.single.$2['requestId']);
          expect(pending.cartDraft!.signature, draft.signature);
          expect(
            find.text(tr(UiLanguage.zh, 'orderRecoveryUnconfirmed')),
            findsOneWidget,
          );
        } else {
          expect(await auth.pendingOrders(), isEmpty);
          expect(
            find.text(tr(UiLanguage.zh, 'orderRecoveryConfirmed')),
            findsNothing,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
      }
    },
  );
}
