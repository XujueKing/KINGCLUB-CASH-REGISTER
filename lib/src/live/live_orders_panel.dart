import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'order_snapshot.dart';
import 'order_preview_dialog.dart';
import 'receipt_document_dialog.dart';
import 'table_receipt_dialog.dart';
import 'table_checkout_dialog.dart';
import 'live_cash_recovery_panel.dart';
import 'live_serving_recovery_panel.dart';
import 'table_snapshot.dart';
import 'provider_payment_panel.dart';
import 'balance_refund_dialog.dart';

class LiveOrdersPanel extends StatefulWidget {
  const LiveOrdersPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.table,
    required this.onBack,
    required this.revision,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final LiveTable table;
  final VoidCallback onBack;
  final int revision;
  @override
  State<LiveOrdersPanel> createState() => _LiveOrdersPanelState();
}

class _LiveOrdersPanelState extends State<LiveOrdersPanel>
    with WidgetsBindingObserver {
  OrderSnapshot? data;
  final cursors = <String?>[null];
  int page = 0, epoch = 0;
  bool loading = false, failed = false, foreground = true, queued = false;
  Timer? debounce;
  bool get snapshotRefreshing => loading || queued;
  bool cashBusy = false, cashRecovery = false;
  bool servingRecovery = false;
  bool servingConfirming = false;
  BuildContext? cashDialog;
  BuildContext? previewDialog;
  bool previewOpening = false;
  bool tableCheckoutOpening = false;
  int checkoutScopeEpoch = 0;
  Future<void> openTableCheckout() async {
    final identity = widget.auth.session,
        snapshot = data,
        generation = checkoutScopeEpoch;
    if (!foreground ||
        snapshotRefreshing ||
        cashBusy ||
        previewOpening ||
        snapshot == null ||
        identity == null) {
      return;
    }
    previewOpening = true;
    tableCheckoutOpening = true;
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          previewDialog = ctx;
          if (!mounted ||
              !foreground ||
              checkoutScopeEpoch != generation ||
              !identical(identity, widget.auth.session)) {
            return discardStaleConfirmation(ctx);
          }
          return TableCheckoutDialog(
            auth: widget.auth,
            tableRef: widget.table.reference,
            sessionRef: widget.table.session!.reference,
            language: widget.language,
          );
        },
      );
    } finally {
      previewDialog = null;
      previewOpening = false;
      tableCheckoutOpening = false;
      if (mounted && foreground) await load(reset: true);
    }
  }

  Future<void> openBalanceRefund(LiveOrder order) async {
    final identity = widget.auth.session, generation = epoch;
    if (!foreground ||
        snapshotRefreshing ||
        cashBusy ||
        previewOpening ||
        data?.orders.contains(order) != true ||
        identity == null ||
        !identity.expiresAt.isAfter(DateTime.now())) {
      return;
    }
    previewOpening = true;
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          previewDialog = ctx;
          if (!mounted ||
              !foreground ||
              epoch != generation ||
              !identical(identity, widget.auth.session)) {
            return discardStaleConfirmation(ctx);
          }
          return BalanceRefundDialog(
            auth: widget.auth,
            orderRef: order.reference,
            language: widget.language,
          );
        },
      );
    } finally {
      previewDialog = null;
      previewOpening = false;
      if (mounted && foreground) await load(reset: true);
    }
  }

  Widget discardStaleConfirmation(BuildContext context) {
    final route = ModalRoute.of(context);
    // The invalidation may precede the dialog builder, before cashDialog exists.
    // Never build old order content; remove only this route after build unlocks.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.mounted && route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
    return const SizedBox.shrink();
  }

  Future<void> previewOrder(
    LiveOrder order, {
    bool receiptDocument = false,
    bool tableReceipt = false,
  }) async {
    final snapshot = data, identity = widget.auth.session;
    if (!foreground ||
        snapshotRefreshing ||
        cashBusy ||
        previewOpening ||
        snapshot == null ||
        !snapshot.orders.contains(order) ||
        identity == null ||
        !identity.expiresAt.isAfter(DateTime.now())) {
      return;
    }
    final generation = epoch;
    previewOpening = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          previewDialog = ctx;
          if (receiptDocument || tableReceipt) {
            if (!mounted ||
                !foreground ||
                epoch != generation ||
                !identical(identity, widget.auth.session)) {
              return discardStaleConfirmation(ctx);
            }
            if (tableReceipt) {
              final checkout = order.tableCheckoutRef;
              if (checkout == null || order.status != 'paid') {
                return discardStaleConfirmation(ctx);
              }
              return TableReceiptDialog(
                auth: widget.auth,
                checkoutRef: checkout,
                tableRef: widget.table.reference,
                sessionRef: widget.table.session!.reference,
                language: widget.language,
              );
            }
            return ReceiptDocumentDialog(
              auth: widget.auth,
              orderRef: order.reference,
              tableRef: widget.table.reference,
              sessionRef: widget.table.session!.reference,
              language: widget.language,
            );
          }
          return OrderPreviewDialog(
            auth: widget.auth,
            order: order,
            language: widget.language,
            observedAt: snapshot.observedAt,
            expiresAt: mounted && foreground && epoch == generation
                ? identity.expiresAt
                : DateTime.fromMillisecondsSinceEpoch(0),
          );
        },
      );
    } finally {
      previewDialog = null;
      previewOpening = false;
    }
  }

  void closeCashDialog() {
    final preview = previewDialog;
    if (preview != null &&
        preview.mounted &&
        ModalRoute.of(preview)?.isCurrent == true) {
      Navigator.of(preview).pop();
    }
    final ctx = cashDialog;
    if (ctx != null && ctx.mounted && ModalRoute.of(ctx)?.isCurrent == true) {
      Navigator.of(ctx).pop();
    }
  }

  bool cashEligible(LiveOrder order) =>
      foreground &&
      widget.auth.session?.permissions.contains('payment.cash') == true &&
      {'open', 'clearing'}.contains(data?.sessionStatus) &&
      order.cashierOrder &&
      order.status == 'pending' &&
      order.currency == 'CNY' &&
      order.totalCents <= 100000000 &&
      RegExp(r'^D[0-9]{11}$').hasMatch(order.reference);

  Future<void> prepareCash(LiveOrder order) async {
    if (cashBusy || snapshotRefreshing || !cashEligible(order)) return;
    final generation = epoch,
        auth = widget.auth,
        identity = widget.auth.session;
    bool current() =>
        mounted &&
        foreground &&
        epoch == generation &&
        identical(auth, widget.auth) &&
        identical(identity, auth.session);
    setState(() => cashBusy = true);
    var attempted = false;
    try {
      final pending = await auth.pendingCash();
      if (!mounted || !current()) return;
      if (pending.any((entry) => entry.orderRef == order.reference)) {
        setState(() => cashRecovery = true);
        return;
      }
      final approved = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          cashDialog = ctx;
          if (!current()) return discardStaleConfirmation(ctx);
          return AlertDialog(
            title: Text(t('cashPrepare')),
            content: SingleChildScrollView(
              child: Text(
                '${order.reference}\nCNY ${formatCents(order.totalCents)}\n\n${t('cashPrepareNotice')}',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(t('cashPrepareCancel')),
              ),
              FilledButton(
                key: const ValueKey('cash-prepare-confirm'),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(t('cashPrepare')),
              ),
            ],
          );
        },
      );
      cashDialog = null;
      if (!current() || approved != true || !cashEligible(order)) return;
      // Controller persists the original request before sending. Never retry here.
      attempted = true;
      await auth.prepareCash(
        orderRef: order.reference,
        totalCents: order.totalCents,
        confirmed: true,
      );
      if (current()) setState(() => cashRecovery = true);
    } catch (_) {
      // Includes ambiguous transport outcomes; recovery reads durable requests first.
      if (current()) {
        setState(() {
          cashRecovery = attempted;
          failed = !attempted;
          if (!attempted) data = null;
        });
      }
    } finally {
      cashDialog = null;
      if (mounted) {
        setState(() => cashBusy = false);
        if (foreground && epoch != generation && !cashRecovery) {
          unawaited(load(reset: true));
        }
      }
    }
  }

  bool servingEligible(LiveOrder order, OrderItem item) =>
      foreground &&
      widget.auth.session?.permissions.contains('orders.serve') == true &&
      order.refunds.isEmpty &&
      {'open', 'clearing'}.contains(data?.sessionStatus) &&
      item.servingKnown &&
      item.remainingQuantity! > 0 &&
      (order.status == 'paid' ||
          (data?.paymentTiming == 'postpay' &&
              order.status == 'pending' &&
              order.cashierOrder));

  Future<void> confirmServing(LiveOrder order, OrderItem item) async {
    if (cashBusy || snapshotRefreshing || !servingEligible(order, item)) return;
    final generation = epoch,
        auth = widget.auth,
        identity = widget.auth.session;
    bool current() =>
        mounted &&
        foreground &&
        epoch == generation &&
        identical(auth, widget.auth) &&
        identical(identity, auth.session);
    setState(() => cashBusy = true);
    var attempted = false;
    try {
      final pending = await auth.pendingServing();
      if (!mounted || !current()) return;
      if (pending.any(
        (e) => e.orderRef == order.reference && e.productRef == item.productRef,
      )) {
        setState(() => servingRecovery = true);
        return;
      }
      var text = '';
      setState(() => servingConfirming = true);
      final delivered = await showDialog<int>(
        context: context,
        builder: (ctx) {
          cashDialog = ctx;
          if (!current()) return discardStaleConfirmation(ctx);
          return StatefulBuilder(
            builder: (ctx, update) {
              if (!current()) return discardStaleConfirmation(ctx);
              final count = RegExp(r'^[1-9][0-9]{0,3}$').hasMatch(text)
                  ? int.tryParse(text)
                  : null;
              final valid = count != null && count <= item.remainingQuantity!;
              return AlertDialog(
                title: Text(t('servingConfirm')),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${item.name(widget.language)} · ${item.specification(widget.language)}\n${t('servingDelivered')}: ${item.servedQuantity} · ${t('servingRemaining')}: ${item.remainingQuantity}',
                      ),
                      Text(t('servingConfirmNotice')),
                      TextField(
                        key: const ValueKey('serving-quantity'),
                        keyboardType: TextInputType.number,
                        onChanged: (value) => update(() => text = value),
                        decoration: InputDecoration(
                          labelText: t('servingThisQuantity'),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text(t('cashPrepareCancel')),
                  ),
                  FilledButton(
                    key: const ValueKey('serving-confirm-submit'),
                    onPressed: valid
                        ? () => Navigator.of(ctx).pop(count)
                        : null,
                    child: Text(t('servingConfirm')),
                  ),
                ],
              );
            },
          );
        },
      );
      cashDialog = null;
      if (mounted) setState(() => servingConfirming = false);
      if (!current() || delivered == null || !servingEligible(order, item)) {
        return;
      }
      attempted = true;
      await auth.confirmServing(
        tableRef: widget.table.reference,
        sessionRef: widget.table.session!.reference,
        orderRef: order.reference,
        productRef: item.productRef,
        quantity: item.quantity,
        expectedServedQuantity: item.servedQuantity!,
        targetServedQuantity: item.servedQuantity! + delivered,
        expectedServingEpoch: item.servingEpoch,
        confirmed: true,
      );
      if (current()) {
        setState(() => data = null);
      }
    } catch (_) {
      if (current()) {
        setState(() {
          if (attempted) {
            servingRecovery = true;
          } else {
            failed = true;
            data = null;
          }
        });
      }
    } finally {
      cashDialog = null;
      if (mounted) {
        setState(() {
          cashBusy = false;
          servingConfirming = false;
        });
        if (foreground && !servingRecovery) unawaited(load(reset: true));
      }
    }
  }

  String t(String key) => tr(widget.language, key);
  @override
  void initState() {
    super.initState();
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(authChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && foreground) unawaited(load());
    });
  }

  void authChanged() {
    ++checkoutScopeEpoch;
    ++epoch;
    closeCashDialog();
    if (mounted) {
      setState(() {
        data = null;
        loading = false;
        failed = true;
        cashRecovery = false;
        servingRecovery = false;
      });
    }
  }

  @override
  void didUpdateWidget(covariant LiveOrdersPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.auth, widget.auth)) {
      oldWidget.auth.removeListener(authChanged);
      widget.auth.addListener(authChanged);
      authChanged();
    }
    final scopeChanged =
        oldWidget.table.reference != widget.table.reference ||
        oldWidget.table.session?.reference != widget.table.session?.reference;
    if (scopeChanged) ++checkoutScopeEpoch;
    if (oldWidget.revision != widget.revision || scopeChanged) {
      ++epoch;
      // A store-wide event may be our own payment confirmation. Keep the
      // original checkout route; each command is revalidated by the server.
      if (scopeChanged || !tableCheckoutOpening) closeCashDialog();
      if (scopeChanged) data = null;
      loading = false;
      schedule();
    }
  }

  void schedule() {
    if (!foreground) return;
    queued = true;
    debounce ??= Timer(const Duration(milliseconds: 400), () {
      debounce = null;
      if (!mounted || !foreground || loading || cashBusy) return;
      queued = false;
      unawaited(load(reset: true));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      unawaited(load(reset: true));
    } else {
      ++checkoutScopeEpoch;
      ++epoch;
      closeCashDialog();
      debounce?.cancel();
      debounce = null;
      queued = false;
      setState(() {
        data = null;
        loading = false;
      });
    }
  }

  Future<void> load({int? target, bool reset = false}) async {
    if (!mounted || !foreground || cashBusy) return;
    final generation = ++epoch, session = widget.auth.session;
    if (session == null) {
      authChanged();
      return;
    }
    final previousPage = page;
    if (reset) {
      cursors
        ..clear()
        ..add(null);
      page = 0;
    }
    final requested = target ?? page, cursor = cursors[target ?? page];
    setState(() {
      loading = true;
      failed = false;
      if (requested != previousPage) data = null;
    });
    try {
      final raw = await widget.auth.readOrders(
        tableRef: widget.table.reference,
        sessionRef: widget.table.session!.reference,
        afterOrder: cursor,
      );
      if (!mounted ||
          epoch != generation ||
          !identical(session, widget.auth.session)) {
        return;
      }
      final result = OrderSnapshot.parse(
        raw,
        storeRef: session.storeRef,
        tableRef: widget.table.reference,
        sessionRef: widget.table.session!.reference,
        afterOrder: cursor,
      );
      if (result.nextAfterOrder != null &&
          cursors.take(requested + 1).contains(result.nextAfterOrder)) {
        throw const FormatException();
      }
      setState(() {
        data = result;
        page = requested;
        loading = false;
      });
    } catch (_) {
      if (mounted && epoch == generation) {
        setState(() {
          data = null;
          failed = true;
          loading = false;
        });
      }
    } finally {
      if (mounted && epoch == generation && queued) schedule();
    }
  }

  @override
  void dispose() {
    ++checkoutScopeEpoch;
    ++epoch;
    debounce?.cancel();
    widget.auth.removeListener(authChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => servingRecovery
      ? LiveServingRecoveryPanel(
          auth: widget.auth,
          language: widget.language,
          onBack: () {
            setState(() => servingRecovery = false);
            unawaited(load(reset: true));
          },
        )
      : cashRecovery
      ? LiveCashRecoveryPanel(
          auth: widget.auth,
          language: widget.language,
          onBack: () {
            setState(() => cashRecovery = false);
            unawaited(load(reset: true));
          },
        )
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                spacing: 20,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: cashBusy ? null : widget.onBack,
                    child: Text(t('ordersBack')),
                  ),
                  Text('${widget.table.name} · ${t('ordersDetails')}'),
                  Tooltip(
                    message:
                        '${t('ordersSnapshotNotice')}\n${t('servingProgressNotice')}'
                        '${data == null ? '' : '\n${t('liveObserved')}: ${data!.observedAt.toLocal()}'}',
                    triggerMode: TooltipTriggerMode.tap,
                    child: const Padding(
                      padding: EdgeInsets.all(10),
                      child: Icon(Icons.info_outline, size: 20),
                    ),
                  ),
                  if ([
                    'payment.wechat',
                    'payment.alipay',
                    'payment.cash',
                    'payment.balance',
                  ].any(
                    (permission) =>
                        widget.auth.session?.permissions.contains(permission) ==
                        true,
                  ))
                    OutlinedButton(
                      key: const ValueKey('table-checkout-open'),
                      onPressed:
                          cashBusy ||
                              snapshotRefreshing ||
                              !foreground ||
                              previewOpening ||
                              data == null
                          ? null
                          : () => unawaited(openTableCheckout()),
                      child: Text(t('tableCheckoutTitle')),
                    ),
                  if (widget.auth.session?.permissions.contains(
                        'orders.serve',
                      ) ==
                      true)
                    OutlinedButton(
                      onPressed: cashBusy || snapshotRefreshing
                          ? null
                          : () => setState(() => servingRecovery = true),
                      child: Text(t('servingRecoveryTitle')),
                    ),
                  OutlinedButton(
                    key: const ValueKey('orders-refresh'),
                    onPressed: snapshotRefreshing || cashBusy
                        ? null
                        : () => unawaited(load(reset: true)),
                    child: Text(t('ordersRefresh')),
                  ),
                ],
              ),
            ),
            if (data != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 4,
                ),
                child: data!.sessionSummary == null
                    ? Text(t('sessionSummaryUnknown'))
                    : Wrap(
                        spacing: 20,
                        runSpacing: 4,
                        children: [
                          Text(t('sessionSummaryTitle')),
                          for (final status in ['paid', 'pending', 'expired'])
                            Text(
                              '${t(status == 'paid' ? 'grossCollected' : 'order_$status')}: ${data!.sessionSummary!.buckets[status]!.orderCount} · ${data!.sessionSummary!.currency} ${formatCents(data!.sessionSummary!.buckets[status]!.totalCents)}',
                            ),
                          for (final key in ['refunded', 'netPaid'])
                            if (data!.sessionSummary!.buckets.containsKey(key))
                              Text(
                                '${t(key == 'refunded' ? 'liveRefunded' : 'livePaid')}: ${data!.sessionSummary!.buckets[key]!.orderCount} · ${data!.sessionSummary!.currency} ${formatCents(data!.sessionSummary!.buckets[key]!.totalCents)}',
                              ),
                        ],
                      ),
              ),
            if (snapshotRefreshing || (cashBusy && !servingConfirming))
              const LinearProgressIndicator(),
            Expanded(
              child: failed
                  ? Center(child: Text(t('liveReadFailed')))
                  : data == null
                  ? const SizedBox()
                  : data!.orders.isEmpty
                  ? Center(child: Text(t('ordersEmpty')))
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      itemCount: data!.orders.length,
                      itemBuilder: (context, index) {
                        final order = data!.orders[index];
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '${order.reference} · ${t(order.fullyRefunded ? 'liveRefunded' : 'order_${order.status}')} · ${order.currency} ${formatCents(order.totalCents)}',
                                          ),
                                          Text('${order.createdAt.toLocal()}'),
                                        ],
                                      ),
                                    ),
                                    Align(
                                      alignment: Alignment.centerRight,
                                      child: OutlinedButton(
                                        key: ValueKey(
                                          'order-preview-${order.reference}',
                                        ),
                                        onPressed:
                                            cashBusy ||
                                                snapshotRefreshing ||
                                                !foreground
                                            ? null
                                            : () => unawaited(
                                                previewOrder(order),
                                              ),
                                        child: Text(t('orderPreviewTitle')),
                                      ),
                                    ),
                                  ],
                                ),
                                if (const bool.fromEnvironment(
                                      'CASHIER_BALANCE_REFUND',
                                      defaultValue: false,
                                    ) &&
                                    order.cashierOrder &&
                                    order.status == 'paid' &&
                                    widget.auth.session?.permissions.contains(
                                          'payment.refund',
                                        ) ==
                                        true)
                                  OutlinedButton(
                                    onPressed:
                                        foreground &&
                                            !snapshotRefreshing &&
                                            !cashBusy &&
                                            !previewOpening
                                        ? () => unawaited(
                                            openBalanceRefund(order),
                                          )
                                        : null,
                                    child: Text(t('refundTitle')),
                                  ),
                                for (final refund in order.refunds) ...[
                                  Text(
                                    '${t('refundPrincipal')}: ${order.currency} ${formatCents(refund.principalCents)} · ${t('refundGift')}: ${order.currency} ${formatCents(refund.giftCents)}',
                                  ),
                                  Text(
                                    '${t('liveRefunded')}: ${refund.refundedAt.toLocal()}',
                                  ),
                                ],
                                if (widget.auth.session?.permissions.contains(
                                          'orders.read',
                                        ) ==
                                        true &&
                                    order.cashierOrder &&
                                    order.status == 'paid' &&
                                    order.tableCheckoutRef == null)
                                  OutlinedButton(
                                    key: ValueKey(
                                      'receipt-document-${order.reference}',
                                    ),
                                    onPressed:
                                        cashBusy ||
                                            snapshotRefreshing ||
                                            !foreground ||
                                            previewOpening
                                        ? null
                                        : () => unawaited(
                                            previewOrder(
                                              order,
                                              receiptDocument: true,
                                            ),
                                          ),
                                    child: Text(t('receiptDocumentTitle')),
                                  ),
                                if (widget.auth.session?.permissions.contains(
                                          'orders.read',
                                        ) ==
                                        true &&
                                    order.tableCheckoutRef != null &&
                                    order.status == 'paid')
                                  OutlinedButton(
                                    key: ValueKey(
                                      'table-receipt-${order.reference}',
                                    ),
                                    onPressed:
                                        cashBusy ||
                                            snapshotRefreshing ||
                                            !foreground ||
                                            previewOpening
                                        ? null
                                        : () => unawaited(
                                            previewOrder(
                                              order,
                                              tableReceipt: true,
                                            ),
                                          ),
                                    child: Text(t('tableReceiptTitle')),
                                  ),
                                if ([
                                  'payment.wechat',
                                  'payment.alipay',
                                  'payment.balance',
                                ].any(
                                  (permission) =>
                                      widget.auth.session?.permissions.contains(
                                        permission,
                                      ) ==
                                      true,
                                ))
                                  if (order.cashierOrder &&
                                      foreground &&
                                      !snapshotRefreshing &&
                                      !cashBusy &&
                                      {
                                        'open',
                                        'clearing',
                                      }.contains(data?.sessionStatus) &&
                                      order.status == 'pending' &&
                                      order.currency == 'CNY')
                                    ProviderPaymentPanel(
                                      key: ValueKey(
                                        'provider-${order.reference}-$epoch',
                                      ),
                                      auth: widget.auth,
                                      orderRef: order.reference,
                                      totalCents: order.totalCents,
                                      language: widget.language,
                                    ),
                                if (cashEligible(order))
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: OutlinedButton(
                                      key: ValueKey(
                                        'cash-prepare-${order.reference}',
                                      ),
                                      onPressed: cashBusy || snapshotRefreshing
                                          ? null
                                          : () => unawaited(prepareCash(order)),
                                      child: Text(t('cashPrepare')),
                                    ),
                                  ),
                                for (final item in order.items)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${item.name(widget.language)} · ${item.specification(widget.language)} · ${item.quantity} × ${formatCents(item.priceCents)} = ${formatCents(item.subtotalCents)}',
                                        ),
                                        Text(
                                          item.servingKnown
                                              ? order.status == 'expired' ||
                                                        order.fullyRefunded
                                                    ? '${t('servingDelivered')}: ${item.servedQuantity}'
                                                    : '${t('servingDelivered')}: ${item.servedQuantity} · ${t('servingRemaining')}: ${item.remainingQuantity}'
                                              : t('servingUnknown'),
                                          key: ValueKey(
                                            'serving-progress-${order.reference}-${item.productRef}',
                                          ),
                                        ),
                                        if (servingEligible(order, item))
                                          OutlinedButton(
                                            key: ValueKey(
                                              'serving-open-${order.reference}-${item.productRef}',
                                            ),
                                            onPressed:
                                                cashBusy || snapshotRefreshing
                                                ? null
                                                : () => unawaited(
                                                    confirmServing(order, item),
                                                  ),
                                            child: Text(t('servingConfirm')),
                                          ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 20,
                children: [
                  OutlinedButton(
                    onPressed: snapshotRefreshing || cashBusy || page == 0
                        ? null
                        : () => unawaited(load(target: page - 1)),
                    child: Text(t('livePrevious')),
                  ),
                  Text('${t('livePage')} ${page + 1}'),
                  OutlinedButton(
                    onPressed:
                        snapshotRefreshing ||
                            cashBusy ||
                            data?.nextAfterOrder == null
                        ? null
                        : () {
                            cursors.removeRange(page + 1, cursors.length);
                            cursors.add(data!.nextAfterOrder);
                            unawaited(load(target: page + 1));
                          },
                    child: Text(t('liveNext')),
                  ),
                ],
              ),
            ),
          ],
        );
}
