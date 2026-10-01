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

class TableCheckoutDialog extends StatefulWidget {
  const TableCheckoutDialog({
    super.key,
    required this.auth,
    required this.tableRef,
    required this.sessionRef,
    required this.language,
    this.originalRequestId,
  });
  final StaffAuthController auth;
  final String tableRef, sessionRef;
  final UiLanguage language;

  /// Recovery entry must remain bound to the selected durable original request.
  final String? originalRequestId;
  @override
  State<TableCheckoutDialog> createState() => _TableCheckoutDialogState();
}

class _TableCheckoutDialogState extends State<TableCheckoutDialog>
    with WidgetsBindingObserver {
  final input = TextEditingController();
  TableCheckoutQuote? quote;
  TableCheckoutCommand? command;
  TableCheckoutAdmission? admission;
  TableCheckoutResult? result;
  String choice = 'wechat', message = '';
  bool foreground = true, busy = false, ready = false;
  bool cancelled = false;
  bool cancellationNeedsQuery = false, confirmationOpen = false;
  int epoch = 0;
  Timer? expiry;
  Timer? authorityExpiry;
  Stopwatch? freshness;
  String t(String key) => tr(widget.language, key);
  String get channel => ['platform_cash', 'store_balance'].contains(choice)
      ? 'member_balance'
      : choice;
  String? get account => channel == 'member_balance' ? choice : null;
  List<String>
  get choices => ['wechat', 'alipay', 'cash', 'platform_cash', 'store_balance']
      .where(
        (value) =>
            widget.auth.session?.permissions.contains(
              'payment.${['platform_cash', 'store_balance'].contains(value) ? 'balance' : value}',
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
    if (foreground) unawaited(load());
  }

  void invalidate() {
    epoch++;
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
      for (final c in ['wechat', 'alipay', 'cash', 'member_balance']) {
        if (widget.auth.session?.permissions.contains(
              'payment.${c == 'member_balance' ? 'balance' : c}',
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
  }

  Future<void> readQuote() async {
    if (!ready || busy || !foreground || command != null) return;
    final e = epoch;
    expiry?.cancel();
    final watch = Stopwatch()..start();
    setState(() {
      busy = true;
      quote = null;
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
          setState(() {
            quote = null;
          });
        }
      });
    } catch (error) {
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

  Future<void> collect({bool recover = false,bool close = false}) async {
    final original = command;
    if (!foreground ||
        busy ||
        cancelled ||
        original == null ||
        (admission?.observed != true&&!(close&&result?.canCloseUnpaid==true&&result!.matches(original)))) {
      return;
    }
    final e = epoch, text = input.text;
    if (!recover && !close &&
        !await confirmAction(
          'tableCheckoutCollect',
          'tableCheckoutCollectConsent',
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
      final next = close ? await widget.auth.closeTableProvider(original,stillCurrent:()=>current(e)) : recover
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

  @override
  Widget build(BuildContext context) {
    final original = command, q = quote;
    return Dialog(
      child: SizedBox(
        width: 760,
        height: 680,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text(t('tableCheckoutTitle'))),
                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pop(result?.settled == true),
                    child: Text(t('printerInspectClose')),
                  ),
                ],
              ),
              if (busy && !confirmationOpen) const LinearProgressIndicator(),
              Expanded(
                child: !foreground
                    ? const SizedBox.shrink()
                    : SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('${widget.tableRef} · ${widget.sessionRef}'),
                            Text(t('tableCheckoutNotice')),
                            if (!ready)
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => unawaited(load()),
                                child: Text(t('ordersRefresh')),
                              ),
                            if (ready && original == null) ...[
                              DropdownButton<String>(
                                value: choice,
                                isExpanded: true,
                                items: choices
                                    .map(
                                      (v) => DropdownMenuItem(
                                        value: v,
                                        child: Text(label(v)),
                                      ),
                                    )
                                    .toList(),
                                onChanged: busy
                                    ? null
                                    : (v) {
                                        if (v != null) {
                                          setState(() {
                                            choice = v;
                                            quote = null;
                                            expiry?.cancel();
                                          });
                                        }
                                      },
                              ),
                              OutlinedButton(
                                onPressed: busy
                                    ? null
                                    : () => unawaited(readQuote()),
                                child: Text(t('tableCheckoutQuote')),
                              ),
                              if (q != null) ...[
                                Text(
                                  'CNY ${formatCents(q.totalCents)} · ${q.allocations.length} ${t('tableReceiptOrders')}',
                                ),
                                SizedBox(
                                  height: 260,
                                  child: ListView.builder(
                                    key: const ValueKey(
                                      'table-checkout-bill-lines',
                                    ),
                                    itemCount: q.allocations.length,
                                    itemBuilder: (context, index) {
                                      final a = q.allocations[index];
                                      return ExpansionTile(
                                        key: ValueKey(
                                          '${q.fingerprint}-${a.orderRef}',
                                        ),
                                        title: Text(
                                          '${a.orderRef} · CNY ${formatCents(a.totalCents)}',
                                        ),
                                        initiallyExpanded:
                                            q.allocations.length == 1,
                                        children: [
                                          for (final line
                                              in q.linesByOrder[a.orderRef]!)
                                            ListTile(
                                              title: Text(
                                                line.name(widget.language),
                                              ),
                                              subtitle: Text(
                                                '${line.specification(widget.language)} · ${line.quantity} × CNY ${formatCents(line.priceCents)}',
                                              ),
                                              trailing: Text(
                                                'CNY ${formatCents(line.quantity * line.priceCents)}',
                                              ),
                                            ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                                FilledButton(
                                  onPressed: busy || !fresh
                                      ? null
                                      : () => unawaited(prepare()),
                                  child: Text(t('tableCheckoutPrepare')),
                                ),
                              ],
                            ],
                            if (original != null) ...[
                              Text(
                                label(original.accountType ?? original.channel),
                              ),
                              Text('CNY ${formatCents(original.totalCents)}'),
                              if (result?.settled == true &&
                                  widget.auth.session?.permissions.contains(
                                        'orders.read',
                                      ) ==
                                      true)
                                OutlinedButton(
                                  key: const ValueKey(
                                    'checkout-settled-receipt',
                                  ),
                                  onPressed: busy || !foreground
                                      ? null
                                      : openReceipt,
                                  child: Text(t('tableReceiptTitle')),
                                ),
                              if (result?.resolved != true)
                                SelectableText(original.requestId),
                              if (result?.settled != true && !cancelled) ...[
                                OutlinedButton(
                                  onPressed: busy
                                      ? null
                                      : () => unawaited(
                                          cancelOriginal(queryOnly: true),
                                        ),
                                  child: Text(t('tableCheckoutCancelQuery')),
                                ),
                                OutlinedButton(
                                  onPressed: busy
                                      ? null
                                      : () => unawaited(queryAdmission()),
                                  child: Text(t('tableCheckoutQuery')),
                                ),
                                if (!cancellationNeedsQuery &&
                                    (admission == null ||
                                        admission?.observed == false)) ...[
                                  OutlinedButton(
                                    onPressed: busy
                                        ? null
                                        : () => unawaited(prepare(retry: true)),
                                    child: Text(t('tableCheckoutRetryPrepare')),
                                  ),
                                ],
                                if(result?.canCloseUnpaid==true&&command?.channel=='alipay')
                                  OutlinedButton(onPressed:busy?null:()=>unawaited(collect(close:true)),child:Text(t('provider_close_attempt'))),
                                if (admission?.observed == true) ...[
                                  OutlinedButton(
                                    onPressed: busy
                                        ? null
                                        : () =>
                                              unawaited(collect(recover: true)),
                                    child: Text(t('tableCheckoutRecover')),
                                  ),
                                  if (admission?.paymentStatus ==
                                      'prepared') ...[
                                    OutlinedButton(
                                      onPressed: busy
                                          ? null
                                          : () => unawaited(cancelOriginal()),
                                      child: Text(t('tableCheckoutCancel')),
                                    ),
                                    if (original.channel != 'cash')
                                      PaymentCodeField(
                                        controller: input,
                                        enabled: !busy,
                                        label: t('tableCheckoutCode'),
                                      )
                                    else
                                      TextField(
                                        controller: input,
                                        enabled: !busy,
                                        obscureText: original.channel != 'cash',
                                        enableSuggestions: false,
                                        autocorrect: false,
                                        enableIMEPersonalizedLearning: false,
                                        keyboardType: original.channel == 'cash'
                                            ? const TextInputType.numberWithOptions(
                                                decimal: true,
                                              )
                                            : TextInputType.visiblePassword,
                                        decoration: InputDecoration(
                                          labelText: t(
                                            original.channel == 'cash'
                                                ? 'cashReceived'
                                                : 'tableCheckoutCode',
                                          ),
                                        ),
                                      ),
                                    FilledButton(
                                      onPressed: busy
                                          ? null
                                          : () => unawaited(collect()),
                                      child: Text(t('tableCheckoutCollect')),
                                    ),
                                  ],
                                ],
                              ],
                            ],
                            if (message.isNotEmpty) Text(message),
                          ],
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
