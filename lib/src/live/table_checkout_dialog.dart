import '../hardware/paid_receipt_printer.dart';
import 'table_discount_dialog.dart';
import '../hardware/receipt_document_renderer.dart';
import '../hardware/receipt_print_identity.dart';

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import '../network/ccsop_client.dart';
import 'table_checkout_command.dart';
import 'table_checkout_result.dart';
import 'table_snapshot.dart';
import 'payment_code_field.dart';
import '../hardware/scanner_input.dart';

class TableCheckoutDialog extends StatefulWidget {
  const TableCheckoutDialog({
    super.key,
    required this.auth,
    required this.tableRef,
    required this.sessionRef,
    required this.language,
    this.originalRequestId,
    this.paidCents = 0,
  });
  final StaffAuthController auth;
  final String tableRef, sessionRef;
  final UiLanguage language;
  final int paidCents;

  /// Recovery entry must remain bound to the selected durable original request.
  final String? originalRequestId;
  @override
  State<TableCheckoutDialog> createState() => _TableCheckoutDialogState();
}

class _TableCheckoutDialogState extends State<TableCheckoutDialog>
    with WidgetsBindingObserver {
  final input = TextEditingController();
  StreamSubscription<String>? scanner;
  TableCheckoutQuote? quote;
  TableCheckoutCommand? command;
  TableCheckoutAdmission? admission;
  TableCheckoutResult? result;
  String? settledOwner;
  String? get currentOwner {
    final identity = widget.auth.session;
    if (identity == null || !identity.expiresAt.isAfter(DateTime.now()))
      return null;
    return '${identity.base}|${identity.storeRef}|${identity.employeeRef}|${widget.tableRef}|${widget.sessionRef}';
  }

  bool get keepSettlement =>
      result?.settled == true &&
      settledOwner != null &&
      settledOwner == currentOwner;
  String choice = 'wechat', message = '';
  String printStatus = '';
  bool printing = false;
  final printedCheckouts = <String>{};
  bool foreground = true, busy = false, ready = false;
  bool cancelled = false;
  bool replaceCash = false;
  bool cancellationNeedsQuery = false, confirmationOpen = false;
  int epoch = 0;
  Route<dynamic>? unpaidPrintRoute;
  Timer? recoveryTimer;
  Timer? expiry;
  Timer? authorityExpiry;
  Stopwatch? freshness;
  String t(String key) => tr(widget.language, key);
  String get channel => ['platform_cash', 'store_balance'].contains(choice)
      ? 'member_balance'
      : choice;
  bool get barcodePayment => ['wechat', 'alipay'].contains(channel);
  String get scanPrompt => [
    '请出示付款码，扫码即可付款',
    'Scan the customer payment code to pay',
    '請出示付款碼，掃碼即可付款',
    'สแกนรหัสชำระเงินของลูกค้าเพื่อชำระเงิน',
  ][widget.language.index];
  String? get account => channel == 'member_balance' ? choice : null;
  List<String> get choices =>
      ['wechat', 'alipay', 'cash', 'pos', 'platform_cash', 'store_balance']
          .where(
            (value) =>
                widget.auth.session?.permissions.contains(
                  'payment.${['platform_cash', 'store_balance'].contains(value)
                      ? 'balance'
                      : value == 'pos'
                      ? 'cash'
                      : value}',
                ) ==
                true,
          )
          .toList();
  String label(String value) => t(
    value == 'cash'
        ? 'receiptCash'
        : ['platform_cash', 'store_balance'].contains(value)
        ? 'balance_$value'
        : 'provider_$value',
  );
  Future<void> printSettledReceipt(TableCheckoutResult settled) async {
    if (!settled.settled || !printedCheckouts.add(settled.checkoutRef)) return;
    setState(() {
      printing = true;
      printStatus = 'checkoutPrinting';
    });
    final auth = widget.auth;
    final identity = auth.session;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final language = widget.language;
    final status = await printPaidTableReceipt(
      auth: auth,
      checkoutRef: settled.checkoutRef,
      tableRef: widget.tableRef,
      sessionRef: widget.sessionRef,
      language: widget.language,
      // Closing the paid dialog must not cancel its receipt output.
      stillCurrent: () =>
          identity != null &&
          auth.session?.storeRef == identity.storeRef &&
          auth.session?.employeeRef == identity.employeeRef &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    if (status != 'checkoutPrintSent' && messenger?.mounted == true) {
      messenger!.showSnackBar(SnackBar(content: Text(tr(language, status))));
    }
    if (mounted)
      setState(() {
        printing = false;
        printStatus = status;
      });
  }

  Future<void> openReceipt() async {
    final settled = result;
    if (busy || printing || !foreground || settled?.settled != true) return;
    setState(() {
      printing = true;
      printStatus = 'checkoutPrinting';
    });
    final status = await printPaidTableReceipt(
      auth: widget.auth,
      checkoutRef: settled!.checkoutRef,
      tableRef: widget.tableRef,
      sessionRef: widget.sessionRef,
      language: widget.language,
      reprint: true,
      stillCurrent: () =>
          mounted && foreground && result?.checkoutRef == settled.checkoutRef,
    );
    if (mounted)
      setState(() {
        printing = false;
        printStatus = status;
      });
  }

  bool current(int e) => mounted && foreground && epoch == e;
  bool get fresh =>
      quote != null &&
      freshness != null &&
      freshness!.elapsed < const Duration(seconds: 30);
  @override
  void initState() {
    super.initState();
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    widget.auth.addListener(authChanged);
    WidgetsBinding.instance.addObserver(this);
    scanner = ScannerInput.codes.listen((code) async {
      if (!mounted ||
          !foreground ||
          busy ||
          confirmationOpen ||
          ModalRoute.of(context)?.isCurrent != true ||
          ['cash', 'pos'].contains(channel) ||
          !ready ||
          result?.settled == true)
        return;
      if (command == null) await startCollection();
      if (!mounted || admission?.paymentStatus != 'prepared') return;
      input.text = code;
      await collect();
    });
    if (foreground) unawaited(load());
  }

  void authChanged() {
    invalidate();
    // Restore the original durable request after the session refresh finishes.
    // Merely clearing the dialog here left a blank checkout until a manual tap.
    if (foreground && !widget.auth.busy && widget.auth.session != null) {
      unawaited(load());
    }
  }

  String get billReadFailure => [
    '账单暂未读取，请重试',
    'Could not load the bill. Please retry.',
    '????????????',
    '??????????????????? ????????????????',
  ][widget.language.index];

  void invalidate() {
    final keep = keepSettlement;
    epoch++;
    final printRoute = unpaidPrintRoute;
    unpaidPrintRoute = null;
    if (printRoute != null && printRoute.isActive && mounted) {
      Navigator.of(context).removeRoute(printRoute);
    }
    recoveryTimer?.cancel();
    expiry?.cancel();
    authorityExpiry?.cancel();
    freshness?.stop();
    freshness = null;
    input.clear();
    if (mounted) {
      setState(() {
        if (!keep) {
          quote = null;
          command = null;
          admission = null;
          result = null;
          settledOwner = null;
        }
        ready = false;
        busy = false;
        confirmationOpen = false;
        cancelled = false;
        cancellationNeedsQuery = false;
        message = '';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    invalidate();
    if (foreground) unawaited(load());
  }

  @override
  void didUpdateWidget(covariant TableCheckoutDialog old) {
    super.didUpdateWidget(old);
    if (old.auth != widget.auth ||
        old.tableRef != widget.tableRef ||
        old.sessionRef != widget.sessionRef ||
        old.originalRequestId != widget.originalRequestId) {
      old.auth.removeListener(authChanged);
      widget.auth.addListener(authChanged);
      authChanged();
    }
  }

  @override
  void dispose() {
    epoch++;
    recoveryTimer?.cancel();
    expiry?.cancel();
    authorityExpiry?.cancel();
    freshness?.stop();
    scanner?.cancel();
    input.dispose();
    widget.auth.removeListener(authChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    if (!foreground || busy) return;
    if (keepSettlement) {
      // A refreshed login does not undo a verified payment or reopen collection.
      authorityExpiry?.cancel();
      authorityExpiry = Timer(
        widget.auth.session!.expiresAt.difference(DateTime.now()),
        invalidate,
      );
      return;
    }
    final e = epoch;
    setState(() => busy = true);
    try {
      final identity = widget.auth.session;
      final remaining = identity?.expiresAt.difference(DateTime.now());
      if (remaining == null || remaining <= Duration.zero) {
        throw const FormatException();
      }
      authorityExpiry?.cancel();
      authorityExpiry = Timer(remaining, invalidate);
      final pending = <TableCheckoutCommand>[];
      for (final c in ['wechat', 'alipay', 'cash', 'pos', 'member_balance']) {
        if (widget.auth.session?.permissions.contains(
              'payment.${c == 'member_balance'
                  ? 'balance'
                  : c == 'pos'
                  ? 'cash'
                  : c}',
            ) ==
            true) {
          pending.addAll(await widget.auth.pendingTableCheckouts(c));
          if (!current(e)) return;
        }
      }
      final matches = pending
          .where(
            (p) =>
                p.tableRef == widget.tableRef &&
                p.sessionRef == widget.sessionRef,
          )
          .toList();
      if (matches.length > 1 || choices.isEmpty) throw const FormatException();
      if (widget.originalRequestId != null &&
          (matches.length != 1 ||
              matches.single.requestId != widget.originalRequestId)) {
        throw const FormatException();
      }
      if (current(e)) {
        setState(() {
          command = matches.isEmpty ? null : matches.single;
          choice = command == null
              ? (choices.contains(choice) ? choice : choices.first)
              : command!.accountType ?? command!.channel;
          ready = true;
          message = '';
        });
      }
    } catch (_) {
      if (current(e)) setState(() => message = billReadFailure);
    } finally {
      if (current(e)) setState(() => busy = false);
    }
    if (current(e) && ready) {
      if (command == null) {
        await readQuote();
      } else {
        await resumePayment();
      }
    }
  }

  Future<void> resumePayment() async {
    if (!mounted ||
        busy ||
        !foreground ||
        command == null ||
        cancelled ||
        result?.settled == true)
      return;
    await queryAdmission();
    if (!mounted || !foreground) return;
    if (admission?.paymentStatus == 'closed') {
      await cancelOriginal(queryOnly: true);
    }
    if (!cancelled &&
        admission?.observed == true &&
        admission?.paymentStatus != 'prepared') {
      await collect(recover: true);
    }
    if (mounted &&
        !cancelled &&
        result?.settled != true &&
        admission?.paymentStatus != 'prepared') {
      recoveryTimer?.cancel();
      recoveryTimer = Timer(
        const Duration(seconds: 3),
        () => unawaited(resumePayment()),
      );
    }
  }

  Future<void> dismissCheckout() async {
    if (busy || printing) return;
    if (command != null &&
        admission?.paymentStatus == 'prepared' &&
        result?.settled != true) {
      await cancelOriginal();
    }
    if (result?.canCloseUnpaid == true) await collect(close: true);
    if (mounted) Navigator.of(context).pop(result?.settled == true);
  }

  Future<void> readQuote() async {
    if (!ready || busy || !foreground || command != null) return;
    final e = epoch;
    expiry?.cancel();
    final watch = Stopwatch()..start();
    setState(() {
      busy = true;
      freshness = null;
      message = '';
    });
    try {
      final next = await widget.auth.quoteTableCheckout(
        tableRef: widget.tableRef,
        sessionRef: widget.sessionRef,
        channel: channel,
        accountType: account,
      );
      if (!current(e)) return;
      final remaining = const Duration(seconds: 30) - watch.elapsed;
      if (remaining <= Duration.zero) throw const FormatException();
      setState(() {
        quote = next;
        freshness = watch;
      });
      expiry = Timer(remaining, () {
        if (current(e)) {
          // Keep the displayed bill; freshness still gates every payment.
          setState(() {});
        }
      });
    } catch (error) {
      // Log only a bounded error identifier, never request or payment data.
      final failureCode = error is CcsopFailure
          ? error.code
          : error.runtimeType.toString();
      if (RegExp(r'^[A-Za-z0-9_]{1,100}$').hasMatch(failureCode)) {
        debugPrint('cashier_checkout_quote: $failureCode');
      }
      if (current(e)) {
        if (error is CcsopFailure &&
            error.code == 'CASHIER_TABLE_CHECKOUT_SCOPE_CHANGED') {
          setState(() {
            quote = null;
            message = [
              '?????????????????????',
              'This table session has ended or changed. Return to tables.',
              '?????????????????????',
              '????????????????????????????? ???????????????????',
            ][widget.language.index];
          });
          // Do not leave an old-business-day payment dialog above the new table.
          if (ModalRoute.of(context)?.isCurrent == true) {
            unawaited(Navigator.of(context).maybePop());
          }
        } else {
          setState(
            () => message =
                error is CcsopFailure &&
                    error.code == 'CASHIER_TABLE_CHECKOUT_NOT_ENABLED'
                ? t('tableCheckoutUnavailable')
                : billReadFailure,
          );
        }
      }
    } finally {
      if (current(e)) setState(() => busy = false);
    }
  }

  String newRequest() {
    final random = Random.secure(),
        bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final s = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  Future<bool> confirmAction(
    String title,
    String notice,
    TableCheckoutCommand original,
  ) async {
    final e = epoch;
    setState(() {
      busy = true;
      confirmationOpen = true;
    });
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(t(title)),
          content: Text(
            '${label(original.accountType ?? original.channel)} / CNY ${formatCents(original.totalCents)}\n${t(notice)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(t('cancel')),
            ),
            FilledButton(
              key: const ValueKey('table-checkout-confirm-action'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(t('confirm')),
            ),
          ],
        ),
      );
      return current(e) && accepted == true;
    } finally {
      if (current(e)) {
        setState(() {
          busy = false;
          confirmationOpen = false;
        });
      }
    }
  }

  Future<void> prepare({bool retry = false}) async {
    if (!foreground ||
        busy ||
        cancelled ||
        cancellationNeedsQuery ||
        (retry ? command == null : !fresh || command != null)) {
      return;
    }
    final identity = widget.auth.session, e = epoch, watch = freshness;
    if (identity == null) return;
    final original = retry
        ? command!
        : TableCheckoutCommand.fromQuote(
            identity,
            quote!,
            requestId: newRequest(),
          );
    setState(() {
      command = original;
      busy = true;
      message = '';
    });
    try {
      final next = await widget.auth.prepareTableCheckout(
        original,
        confirmed: true,
        stillCurrent: () =>
            current(e) &&
            (retry ||
                watch != null && watch.elapsed < const Duration(seconds: 30)),
      );
      if (current(e)) setState(() => admission = next);
    } catch (_) {
      if (!current(e)) return;
      // Preparation may commit before its response is lost. Query the SAME
      // request once; this never prepares again or sends a payment code.
      try {
        final observed = await widget.auth.lookupTableCheckout(original);
        if (current(e)) {
          setState(() {
            admission = observed;
            message = observed.observed ? '' : t('tableCheckoutMissing');
          });
        }
      } catch (_) {
        if (current(e)) setState(() => message = t('tableCheckoutReview'));
      }
    } finally {
      if (current(e)) setState(() => busy = false);
    }
  }

  Future<void> queryAdmission() async {
    final original = command;
    if (!foreground || busy || original == null || cancelled) return;
    final e = epoch;
    setState(() {
      busy = true;
      admission = null;
      message = '';
    });
    input.clear();
    try {
      final next = await widget.auth.lookupTableCheckout(original);
      if (current(e)) {
        setState(() {
          admission = next;
          cancellationNeedsQuery = false;
          if (!next.observed) message = t('tableCheckoutMissing');
        });
      }
    } catch (_) {
      if (current(e)) setState(() => message = t('tableCheckoutReview'));
    } finally {
      if (current(e)) setState(() => busy = false);
    }
  }

  int cashCents(String value) {
    if (!RegExp(r'^(0|[1-9][0-9]{0,6})(\.[0-9]{1,2})?$').hasMatch(value)) {
      throw const FormatException();
    }
    final parts = value.split('.');
    return int.parse(parts[0]) * 100 +
        (parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0')));
  }

  Future<void> cancelOriginal({bool queryOnly = false}) async {
    final original = command;
    if (!foreground ||
        busy ||
        original == null ||
        cancelled ||
        result?.settled == true ||
        (!queryOnly && admission?.paymentStatus != 'prepared')) {
      return;
    }
    final e = epoch;
    if (!current(e)) return;
    input.clear();
    setState(() {
      busy = true;
      admission = null;
      cancellationNeedsQuery = true;
      message = '';
    });
    try {
      final next = queryOnly
          ? await widget.auth.lookupTableCancellation(
              original,
              stillCurrent: () => current(e),
            )
          : await widget.auth.cancelTableCheckout(
              original,
              confirmed: true,
              stillCurrent: () => current(e),
            );
      if (!current(e)) return;
      setState(() {
        cancelled = next.cancelled;
        message = t(
          next.cancelled
              ? 'tableCheckoutCancelled'
              : 'tableCheckoutNotCancelled',
        );
      });
    } catch (_) {
      if (current(e)) setState(() => message = t('tableCheckoutReview'));
    } finally {
      if (current(e)) setState(() => busy = false);
    }
  }

  Future<void> collect({bool recover = false, bool close = false}) async {
    final original = command;
    if (!foreground ||
        busy ||
        cancelled ||
        original == null ||
        (admission?.observed != true &&
            !(close &&
                result?.canCloseUnpaid == true &&
                result!.matches(original)))) {
      return;
    }
    final e = epoch, text = input.text;
    if (!recover &&
        !close &&
        !['wechat', 'alipay'].contains(original.channel) &&
        !await confirmAction(
          'tableCheckoutCollect',
          original.channel == 'pos'
              ? 'checkoutPosConsent'
              : 'tableCheckoutCollectConsent',
          original,
        )) {
      return;
    }
    if (!current(e)) return;
    input.clear();
    setState(() {
      busy = true;
      message = '';
      admission = null;
    });
    try {
      final next = close
          ? await widget.auth.closeTableProvider(
              original,
              stillCurrent: () => current(e),
            )
          : recover
          ? await widget.auth.recoverTableCheckout(
              original,
              stillCurrent: () => current(e),
            )
          : await widget.auth.collectTableCheckout(
              original,
              confirmed: true,
              stillCurrent: () => current(e),
              payerCode: original.channel == 'cash' ? null : text,
              cashReceivedCents: original.channel == 'cash'
                  ? cashCents(text)
                  : null,
            );
      if (current(e)) {
        setState(() {
          result = next;
          if (next.settled) settledOwner = currentOwner;
          cancelled = next.closedUnpaid;
          message = t('tableCheckout_${next.state}');
        });
        if (next.settled) {
          unawaited(printSettledReceipt(next));
          Navigator.of(context).pop(true);
        }
      }
    } catch (error) {
      // A failed send must be classified by the server's original request.
      // Restore scanning only when it is still prepared; never retry this code.
      if (current(e)) {
        try {
          final latest = await widget.auth.lookupTableCheckout(original);
          if (current(e)) setState(() => admission = latest);
        } catch (_) {
          // Keep recovery-only controls when the original state is unavailable.
        }
      }
      final soldOut =
          error is CcsopFailure &&
          [
            'ORDERING_OUT_OF_STOCK',
            'ORDERING_POSTPAY_OUT_OF_STOCK',
          ].contains(error.code);
      final postpayShortage =
          error is CcsopFailure &&
          error.code == 'ORDERING_POSTPAY_OUT_OF_STOCK';
      if (current(e)) {
        setState(
          () => message =
              error is CcsopFailure &&
                  error.code == 'CASHIER_TABLE_ORDER_EXPIRED'
              ? [
                  '订单已超时，未扣款。请取消本次收款后重新下单。',
                  'Order expired; no charge. Cancel this collection and place a new order.',
                  '訂單已逾時，未扣款。請取消本次收款後重新下單。',
                  'คำสั่งซื้อหมดเวลา ยังไม่เรียกเก็บเงิน โปรดยกเลิกการรับชำระนี้แล้วสั่งใหม่',
                ][widget.language.index]
              : t(
                  soldOut
                      ? (original.channel == 'cash'
                            ? (postpayShortage
                                  ? 'postpayCashStockUnavailable'
                                  : 'cashStockUnavailable')
                            : (postpayShortage
                                  ? 'postpayStockUnavailable'
                                  : 'paymentStockUnavailable'))
                      : 'tableCheckoutReview',
                ),
        );
      }
    } finally {
      if (current(e)) setState(() => busy = false);
    }
    if (current(e) &&
        !cancelled &&
        result?.settled != true &&
        admission?.paymentStatus != 'prepared') {
      recoveryTimer?.cancel();
      recoveryTimer = Timer(
        const Duration(seconds: 3),
        () => unawaited(resumePayment()),
      );
    }
  }

  Future<void> discount({bool waive = false}) async {
    if (busy || !foreground || command != null) return;
    await readQuote();
    if (!mounted || !fresh || quote == null) return;
    final changed = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => TableDiscountDialog(
        auth: widget.auth,
        quote: quote!,
        language: widget.language,
        requestId: newRequest(),
        waive: waive,
      ),
    );
    if (!mounted) return;
    if (changed != null && changed['totalCents'] == 0) {
      Navigator.of(context).pop(true);
      return;
    }
    quote = null;
    freshness = null;
    await readQuote();
  }

  Future<void> printUnpaid() async {
    if (busy || printing || !foreground || command != null) return;
    await readQuote();
    final q = quote, identity = widget.auth.session, generation = epoch;
    if (!mounted || !fresh || q == null || identity == null) return;
    setState(() {
      printing = true;
      message = t('checkoutPrinting');
    });
    final status = await printReceiptPlan(
      plan: ReceiptRasterPlan.unpaid(
        q,
        caption: await readReceiptCaption(
          widget.auth,
          q.tableRef,
          q.sessionRef,
        ),
        language: widget.language,
        widthDots: 576,
      ),
      printIdentity: ReceiptPrintIdentity.unpaid(
        base: identity.base.toString(),
        storeRef: q.storeRef,
        fingerprint: q.fingerprint,
      ),
      current: () =>
          current(generation) && identical(identity, widget.auth.session),
      reprint: true,
    );
    if (mounted)
      setState(() {
        printing = false;
        message = t(
          status == 'checkoutPrintSent' ? status : 'receiptPrinterUnavailable',
        );
      });
  }

  Future<void> startCollection() async {
    if (busy || !foreground || !ready || command != null) return;
    if (!fresh) await readQuote();
    if (!mounted || !fresh || busy) return;
    await prepare();
    if (!mounted || admission?.paymentStatus != 'prepared') return;
    if (channel == 'cash') {
      input.clear();
      replaceCash = false;
    }
  }

  Widget amount(String title, int? cents, {bool prominent = false}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: const TextStyle(fontSize: 14, color: Colors.black54)),
      const SizedBox(height: 8),
      Text(
        cents == null ? '—' : '￥ ${formatCents(cents)}',
        style: TextStyle(
          fontSize: prominent ? 32 : 24,
          fontWeight: FontWeight.w700,
          color: prominent ? const Color(0xffbd3039) : null,
        ),
      ),
    ],
  );

  Widget cashPad() => Column(
    children: [
      TextField(
        key: const ValueKey('cash-amount-input'),
        controller: input,
        readOnly: true,
        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        decoration: InputDecoration(labelText: t('cashReceived')),
      ),
      const SizedBox(height: 12),
      for (final row in const [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9'],
        ['.', '0', '⌫'],
      ])
        Row(
          children: [
            for (final digit in row)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: OutlinedButton(
                    onPressed: busy
                        ? null
                        : () {
                            var value = input.text;
                            if (digit == '⌫') {
                              input.text = value.isEmpty
                                  ? ''
                                  : value.substring(0, value.length - 1);
                              replaceCash = false;
                            } else {
                              if (replaceCash) value = '';
                              if (digit == '.') {
                                if (!value.contains('.')) {
                                  input.text = value.isEmpty ? '0.' : '$value.';
                                }
                              } else if (!(value.contains('.') &&
                                  value.split('.').last.length >= 2)) {
                                final next =
                                    (value == '0' ? '' : value) + digit;
                                if (RegExp(r'^\d{1,7}(\.\d{0,2})?$')
                                    .hasMatch(next)) {
                                  input.text = next;
                                }
                              }
                              replaceCash = false;
                            }
                            setState(() {});
                          },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(digit, style: const TextStyle(fontSize: 22)),
                    ),
                  ),
                ),
              ),
          ],
        ),
      TextButton(
        onPressed: busy
            ? null
            : () => setState(() {
                input.text = formatCents(command!.totalCents);
                replaceCash = true;
              }),
        child: Text(t('checkoutExactCash')),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final original = command, q = quote;
    final originalDue = original?.totalCents ?? q?.totalCents;
    final due = result?.settled == true ? 0 : originalDue;
    final paid =
        widget.paidCents + (result?.settled == true ? originalDue ?? 0 : 0);
    return Dialog(
      child: SizedBox(
        width: 880,
        height: 630,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t('tableCheckoutTitle'),
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: busy || printing ? null : dismissCheckout,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: amount(
                      t('checkoutTotal'),
                      due == null ? null : due + paid,
                    ),
                  ),
                  Expanded(child: amount(t('checkoutPaid'), paid)),
                  Expanded(
                    child: amount(t('checkoutDue'), due, prominent: true),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Divider(height: 1),
              const SizedBox(height: 16),
              Expanded(
                child: !foreground
                    ? const SizedBox.shrink()
                    : result?.settled == true
                    ? Center(
                        child: Column(
                          key: const ValueKey('checkout-success'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.check_circle,
                              color: Color(0xff168657),
                              size: 68,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              t('checkoutSuccess'),
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '￥ ${formatCents(originalDue ?? 0)}',
                              style: const TextStyle(
                                fontSize: 38,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 16),
                            if (printStatus.isNotEmpty) Text(t(printStatus)),
                            const SizedBox(height: 20),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                OutlinedButton(
                                  key: const ValueKey(
                                    'checkout-settled-receipt',
                                  ),
                                  onPressed: printing ? null : openReceipt,
                                  child: Text(t('receiptReprint')),
                                ),
                                const SizedBox(width: 16),
                                FilledButton(
                                  onPressed: printing ? null : dismissCheckout,
                                  child: Text(t('checkoutDone')),
                                ),
                              ],
                            ),
                          ],
                        ),
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                if (command == null)
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      onPressed:
                                          busy || printing || quote == null
                                          ? null
                                          : printUnpaid,
                                      icon: const Icon(Icons.print_outlined),
                                      label: Text(t('checkoutUnpaidTicket')),
                                    ),
                                  ),
                                if (command == null &&
                                    widget.auth.session?.permissions.contains(
                                          'orders.create',
                                        ) ==
                                        true)
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      OutlinedButton(
                                        onPressed:
                                            busy || printing || quote == null
                                            ? null
                                            : () => discount(),
                                        child: Text(t('checkoutDiscount')),
                                      ),
                                      OutlinedButton(
                                        onPressed:
                                            busy || printing || quote == null
                                            ? null
                                            : () => discount(waive: true),
                                        child: Text(t('checkoutWaive')),
                                      ),
                                    ],
                                  ),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    for (final value in choices)
                                      ChoiceChip(
                                        label: Text(label(value)),
                                        selected: choice == value,
                                        onSelected: busy || original != null
                                            ? null
                                            : (_) {
                                                setState(() {
                                                  choice = value;
                                                  freshness = null;
                                                  input.clear();
                                                });
                                                unawaited(readQuote());
                                              },
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Expanded(
                                  child: q == null
                                      ? const SizedBox.shrink()
                                      : ListView(
                                          key: const ValueKey(
                                            'table-checkout-bill-lines',
                                          ),
                                          children: [
                                            for (final line in q.lines)
                                              ListTile(
                                                dense: true,
                                                contentPadding: EdgeInsets.zero,
                                                title: Text(
                                                  line.name(widget.language),
                                                ),
                                                subtitle: Text(
                                                  '${line.specification(widget.language)} × ${line.quantity}',
                                                ),
                                                trailing: Text(
                                                  '￥ ${formatCents(line.quantity * line.priceCents)}',
                                                ),
                                              ),
                                          ],
                                        ),
                                ),
                                Text(
                                  t('checkoutCouponUnavailable'),
                                  style: const TextStyle(
                                    color: Colors.black45,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 24),
                          SizedBox(
                            width: 310,
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (!ready)
                                    OutlinedButton(
                                      onPressed: busy ? null : load,
                                      child: Text(t('ordersRefresh')),
                                    ),
                                  if (ready &&
                                      original == null &&
                                      !['cash', 'pos'].contains(channel))
                                    PaymentCodeField(
                                      controller: input,
                                      enabled: !busy && q != null,
                                      label: t('tableCheckoutCode'),
                                    ),
                                  if (ready &&
                                      barcodePayment &&
                                      q != null &&
                                      original == null)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 20,
                                      ),
                                      child: Text(
                                        scanPrompt,
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  if (ready &&
                                      original == null &&
                                      (!barcodePayment || q == null))
                                    FilledButton(
                                      onPressed: busy
                                          ? null
                                          : q == null
                                          ? readQuote
                                          : startCollection,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 14,
                                        ),
                                        child: Text(
                                          t(
                                            q == null
                                                ? 'ordersRefresh'
                                                : 'checkoutStart',
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (original != null &&
                                      result?.settled == true)
                                    OutlinedButton(
                                      key: const ValueKey(
                                        'checkout-settled-receipt',
                                      ),
                                      onPressed: busy ? null : openReceipt,
                                      child: Text(t('receiptReprint')),
                                    ),
                                  if (original != null &&
                                      result?.settled != true &&
                                      !cancelled) ...[
                                    if (admission?.paymentStatus ==
                                            'prepared' &&
                                        !cancellationNeedsQuery) ...[
                                      if (original.channel == 'cash')
                                        cashPad()
                                      else if (original.channel == 'pos')
                                        TextField(
                                          controller: input,
                                          enabled: !busy,
                                          decoration: InputDecoration(
                                            labelText: t(
                                              'checkoutPosReference',
                                            ),
                                          ),
                                        )
                                      else
                                        PaymentCodeField(
                                          controller: input,
                                          enabled: !busy,
                                          label: t('tableCheckoutCode'),
                                        ),
                                      const SizedBox(height: 12),
                                      if (barcodePayment)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 12,
                                          ),
                                          child: Text(
                                            scanPrompt,
                                            textAlign: TextAlign.center,
                                          ),
                                        ),
                                      if (!barcodePayment)
                                        FilledButton(
                                          onPressed: busy
                                              ? null
                                              : () => unawaited(collect()),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              vertical: 12,
                                            ),
                                            child: Text(
                                              t('tableCheckoutCollect'),
                                            ),
                                          ),
                                        ),
                                      OutlinedButton(
                                        onPressed: busy
                                            ? null
                                            : dismissCheckout,
                                        child: Text(t('cancel')),
                                      ),
                                    ] else ...[
                                      Text(
                                        [
                                          '正在确认付款结果，请稍候',
                                          'Checking payment status…',
                                          '正在確認付款結果，請稍候',
                                          'กำลังตรวจสอบการชำระเงิน',
                                        ][widget.language.index],
                                      ),
                                      TextButton(
                                        onPressed: busy ? null : resumePayment,
                                        child: Text(t('ordersRefresh')),
                                      ),
                                    ],
                                  ],
                                  if (busy && !confirmationOpen)
                                    const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: Center(
                                        child: SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (message.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 12),
                                      child: Text(message),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
