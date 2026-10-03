import 'table_discount_dialog.dart';
import '../hardware/receipt_document_renderer.dart';
import '../hardware/receipt_output_panel.dart';
import '../hardware/receipt_print_identity.dart';

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import '../network/ccsop_client.dart';
import 'table_checkout_command.dart';
import 'table_checkout_result.dart';
import 'table_receipt_dialog.dart';
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
  String choice = 'wechat', message = '';
  bool foreground = true, busy = false, ready = false;
  bool cancelled = false;
  bool replaceCash = false;
  bool cancellationNeedsQuery = false, confirmationOpen = false;
  int epoch = 0;
  Route<dynamic>? unpaidPrintRoute;
  Timer? expiry;
  Timer? authorityExpiry;
  Stopwatch? freshness;
  String t(String key) => tr(widget.language, key);
  String get channel => ['platform_cash', 'store_balance'].contains(choice)
      ? 'member_balance'
      : choice;
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
  Future<void> openReceipt() async {
    final settled = result;
    final identity = widget.auth.session;
    final generation = epoch;
    if (busy ||
        !foreground ||
        settled?.settled != true ||
        identity?.permissions.contains('orders.read') != true) {
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        if (!current(generation) || !identical(identity, widget.auth.session)) {
          return AlertDialog(content: Text(t('receiptDocumentReload')));
        }
        return TableReceiptDialog(
          auth: widget.auth,
          checkoutRef: settled!.checkoutRef,
          tableRef: widget.tableRef,
          sessionRef: widget.sessionRef,
          language: widget.language,
        );
      },
    );
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
    widget.auth.addListener(invalidate);
    WidgetsBinding.instance.addObserver(this);
    scanner = ScannerInput.codes.listen((code) {
      if (!mounted ||
          !foreground ||
          busy ||
          confirmationOpen ||
          ModalRoute.of(context)?.isCurrent != true ||
          ['cash', 'pos'].contains(command?.channel) ||
          admission?.paymentStatus != 'prepared') {
        return;
      }
      input.text = code;
      unawaited(collect());
    });
    if (foreground) unawaited(load());
  }

  void invalidate() {
    epoch++;
    final printRoute = unpaidPrintRoute;
    unpaidPrintRoute = null;
    if (printRoute != null && printRoute.isActive && mounted) {
      Navigator.of(context).removeRoute(printRoute);
    }
    expiry?.cancel();
    authorityExpiry?.cancel();
    freshness?.stop();
    freshness = null;
    input.clear();
    if (mounted) {
      setState(() {
        quote = null;
        command = null;
        admission = null;
        result = null;
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
      old.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
      invalidate();
    }
  }

  @override
  void dispose() {
    epoch++;
    expiry?.cancel();
    authorityExpiry?.cancel();
    freshness?.stop();
    scanner?.cancel();
    input.dispose();
    widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    if (!foreground || busy) return;
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
      if (current(e)) setState(() => message = t('tableCheckoutReview'));
    } finally {
      if (current(e)) setState(() => busy = false);
    }
    if (current(e) && ready && command == null) await readQuote();
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
        setState(
          () => message = t(
            error is CcsopFailure &&
                    error.code == 'CASHIER_TABLE_CHECKOUT_NOT_ENABLED'
                ? 'tableCheckoutUnavailable'
                : 'tableCheckoutReview',
          ),
        );
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
      if (current(e)) setState(() => message = t('tableCheckoutReview'));
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
    if (!queryOnly &&
        !await confirmAction(
          'tableCheckoutCancel',
          'tableCheckoutCancelConsent',
          original,
        )) {
      return;
    }
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
          cancelled = next.closedUnpaid;
          message = t('tableCheckout_${next.state}');
        });
      }
    } catch (error) {
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
          () => message = t(
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
    if (busy || !foreground || command != null) return;
    await readQuote();
    final q = quote, identity = widget.auth.session, generation = epoch;
    if (!mounted || !fresh || q == null || identity == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) {
        if (!current(generation) || !identical(identity, widget.auth.session))
          return const SizedBox.shrink();
        unpaidPrintRoute = ModalRoute.of(context);
        return AlertDialog(
          title: Text(t('checkoutUnpaidTicket')),
          content: SizedBox(
            width: 550,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(t('checkoutNotPaymentProof')),
                  for (final line in q.lines)
                    ListTile(
                      dense: true,
                      title: Text(line.name(widget.language)),
                      trailing: Text(
                        '× ${line.quantity}  ￥ ${formatCents(line.quantity * line.priceCents)}',
                      ),
                    ),
                  ReceiptOutputPanel(
                    plan: ReceiptRasterPlan.unpaid(
                      q,
                      language: widget.language,
                      widthDots: 576,
                    ),
                    language: widget.language,
                    identity: ReceiptPrintIdentity.unpaid(
                      base: identity.base.toString(),
                      storeRef: q.storeRef,
                      fingerprint: q.fingerprint,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('printerInspectClose')),
            ),
          ],
        );
      },
    );
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
                    onPressed: busy
                        ? null
                        : () =>
                              Navigator.of(context)
                                  .pop(result?.settled == true),
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
                                      onPressed: busy || quote == null
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
                                        onPressed: busy || quote == null
                                            ? null
                                            : () => discount(),
                                        child: Text(t('checkoutDiscount')),
                                      ),
                                      OutlinedButton(
                                        onPressed: busy || quote == null
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
                                  if (ready && original == null)
                                    FilledButton(
                                      onPressed: busy || q == null
                                          ? null
                                          : startCollection,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 14,
                                        ),
                                        child: Text(t('checkoutStart')),
                                      ),
                                    ),
                                  if (original != null &&
                                      result?.settled == true)
                                    OutlinedButton(
                                      key: const ValueKey(
                                        'checkout-settled-receipt',
                                      ),
                                      onPressed: busy ? null : openReceipt,
                                      child: Text(t('tableReceiptTitle')),
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
                                      OutlinedButton(
                                        onPressed: busy
                                            ? null
                                            : () => unawaited(
                                                collect(recover: true),
                                              ),
                                        child: Text(t('tableCheckoutRecover')),
                                      ),
                                      const SizedBox(height: 12),
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
                                            : () => unawaited(cancelOriginal()),
                                        child: Text(t('tableCheckoutCancel')),
                                      ),
                                    ] else ...[
                                      OutlinedButton(
                                        onPressed: busy
                                            ? null
                                            : () => unawaited(queryAdmission()),
                                        child: Text(t('tableCheckoutQuery')),
                                      ),
                                      if (admission?.observed == true)
                                        OutlinedButton(
                                          onPressed: busy
                                              ? null
                                              : () => unawaited(
                                                  collect(recover: true),
                                                ),
                                          child: Text(
                                            t('tableCheckoutRecover'),
                                          ),
                                        ),
                                      if (!cancellationNeedsQuery &&
                                          (admission == null ||
                                              !admission!.observed))
                                        OutlinedButton(
                                          onPressed: busy
                                              ? null
                                              : () => unawaited(
                                                  prepare(retry: true),
                                                ),
                                          child: Text(
                                            t('tableCheckoutRetryPrepare'),
                                          ),
                                        ),
                                      if (cancellationNeedsQuery ||
                                          admission?.paymentStatus ==
                                              'closed' ||
                                          admission == null)
                                        OutlinedButton(
                                          onPressed: busy
                                              ? null
                                              : () => unawaited(
                                                  cancelOriginal(
                                                    queryOnly: true,
                                                  ),
                                                ),
                                          child: Text(
                                            t('tableCheckoutCancelQuery'),
                                          ),
                                        ),
                                      if (result?.canCloseUnpaid == true &&
                                          original.channel == 'alipay')
                                        OutlinedButton(
                                          onPressed: busy
                                              ? null
                                              : () => unawaited(
                                                  collect(close: true),
                                                ),
                                          child: Text(
                                            t('provider_close_attempt'),
                                          ),
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
