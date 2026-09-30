import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/cart_draft.dart';
import 'package:kingclub_cash_register/src/live/live_cart_drafts_panel.dart';
import 'package:kingclub_cash_register/src/live/live_tables_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'cart_draft_ui_test.dart' as d;
import 'live_cart_panel_test.dart' as ui;
import 'order_command_test.dart' as o;

class DraftAuth extends d.DraftAuth {
  bool failDelete = false;
  @override
  Future<void> discardCartDraft(
    CartDraft draft, {
    required bool confirmed,
  }) async {
    if (failDelete) throw StateError('TEST_ONLY_PRIVATE');
    await super.discardCartDraft(draft, confirmed: confirmed);
  }
}

CartDraft oldDraft() => CartDraft.decode({
  ...d.seed().encode(),
  'sessionRef': 'H00000000099',
  'memberRef': 'left-member',
});
String deleteKey(CartDraft draft) =>
    'drafts-delete-${draft.encode()['editVersion']}';

Future<void> show(
  WidgetTester tester,
  DraftAuth auth, {
  UiLanguage language = UiLanguage.zh,
  int revision = 0,
  bool workbench = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: workbench
            ? LiveTablesPanel(
                auth: auth,
                language: language,
                enableRealtime: false,
              )
            : LiveCartDraftsPanel(
                auth: auth,
                language: language,
                revision: revision,
                onBack: () {},
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
  void size(WidgetTester tester) {
    tester.view.physicalSize = const Size(1024, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'old-session and departed-member draft is reachable from workbench',
    (tester) async {
      size(tester);
      final auth = DraftAuth()..drafts = [oldDraft()];
      await show(tester, auth, workbench: true);
      await tester.tap(find.byKey(const ValueKey('table-tools')));
      await tester.pumpAndSettle();
      await ui.tap(tester, 'cart-drafts-open');
      expect(find.textContaining('H00000000099'), findsOneWidget);
      expect(find.text('left-member'), findsOneWidget);
      expect(auth.restores, 0);
      expect(auth.submits, 0);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets('old draft deletion needs confirmation and rereads actual list', (
    tester,
  ) async {
    size(tester);
    final draft = oldDraft(), auth = DraftAuth();
    auth.drafts = [draft];
    await show(tester, auth);
    await ui.tap(tester, deleteKey(draft));
    await tester.tap(find.text(tr(UiLanguage.zh, 'cancel')));
    await tester.pumpAndSettle();
    expect(auth.discards, 0);
    await ui.tap(tester, deleteKey(draft));
    await ui.tap(tester, 'drafts-delete-confirm');
    expect(auth.discards, 1);
    expect(find.text(tr(UiLanguage.zh, 'cartDraftsEmpty')), findsOneWidget);
    expect(auth.submits, 0);
    await tester.pumpWidget(const SizedBox());
    auth.dispose();
  });

  testWidgets(
    'pending order blocks deletion even for older session on same table',
    (tester) async {
      size(tester);
      final draft = oldDraft(), auth = DraftAuth();
      auth
        ..drafts = [draft]
        ..pending = [o.command()];
      await show(tester, auth);
      expect(
        tester
            .widget<TextButton>(find.byKey(ValueKey(deleteKey(draft))))
            .onPressed,
        isNull,
      );
      expect(find.text(tr(UiLanguage.zh, 'cartPending')), findsOneWidget);
      expect(auth.discards, 0);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets(
    'read and delete failures do not claim empty or drop saved records',
    (tester) async {
      size(tester);
      final draft = oldDraft(), auth = DraftAuth();
      auth
        ..drafts = [draft]
        ..failRead = true;
      await show(tester, auth);
      expect(find.text(tr(UiLanguage.zh, 'cartDraftsEmpty')), findsNothing);
      auth
        ..failRead = false
        ..failDelete = true;
      await ui.tap(tester, 'drafts-refresh');
      await ui.tap(tester, deleteKey(draft));
      await ui.tap(tester, 'drafts-delete-confirm');
      expect(find.text(tr(UiLanguage.zh, 'cartDraftFailed')), findsOneWidget);
      expect(auth.drafts, hasLength(1));
      expect(find.textContaining('TEST_ONLY_PRIVATE'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets(
    'realtime revision closes old confirmation and refreshes local list',
    (tester) async {
      size(tester);
      final draft = oldDraft(), auth = DraftAuth();
      auth.drafts = [draft];
      await show(tester, auth);
      await ui.tap(tester, deleteKey(draft));
      await show(tester, auth, revision: 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(auth.discards, 0);
      expect(auth.drafts, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  for (final language in UiLanguage.values) {
    testWidgets('local drafts and confirmation fit ${language.name}', (
      tester,
    ) async {
      size(tester);
      final draft = oldDraft(), auth = DraftAuth();
      auth.drafts = [draft];
      await show(tester, auth, language: language);
      await ui.tap(tester, deleteKey(draft));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text(tr(language, 'cancel')));
      await tester.pumpAndSettle();
      expect(auth.discards, 0);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    });
  }
}
