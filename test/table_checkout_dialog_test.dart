import 'support/lifecycle.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_command.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_cancellation.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_dialog.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_result.dart';
import 'package:kingclub_cash_register/src/live/table_receipt_dialog.dart';
import 'package:kingclub_cash_register/src/live/receipt_document.dart';
import 'package:kingclub_cash_register/src/strings.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as staff;
import 'table_checkout_command_test.dart' as fixture;
import 'table_checkout_admission_test.dart' as admission;
import 'table_checkout_result_test.dart' as settlement;
import 'table_checkout_cancellation_test.dart' show cancellationFixture;

class CheckoutDialogAuth extends StaffAuthController {
  CheckoutDialogAuth({List<String> permissions = const ['workbench.read', 'payment.balance']}) {
    final now = DateTime.now();
    identity = StaffSession.fromServer(
      {
        ...staff.response(),
        'permissions': permissions,
        'expiresAtMs': now
            .add(const Duration(minutes: 10))
            .millisecondsSinceEpoch,
        'refreshExpiresAtMs': now
            .add(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      },
      base: 'https://service.invalid/prefix',
      deviceId: staff.device,
      expectedStore: 'test-store',
      now: now,
    );
  }
  late StaffSession identity;
  TableCheckoutCommand? saved;
  int preparations = 0, collections = 0, recoveries = 0;
  bool losePreparationResponse = false;
  int cancellations = 0;
  int cancellationQueries = 0;
  String? requestedReceipt;
  @override
  Future<TableReceiptDocument> readTableReceiptDocument(String checkoutRef) async {
    requestedReceipt = checkoutRef;
    throw const CcsopFailure('TEST_RECEIPT_UNAVAILABLE');
  }
  String admissionStatus = 'prepared';
  bool cancellationConfirmed = true;
  bool quoteUnavailable = false;
  String? quoteError;
  int quoteReads = 0;
  void sessionRefreshed() => notifyListeners();
  Completer<void>? cancellationWait;
  Future<TableCheckoutCancellation> cancellationResult(
    TableCheckoutCommand command,
  ) async {
    await cancellationWait?.future;
    if (cancellationConfirmed) saved = null;
    return TableCheckoutCancellation.parse(
      cancellationConfirmed
          ? cancellationFixture(command)
          : {
              'result': {
                'state': 'not_cancelled',
                'checkoutRef': settlement.checkout,
              },
            },
      command,
      checkoutRef: settlement.checkout,
    );
  }

  @override
  Future<TableCheckoutCancellation> lookupTableCancellation(
    TableCheckoutCommand command, {
    required bool Function() stillCurrent,
  }) async {
    expect(stillCurrent(), true);
    cancellationQueries++;
    return cancellationResult(command);
  }

  @override
  Future<TableCheckoutCancellation> cancelTableCheckout(
    TableCheckoutCommand command, {
    required bool confirmed,
    required bool Function() stillCurrent,
  }) async {
    expect(confirmed, true);
    expect(stillCurrent(), true);
    cancellations++;
    return cancellationResult(command);
  }

  @override
  StaffSession get session => identity;
  @override
  Future<List<TableCheckoutCommand>> pendingTableCheckouts(
    String channel,
  ) async => saved != null && saved!.channel == channel ? [saved!] : [];
  @override
  Future<TableCheckoutQuote> quoteTableCheckout({
    required String tableRef,
    required String sessionRef,
    required String channel,
    required String? accountType,
  }) async {
    quoteReads++;
    if (quoteError != null) throw CcsopFailure(quoteError!);
    if (quoteUnavailable) {
      throw const CcsopFailure('CASHIER_TABLE_CHECKOUT_NOT_ENABLED');
    }
    final raw = fixture.tableQuoteFixture();
    raw['result'] = <String, dynamic>{...raw['result'], 'accountType': accountType, 'channel': channel};
    return TableCheckoutQuote.parse(
      raw,
      storeRef: 'test-store',
      tableRef: tableRef,
      sessionRef: sessionRef,
      channel: channel,
      accountType: accountType,
    );
  }

  @override
  Future<TableCheckoutAdmission> prepareTableCheckout(
    TableCheckoutCommand command, {
    required bool confirmed,
    bool Function()? stillCurrent,
  }) async {
    expect(confirmed, true);
    expect(stillCurrent!(), true);
    saved = command;
    preparations++;
    if (losePreparationResponse) throw const CcsopFailure('TRANSPORT_FAILED');
    return TableCheckoutAdmission.parse(
      admission.admissionFixture(command),
      command,
    );
  }

  @override
  Future<TableCheckoutAdmission> lookupTableCheckout(
    TableCheckoutCommand command,
  ) async => TableCheckoutAdmission.parse({
    'result': <String, dynamic>{
      ...admission.admissionFixture(command)['result'],
      'paymentStatus': admissionStatus,
    },
  }, command);
  @override
  Future<TableCheckoutResult> recoverTableCheckout(
    TableCheckoutCommand command, {
    required bool Function() stillCurrent,
  }) async {
    recoveries++;
    expect(stillCurrent(), true);
    return TableCheckoutResult.parse(
      settlement.settlementFixture(command),
      command,
      checkoutRef: settlement.checkout,
    );
  }

  @override
  Future<TableCheckoutResult> collectTableCheckout(
    TableCheckoutCommand command, {
    required bool confirmed,
    required bool Function() stillCurrent,
    String? payerCode,
    int? cashReceivedCents,
  }) async {
    collections++;
    throw StateError('Unexpected automatic collection');
  }
}

class ExplicitCloseAuth extends CheckoutDialogAuth {
  ExplicitCloseAuth():super(permissions:['workbench.read','payment.alipay']) {
    saved=TableCheckoutCommand.decode({...fixture.command().encoded,'channel':'alipay','accountType':null});
    admissionStatus='pending';
  }
  int closes=0;
  @override Future<TableCheckoutResult> recoverTableCheckout(TableCheckoutCommand command,{required bool Function() stillCurrent}) async =>
    TableCheckoutResult.parse({'result':{'state':'pending','checkoutRef':settlement.checkout,'canCloseUnpaid':closes==0}},command,checkoutRef:settlement.checkout);
  @override Future<TableCheckoutResult> closeTableProvider(TableCheckoutCommand command,{required bool Function() stillCurrent}) async {
    expect(stillCurrent(),true);closes++;
    return TableCheckoutResult.parse({'result':{'state':'unknown','checkoutRef':settlement.checkout}},command,checkoutRef:settlement.checkout);
  }
}

void main() {
  Future<void> mount(WidgetTester tester, CheckoutDialogAuth auth) async {
    tester.view.physicalSize = const Size(1366, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: TableCheckoutDialog(
          auth: auth,
          tableRef: 'TEST_TABLE',
          sessionRef: 'TEST_SESSION',
          language: UiLanguage.zh,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lost preparation response queries the same request and restores scanning without collection', (tester) async {
    final auth = CheckoutDialogAuth()..losePreparationResponse = true;
    await mount(tester, auth);
    await tester.tap(find.text(tr(UiLanguage.zh, 'checkoutStart')));
    await tester.pumpAndSettle();
    expect(auth.preparations, 1);
    expect(auth.saved, isNotNull);
    expect(find.byType(TextField), findsOneWidget);
    expect(auth.collections, 0);
    expect(find.text(tr(UiLanguage.zh, 'tableCheckoutReview')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('session refresh reloads quote without leaving a blank checkout', (tester) async {
    final auth = CheckoutDialogAuth();
    await mount(tester, auth);
    expect(auth.quoteReads, 1);
    auth.sessionRefreshed();
    await tester.pumpAndSettle();
    expect(auth.quoteReads, 2);
    expect(find.text(tr(UiLanguage.zh, 'checkoutStart')), findsOneWidget);
    expect(auth.preparations, 0);
    expect(auth.collections, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('failed quote retries without creating a payment request', (tester) async {
    final auth = CheckoutDialogAuth()..quoteError = 'TRANSPORT_FAILED';
    await mount(tester, auth);
    expect(find.text(tr(UiLanguage.zh, 'tableCheckoutReview')), findsNothing);
    auth.quoteError = null;
    await tester.tap(find.text(tr(UiLanguage.zh, 'ordersRefresh')));
    await tester.pumpAndSettle();
    expect(auth.quoteReads, 2);
    expect(find.text(tr(UiLanguage.zh, 'checkoutStart')), findsOneWidget);
    expect(auth.preparations, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('ended table session closes the old checkout route', (tester) async {
    final auth = CheckoutDialogAuth()..quoteError = 'CASHIER_TABLE_CHECKOUT_SCOPE_CHANGED';
    tester.view.physicalSize = const Size(1366, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(auth.dispose);
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(
      onPressed: () => showDialog<void>(context: context, builder: (_) => TableCheckoutDialog(
        auth: auth, tableRef: 'TEST_TABLE', sessionRef: 'TEST_SESSION', language: UiLanguage.zh)),
      child: const Text('open'),
    ))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(TableCheckoutDialog), findsNothing);
    expect(find.text('open'), findsOneWidget);
    expect(auth.preparations, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cash touch keys enter yuan, normalize zero and replace exact amount', (tester) async {
    final auth = CheckoutDialogAuth(permissions: ['workbench.read', 'payment.cash']);
    await mount(tester, auth);
    await tester.tap(find.text(tr(UiLanguage.zh, 'checkoutStart')));
    await tester.pumpAndSettle();
    expect(auth.preparations, 1);
    expect(find.byKey(const ValueKey('cash-amount-input')), findsOneWidget);
    String amount() => tester.widget<TextField>(find.byKey(const ValueKey('cash-amount-input'))).controller!.text;
    Future<void> key(String digit) async {
      final button = find.widgetWithText(OutlinedButton, digit);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
    }
    await key('0'); await key('2'); await key('0');
    expect(amount(), '20');
    await key('.'); await key('5'); await key('6'); await key('7');
    expect(amount(), '20.56');
    await key('⌫'); await key('8');
    expect(amount(), '20.58');
    final exact = find.text(tr(UiLanguage.zh, 'checkoutExactCash'));
    await tester.ensureVisible(exact); await tester.tap(exact); await tester.pump();
    await key('5'); await key('0');
    expect(amount(), '50');
    expect(auth.collections, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('explicit whole-table close is one button and retains original uncertainty',(tester) async {
    final auth=ExplicitCloseAuth();await mount(tester,auth);
    await tester.tap(find.text(tr(UiLanguage.zh,'tableCheckoutQuery')));await tester.pumpAndSettle();
    await tester.tap(find.text(tr(UiLanguage.zh,'tableCheckoutRecover')));await tester.pumpAndSettle();
    final close=find.text(tr(UiLanguage.zh,'provider_close_attempt'));expect(close,findsOneWidget);
    await tester.ensureVisible(close);await tester.tap(close);await tester.pumpAndSettle();
    expect(auth.closes,1);expect(auth.collections,0);expect(auth.saved,isNotNull);expect(find.byType(AlertDialog),findsNothing);
    expect(close,findsNothing);await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('settled checkout opens its server receipt without collecting again', (tester) async {
    final auth = CheckoutDialogAuth(permissions: ['workbench.read', 'payment.balance', 'orders.read'])..saved = fixture.command();
    await mount(tester, auth);
    await tester.tap(find.text(tr(UiLanguage.zh, 'tableCheckoutQuery')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr(UiLanguage.zh, 'tableCheckoutRecover')));
    await tester.pumpAndSettle();
    final receipt = find.byKey(const ValueKey('checkout-settled-receipt'));
    await tester.ensureVisible(receipt);
    await tester.tap(receipt);
    await tester.pumpAndSettle();
    final dialog = tester.widget<TableReceiptDialog>(find.byType(TableReceiptDialog));
    expect(dialog.checkoutRef, settlement.checkout);
    expect(dialog.tableRef, 'TEST_TABLE');
    expect(dialog.sessionRef, 'TEST_SESSION');
    expect(auth.requestedReceipt, settlement.checkout);
    expect(auth.collections, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'server-disabled checkout has a clear message and no payment request',
    (tester) async {
      final auth = CheckoutDialogAuth()..quoteUnavailable = true;
      await mount(tester, auth);
      await tester.pumpAndSettle();
      expect(
        find.text(tr(UiLanguage.zh, 'tableCheckoutUnavailable')),
        findsOneWidget,
      );
      expect(auth.preparations, 0);
      expect(auth.collections, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('bill button prepares without a checkbox and never collects', (
    tester,
  ) async {
    final auth = CheckoutDialogAuth();
    await mount(tester, auth);
    await tester.pumpAndSettle();
    expect(auth.preparations, 0);
    expect(auth.collections, 0);
    final button = find.widgetWithText(
      FilledButton,
      tr(UiLanguage.zh, 'checkoutStart'),
    );
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    expect(find.byType(CheckboxListTile), findsNothing);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(auth.preparations, 1);
    expect(auth.collections, 0);
    expect(find.byType(TextField), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'cancellation has one confirmation, clears code and ends original controls',
    (tester) async {
      final auth = CheckoutDialogAuth()..saved = fixture.command();
      await mount(tester, auth);
      expect(auth.cancellations, 0);
      await tester.tap(find.text(tr(UiLanguage.zh, 'tableCheckoutQuery')));
      await tester.pumpAndSettle();
      final button = find.widgetWithText(
        OutlinedButton,
        tr(UiLanguage.zh, 'tableCheckoutCancel'),
      );
      expect(tester.widget<OutlinedButton>(button).onPressed, isNotNull);
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.enterText(find.byType(TextField), 'TEST_ONLY_CODE');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(auth.cancellations, 0);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('TEST_ONLY_CODE'),
        ),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('table-checkout-confirm-action')),
      );
      await tester.pumpAndSettle();
      expect(auth.cancellations, 1);
      expect(auth.collections, 0);
      expect(find.byType(TextField), findsNothing);
      expect(
        find.text(tr(UiLanguage.zh, 'tableCheckoutCancelled')),
        findsOneWidget,
      );
      expect(find.text(tr(UiLanguage.zh, 'tableCheckoutQuery')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('dismissed collection confirmation never sends payment', (
    tester,
  ) async {
    final auth = CheckoutDialogAuth()..saved = fixture.command();
    await mount(tester, auth);
    await tester.tap(find.text(tr(UiLanguage.zh, 'tableCheckoutQuery')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'TEST_ONLY_CODE');
    final button = find.widgetWithText(
      FilledButton,
      tr(UiLanguage.zh, 'tableCheckoutCollect'),
    );
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(auth.collections, 0);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(
      find.widgetWithText(TextButton, tr(UiLanguage.zh, 'cancel')),
    );
    await tester.pumpAndSettle();
    expect(auth.collections, 0);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'TEST_ONLY_CODE',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('backgrounding invalidates an open collection confirmation', (
    tester,
  ) async {
    final auth = CheckoutDialogAuth()..saved = fixture.command();
    await mount(tester, auth);
    await tester.tap(find.text(tr(UiLanguage.zh, 'tableCheckoutQuery')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'TEST_ONLY_CODE');
    final button = find.widgetWithText(
      FilledButton,
      tr(UiLanguage.zh, 'tableCheckoutCollect'),
    );
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await transitionLifecycle(tester, AppLifecycleState.paused);
    await transitionLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey('table-checkout-confirm-action')),
    );
    await tester.pumpAndSettle();
    expect(auth.collections, 0);
    await transitionLifecycle(tester, AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
  testWidgets(
    'one explicit payment confirmation sends once and retains uncertain original',
    (tester) async {
      final auth = CheckoutDialogAuth()..saved = fixture.command();
      await mount(tester, auth);
      await tester.tap(find.text(tr(UiLanguage.zh, 'tableCheckoutQuery')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'TEST_ONLY_CODE');
      final button = find.widgetWithText(
        FilledButton,
        tr(UiLanguage.zh, 'tableCheckoutCollect'),
      );
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(auth.collections, 0);
      await tester.tap(
        find.byKey(const ValueKey('table-checkout-confirm-action')),
      );
      await tester.pumpAndSettle();
      expect(auth.collections, 1);
      expect(auth.saved, isNotNull);
      expect(
        find.text(tr(UiLanguage.zh, 'tableCheckoutReview')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'saved original recovers without a code or automatic collection',
    (tester) async {
      final auth = CheckoutDialogAuth()..saved = fixture.command();
      await mount(tester, auth);
      expect(auth.collections, 0);
      expect(auth.recoveries, 0);
      await tester.tap(find.text(tr(UiLanguage.zh, 'tableCheckoutQuery')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr(UiLanguage.zh, 'tableCheckoutRecover')));
      await tester.pumpAndSettle();
      expect(auth.recoveries, 1);
      expect(auth.collections, 0);
      expect(
        find.text(tr(UiLanguage.zh, 'tableCheckout_settled')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'unconfirmed cancellation retains original and requires query before retry',
    (tester) async {
      final auth = CheckoutDialogAuth()
        ..saved = fixture.command()
        ..cancellationConfirmed = false;
      await mount(tester, auth);
      await tester.tap(
        find.text(tr(UiLanguage.zh, 'tableCheckoutCancelQuery')),
      );
      await tester.pumpAndSettle();
      expect(auth.saved, isNotNull);
      expect(auth.cancellationQueries, 1);
      expect(auth.cancellations, 0);
      expect(
        find.text(tr(UiLanguage.zh, 'tableCheckoutNotCancelled')),
        findsOneWidget,
      );
      expect(
        find.text(tr(UiLanguage.zh, 'tableCheckoutRetryPrepare')),
        findsNothing,
      );
      expect(find.byType(TextField), findsNothing);
      expect(auth.collections, 0);
      await tester.tap(find.text(tr(UiLanguage.zh, 'tableCheckoutQuery')));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(auth.collections, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('closed admission alone does not confirm cancellation', (
    tester,
  ) async {
    final auth = CheckoutDialogAuth()
      ..saved = fixture.command()
      ..admissionStatus = 'closed';
    await mount(tester, auth);
    await tester.tap(find.text(tr(UiLanguage.zh, 'tableCheckoutQuery')));
    await tester.pumpAndSettle();
    expect(
      find.text(tr(UiLanguage.zh, 'tableCheckoutCancelled')),
      findsNothing,
    );
    expect(find.byType(TextField), findsNothing);
    expect(auth.saved, isNotNull);
    await tester.tap(find.text(tr(UiLanguage.zh, 'tableCheckoutCancelQuery')));
    await tester.pumpAndSettle();
    expect(auth.cancellationQueries, 1);
    expect(auth.cancellations, 0);
    expect(
      find.text(tr(UiLanguage.zh, 'tableCheckoutCancelled')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('late cancellation response cannot restore background UI', (
    tester,
  ) async {
    final wait = Completer<void>();
    final auth = CheckoutDialogAuth()
      ..saved = fixture.command()
      ..cancellationWait = wait;
    await mount(tester, auth);
    await tester.tap(find.text(tr(UiLanguage.zh, 'tableCheckoutCancelQuery')));
    await tester.pump();
    await transitionLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    wait.complete();
    await tester.pump();
    await transitionLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(
      find.text(tr(UiLanguage.zh, 'tableCheckoutCancelled')),
      findsNothing,
    );
    expect(find.byType(TextField), findsNothing);
    expect(auth.collections, 0);
    expect(auth.cancellationQueries, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('background clears entered code and hides old transaction', (
    tester,
  ) async {
    final auth = CheckoutDialogAuth()..saved = fixture.command();
    await mount(tester, auth);
    await tester.tap(find.text(tr(UiLanguage.zh, 'tableCheckoutQuery')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'TEST_ONLY_CODE');
    await transitionLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    await transitionLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(auth.collections, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
