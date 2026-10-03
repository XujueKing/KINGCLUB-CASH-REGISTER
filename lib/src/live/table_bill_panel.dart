import 'bill_product_group.dart';
import 'workspace_read_cache.dart';
import 'bill_product_card.dart';
import 'bill_details_dialog.dart';
import 'bill_serving_dialog.dart';
import 'bill_item_return_dialog.dart';
import 'catalog_snapshot.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../network/ccsop_client.dart';
import '../strings.dart';
import 'order_snapshot.dart';
import 'table_checkout_dialog.dart';
import 'table_snapshot.dart';

/// The server's table bill, separate from the local unsubmitted selection.
class TableBillPanel extends StatefulWidget {
  const TableBillPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.tableRef,
    required this.sessionRef,
    required this.revision,
    this.checkoutAllowed = true,
    this.recording = false,
    this.changesAllowed = true,
    this.fillHeight = false,
    this.leading,
    this.draftCents = 0,
    this.headerBuilder,
    this.onAddProduct,
    this.draftCards = const {},
    this.onQuickAddProduct,
    this.orderAction,
    this.primaryAction,
    this.beforeActions,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef, sessionRef;
  final int revision;
  final bool checkoutAllowed, fillHeight, recording;
  final bool changesAllowed;
  final Widget? leading;
  final Widget? orderAction, primaryAction, beforeActions;
  final int draftCents;
  final Widget Function(Widget filter)? headerBuilder;
  final Future<void> Function(String productRef)? onAddProduct;
  final Map<String, BillProductCard> draftCards;
  final Future<void> Function(String productRef)? onQuickAddProduct;
  @override
  State<TableBillPanel> createState() => _TableBillPanelState();
}

class _TableBillPanelState extends State<TableBillPanel>
    with WidgetsBindingObserver {
  List<LiveOrder> orders = [];
  String filter = 'all';
  OrderSnapshot? snapshot;
  bool loading = false, failed = false, foreground = true, checkout = false;
  bool reducing = false;
  bool verifiedSnapshot = false;
  final queuedReductions = <String>[];
  int epoch = 0;
  final inventory = <String, CatalogProduct>{};
  String t(String key) => tr(widget.language, key);
  bool get canRead =>
      widget.auth.session?.permissions.contains('orders.read') == true;
  @override
  void initState() {
    super.initState();
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(reset);
    restoreDisplayCache();
    unawaited(load());
  }

  void restoreDisplayCache() {
    if (foreground && canRead) {
      final cached =
          WorkspaceReadCache.read<
            ({OrderSnapshot snapshot, List<LiveOrder> orders})
          >(
            widget.auth.session,
            'bill/${widget.tableRef}/${widget.sessionRef}',
          );
      if (cached != null) {
        snapshot = cached.snapshot;
        orders = List.of(cached.orders);
      }
    }
  }

  void reset({bool useCache = false}) {
    epoch++;
    activeRead = null;
    queuedReductions.clear();
    verifiedSnapshot = false;
    setState(() {
      orders = [];
      snapshot = null;
      loading = false;
      failed = false;
      if (useCache) restoreDisplayCache();
      inventory.clear();
    });
    if (foreground) {
      unawaited(load());
    }
  }

  @override
  void didUpdateWidget(covariant TableBillPanel old) {
    super.didUpdateWidget(old);
    if (widget.draftCents > old.draftCents && filter == 'paid') {
      filter = 'pending';
    }
    if (old.auth != widget.auth) {
      old.auth.removeListener(reset);
      widget.auth.addListener(reset);
    }
    if (old.auth != widget.auth ||
        old.tableRef != widget.tableRef ||
        old.sessionRef != widget.sessionRef) {
      reset(useCache: old.auth == widget.auth);
    } else if (old.revision != widget.revision && foreground) {
      unawaited(load());
    } else if (old.onQuickAddProduct == null &&
        widget.onQuickAddProduct != null &&
        !loading &&
        inventory.isEmpty) {
      unawaited(loadInventory(epoch));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    reset();
  }

  Future<void>? activeRead;
  Future<void> load({bool more = false, bool fresh = false}) async {
    final previous = activeRead;
    if (previous != null) {
      await previous;
      if (!fresh || !mounted) return;
    }
    final work = readBill(more: more);
    activeRead = work;
    try {
      await work;
    } finally {
      if (identical(activeRead, work)) activeRead = null;
    }
  }

  Future<void> readBill({bool more = false}) async {
    if (!mounted ||
        !foreground ||
        !canRead ||
        (more && (loading || snapshot?.nextAfterOrder == null))) {
      return;
    }
    final ticket = ++epoch, identity = widget.auth.session;
    final cursor = more ? snapshot?.nextAfterOrder : null;
    final previous = more ? List<LiveOrder>.of(orders) : <LiveOrder>[];
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      var after = cursor;
      final collected = List<LiveOrder>.of(previous);
      OrderSnapshot? next;
      do {
        final raw = await widget.auth.readOrders(
          tableRef: widget.tableRef,
          sessionRef: widget.sessionRef,
          afterOrder: after,
        );
        if (!mounted ||
            ticket != epoch ||
            !foreground ||
            !identical(identity, widget.auth.session)) {
          return;
        }
        next = OrderSnapshot.parse(
          raw,
          storeRef: identity!.storeRef,
          tableRef: widget.tableRef,
          sessionRef: widget.sessionRef,
          afterOrder: after,
        );
        collected.addAll(next.orders);
        after = next.nextAfterOrder;
      } while (after != null);
      WorkspaceReadCache.put(
        identity,
        'bill/${widget.tableRef}/${widget.sessionRef}',
        (snapshot: next, orders: List<LiveOrder>.unmodifiable(collected)),
      );
      setState(() {
        orders = collected;
        snapshot = next;
        verifiedSnapshot = true;
        loading = false;
      });
      if (widget.onQuickAddProduct != null) unawaited(loadInventory(ticket));
    } catch (_) {
      if (mounted && ticket == epoch) {
        setState(() {
          failed = true;
          loading = false;
        });
      }
    }
  }

  Future<void> loadInventory(int ticket) async {
    try {
      final wanted = orders
          .expand((o) => o.items)
          .map((i) => i.productRef)
          .toSet();
      final found = <String, CatalogProduct>{};
      String? cursor;
      final seen = <String>{};
      while (wanted.isNotEmpty) {
        final page = await widget.auth.readCatalog(afterProduct: cursor);
        if (!mounted || ticket != epoch || !foreground) return;
        for (final product in page.products) {
          if (wanted.remove(product.reference)) {
            found[product.reference] = product;
          }
        }
        cursor = page.nextAfterProduct;
        if (cursor == null) break;
        if (!seen.add(cursor)) throw const FormatException();
      }
      if (mounted && ticket == epoch) {
        setState(() {
          inventory
            ..clear()
            ..addAll(found);
        });
      }
    } catch (_) {
      // Unknown stock leaves quick-add disabled; bill amounts remain readable.
    }
  }

  Future<void> pay() async {
    if (loading ||
        failed ||
        checkout ||
        !foreground ||
        !widget.checkoutAllowed ||
        reducing ||
        snapshot == null) {
      return;
    }
    final identity = widget.auth.session;
    final tableRef = widget.tableRef, sessionRef = widget.sessionRef;
    setState(() => checkout = true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) {
          if (!mounted ||
              !foreground ||
              tableRef != widget.tableRef ||
              sessionRef != widget.sessionRef ||
              !identical(identity, widget.auth.session)) {
            final route = ModalRoute.of(context);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted && route != null && route.isActive) {
                Navigator.of(context).removeRoute(route);
              }
            });
            return const SizedBox.shrink();
          }
          return TableCheckoutDialog(
            auth: widget.auth,
            language: widget.language,
            tableRef: tableRef,
            sessionRef: sessionRef,
          );
        },
      );
    } finally {
      if (mounted) {
        setState(() => checkout = false);
        if (foreground) {
          unawaited(load());
        }
      }
    }
  }

  @override
  void dispose() {
    epoch++;
    widget.auth.removeListener(reset);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool canReduce(BillProductGroup group) =>
      verifiedSnapshot &&
      !checkout &&
      widget.changesAllowed &&
      foreground &&
      widget.auth.session?.permissions.contains('orders.create') == true &&
      snapshot?.sessionStatus == 'open' &&
      group.active.any(
        (line) =>
            line.order.status == 'pending' &&
            line.item.servingKnown &&
            (line.item.remainingQuantity ?? 0) > 0,
      );

  Future<void> reduceGroup(
    BillProductGroup group, {
    bool retryConflict = true,
  }) async {
    if (failed || !canReduce(group)) return;
    if (reducing) {
      if (queuedReductions.length < 50) queuedReductions.add(group.productRef);
      return;
    }
    var succeeded = false;
    var stateConflict = false;
    final identity = widget.auth.session,
        table = widget.tableRef,
        session = widget.sessionRef;
    // Most recent unpaid addition first, keeping the original price on each order.
    final lines =
        group.active
            .where(
              (line) =>
                  line.order.status == 'pending' &&
                  line.item.servingKnown &&
                  (line.item.remainingQuantity ?? 0) > 0,
            )
            .toList()
          ..sort((a, b) => b.order.reference.compareTo(a.order.reference));
    final target = lines.first;
    setState(() => reducing = true);
    try {
      await widget.auth.reduceUnpaidItem(
        tableRef: table,
        sessionRef: session,
        orderRef: target.order.reference,
        productRef: target.item.productRef,
        expectedQuantity: target.item.quantity,
        expectedServedQuantity: target.item.servedQuantity!,
        expectedServingEpoch: target.item.servingEpoch,
        expectedTotalCents: target.order.totalCents,
      );
      succeeded = true;
    } catch (error) {
      stateConflict =
          retryConflict &&
          error is CcsopFailure &&
          error.code == 'ORDER_REDUCTION_STATE_CHANGED';
      if (!stateConflict &&
          mounted &&
          identical(identity, widget.auth.session) &&
          table == widget.tableRef &&
          session == widget.sessionRef) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                error is CcsopFailure &&
                        [
                          'ORDER_REDUCTION_PAYMENT_REVIEW',
                          'CASHIER_TABLE_CHECKOUT_IN_PROGRESS',
                        ].contains(error.code)
                    ? 'billReductionPaymentBusy'
                    : 'billReductionRefresh',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        await load(fresh: true);
        if (mounted) {
          setState(() => reducing = false);
          if (stateConflict &&
              !failed &&
              identical(identity, widget.auth.session) &&
              table == widget.tableRef &&
              session == widget.sessionRef) {
            final next = groupBillProducts(orders)
                .where((g) => g.productRef == group.productRef && canReduce(g))
                .firstOrNull;
            if (next != null) {
              unawaited(reduceGroup(next, retryConflict: false));
            } else {
              queuedReductions.clear();
            }
          } else if (!succeeded ||
              failed ||
              !identical(identity, widget.auth.session) ||
              table != widget.tableRef ||
              session != widget.sessionRef) {
            queuedReductions.clear();
          } else {
            while (queuedReductions.isNotEmpty) {
              final ref = queuedReductions.removeAt(0);
              final next = groupBillProducts(orders)
                  .where((g) => g.productRef == ref && canReduce(g))
                  .firstOrNull;
              if (next != null) {
                unawaited(reduceGroup(next));
                break;
              }
            }
          }
        }
      }
    }
  }

  Future<void> openGroup(BillProductGroup group) async {
    if (loading || failed || !foreground || reducing || checkout) return;
    final generation = epoch, identity = widget.auth.session;
    bool current() =>
        mounted &&
        foreground &&
        generation == epoch &&
        identical(identity, widget.auth.session) &&
        !loading &&
        !failed;
    bool canServe(LiveOrder order, OrderItem item) =>
        identity?.permissions.contains('orders.serve') == true &&
        order.refundQuantitiesKnown &&
        !order.fullyRefunded &&
        item.servingKnown &&
        item.remainingQuantity! > 0 &&
        {'open', 'clearing'}.contains(snapshot?.sessionStatus) &&
        (order.status == 'paid' ||
            (snapshot?.paymentTiming == 'postpay' &&
                order.status == 'pending'));
    bool canRecall(LiveOrder order, OrderItem item) =>
        identity?.permissions.contains('orders.serve') == true &&
        order.refundQuantitiesKnown &&
        !order.fullyRefunded &&
        item.servingKnown &&
        item.servedQuantity! > 0 &&
        item.servingEpoch != null &&
        item.servingEpoch! < 1000000 &&
        {'open', 'clearing'}.contains(snapshot?.sessionStatus) &&
        (order.status == 'paid' ||
            (snapshot?.paymentTiming == 'postpay' &&
                order.status == 'pending'));
    bool canReturnUnserved(LiveOrder order, OrderItem item) =>
        identity?.permissions.contains('orders.serve') == true &&
        identity?.permissions.contains('orders.create') == true &&
        order.refunds.isEmpty &&
        order.status == 'pending' &&
        snapshot?.paymentTiming == 'postpay' &&
        snapshot?.sessionStatus == 'open' &&
        item.servingKnown &&
        item.servingEpoch != null &&
        item.servingEpoch! < 1000000 &&
        (item.returnableUnservedQuantity ?? 0) > 0;
    final selected = await showDialog<BillDetailAction>(
      context: context,
      builder: (_) => BillDetailsDialog(
        group: group,
        language: widget.language,
        canServe: canServe,
        canRecall: canRecall,
        canReturnUnserved: canReturnUnserved,
      ),
    );
    if (!mounted || !current() || selected == null) return;
    if (selected.action == 'return' &&
        !selected.served &&
        canReturnUnserved(selected.order, selected.item)) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => BillItemReturnDialog(
          auth: widget.auth,
          language: widget.language,
          tableRef: widget.tableRef,
          sessionRef: widget.sessionRef,
          order: selected.order,
          item: selected.item,
          isCurrent: current,
          served: false,
        ),
      );
      if (mounted && foreground) await load();
      return;
    }
    final recall = selected.action == 'recall';
    if (recall && canRecall(selected.order, selected.item)) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(t('billRecall')),
          children: [
            SimpleDialogOption(
              key: const ValueKey('bill-recall-wait'),
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('billRecallWait')),
            ),
            ListTile(
              key: const ValueKey('bill-recall-return'),
              enabled:
                  selected.order.status == 'pending' &&
                  identity?.permissions.contains('orders.create') == true &&
                  identity?.permissions.contains('payment.refund') == true &&
                  snapshot?.sessionStatus == 'open',
              onTap:
                  selected.order.status == 'pending' &&
                      identity?.permissions.contains('orders.create') == true &&
                      identity?.permissions.contains('payment.refund') ==
                          true &&
                      snapshot?.sessionStatus == 'open'
                  ? () => Navigator.pop(context, false)
                  : null,
              title: Text(t('billRecallReturn')),
            ),
          ],
        ),
      );
      if (!mounted || !current() || choice == null) return;
      if (!choice) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => BillItemReturnDialog(
            auth: widget.auth,
            language: widget.language,
            tableRef: widget.tableRef,
            sessionRef: widget.sessionRef,
            order: selected.order,
            item: selected.item,
            isCurrent: current,
          ),
        );
        if (mounted && foreground) await load();
        return;
      }
    }
    if ((!recall &&
            selected.action == 'serve' &&
            canServe(selected.order, selected.item)) ||
        (recall && canRecall(selected.order, selected.item))) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => BillServingDialog(
          auth: widget.auth,
          language: widget.language,
          tableRef: widget.tableRef,
          sessionRef: widget.sessionRef,
          order: selected.order,
          item: selected.item,
          isCurrent: current,
          recall: recall,
        ),
      );
      if (mounted && foreground) await load();
    }
  }

  Widget status(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600),
    ),
  );
  Widget filterDropdown() => DropdownButton<String>(
    key: const ValueKey('bill-filter'),
    value: filter,
    underline: const SizedBox(),
    style: const TextStyle(fontSize: 12, color: Color(0xff203d32)),
    items: [
      for (final entry in {
        'all': 'billAllConsumption',
        'pending': 'tableBillUnpaid',
        'paid': 'tableBillPaid',
        'voucher': 'billVoucher',
        'gift': 'billGift',
      }.entries)
        DropdownMenuItem(value: entry.key, child: Text(t(entry.value))),
    ],
    onChanged: (value) {
      if (value != null) setState(() => filter = value);
    },
  );

  Widget amountLabel(String label) => Text.rich(
    TextSpan(
      text: t(label),
      children: const [
        TextSpan(
          text: ' (CNY)',
          style: TextStyle(fontSize: 10, color: Color(0xFF86918B)),
        ),
      ],
    ),
    style: const TextStyle(fontSize: 12),
  );

  Widget amount(String label, int cents, String key) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      key: ValueKey(key),
      children: [
        Expanded(child: amountLabel(label)),
        Text(
          formatCents(cents),
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final pending = snapshot?.sessionSummary?.buckets['pending'];
    final summary = snapshot?.sessionSummary;
    final paid = summary?.buckets['netPaid'] ?? summary?.buckets['paid'];
    final drafts = filter == 'all' || filter == 'pending'
        ? widget.draftCards
        : <String, BillProductCard>{};
    final visible = orders
        .where(
          (o) =>
              o.status != 'expired' && (filter == 'all' || o.status == filter),
        )
        .toList();
    final groups = groupBillProducts(visible);
    BillProductCard? draftFor(BillProductGroup group) =>
        group.currency == 'CNY' ? drafts[group.productRef] : null;
    final canPay = [
      'payment.cash',
      'payment.wechat',
      'payment.alipay',
      'payment.balance',
    ].any((p) => widget.auth.session?.permissions.contains(p) == true);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.leading != null && (filter == 'all' || filter == 'pending'))
          widget.leading!,
        for (final entry in drafts.entries)
          if (!groups.any(
            (g) => g.currency == 'CNY' && g.productRef == entry.key,
          ))
            entry.value,
        if (canRead) ...[
          if (loading && snapshot == null) Text(t('billFirstSync')),
          if (failed)
            TextButton(
              onPressed: () => unawaited(load()),
              child: Text(t('tableBillRetry')),
            ),
          if (filter == 'voucher' || filter == 'gift')
            Text(t('billSourceUnavailable'))
          else if (!loading && !failed && visible.isEmpty && drafts.isEmpty)
            Text(t('billNoItems')),
          for (final group in groups)
            BillProductCard(
              key: ValueKey('bill-group-${group.currency}-${group.productRef}'),
              language: widget.language,
              name: group.item.name(widget.language),
              specification: group.item.specification(widget.language),
              quantity: group.quantity + (draftFor(group)?.quantity ?? 0),
              priceCents: group.item.priceCents,
              priceLabel:
                  group.mixedPrices ||
                      (draftFor(group) != null &&
                          group.item.priceCents != draftFor(group)!.priceCents)
                  ? t('billMixedPrices')
                  : null,
              totalCents: group.totalCents + (draftFor(group)?.totalCents ?? 0),
              thumbnailPath: group.item.thumbnailPath,
              base: widget.auth.session?.base,
              onTap: () => openGroup(group),
              quantityControls: true,
              productRef: group.productRef,
              onMinus: !failed && !checkout
                  ? (draftFor(group) != null
                        ? draftFor(group)!.onMinus
                        : (canReduce(group) ? () => reduceGroup(group) : null))
                  : null,
              onPlus:
                  !failed &&
                      widget.onQuickAddProduct != null &&
                      (inventory[group.productRef]?.inventoryKnown ?? false) &&
                      group.unpaidQuantity + (draftFor(group)?.quantity ?? 0) <
                          inventory[group.productRef]!.available &&
                      (draftFor(group)?.quantity ?? 0) < 1000
                  ? (draftFor(group) != null
                        ? draftFor(group)!.onPlus
                        : () => widget.onQuickAddProduct!(group.productRef))
                  : null,
              badges: status(
                '${t('tableBillPaid')} ${group.paidQuantity} / ${t('tableBillUnpaid')} ${group.unpaidQuantity + (draftFor(group)?.quantity ?? 0)}',
                const Color(0xff216344),
              ),
              leadingBadge: group.quantity == 0
                  ? null
                  : !group.servingKnown
                  ? status(t('billProgressUnknown'), const Color(0xff666666))
                  : status(
                      '${t('billServed')} ${group.served} / ${t('billNotServed')} ${group.remaining}',
                      group.remaining == 0
                          ? const Color(0xff216344)
                          : const Color(0xff994a16),
                    ),
              footer: group.returned == 0 && draftFor(group)?.footer == null
                  ? null
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (group.returned > 0)
                          Text(
                            [
                              if (group.returned > 0)
                                '${t('tableBillRefunded')} ${group.returned}',
                            ].join(' · '),
                            style: const TextStyle(fontSize: 11),
                          ),
                        if (draftFor(group)?.footer != null)
                          draftFor(group)!.footer!,
                      ],
                    ),
            ),
          if (snapshot?.nextAfterOrder != null)
            TextButton(
              onPressed: loading ? null : () => unawaited(load(more: true)),
              child: Text(t('tableBillMore')),
            ),
        ],
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (canRead || widget.headerBuilder != null) ...[
          widget.headerBuilder?.call(
                canRead ? filterDropdown() : const SizedBox(),
              ) ??
              Align(alignment: Alignment.centerRight, child: filterDropdown()),
          const Divider(height: 14, thickness: 1, color: Color(0xffd7e2dc)),
        ],
        if (widget.fillHeight)
          Expanded(child: SingleChildScrollView(child: content))
        else
          content,
        if (canRead && pending != null && paid != null) ...[
          const Divider(height: 12, thickness: 1, color: Color(0xffd7e2dc)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  key: const ValueKey('table-bill-total'),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: amountLabel('billTotal'),
                    ),
                    Text(
                      formatCents(
                        paid.totalCents +
                            pending.totalCents +
                            widget.draftCents,
                      ),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  children: [
                    amount(
                      'billUnpaidAmount',
                      pending.totalCents + widget.draftCents,
                      'table-bill-pending',
                    ),
                    amount(
                      'billPaidAmount',
                      paid.totalCents,
                      'table-bill-paid',
                    ),
                  ],
                ),
              ),
            ],
          ),
          if ((summary?.buckets['refunded']?.totalCents ?? 0) > 0)
            amount(
              'tableBillRefunded',
              summary!.buckets['refunded']!.totalCents,
              'table-bill-refunded',
            ),
        ],
        if (widget.beforeActions != null) widget.beforeActions!,
        if (widget.orderAction != null ||
            widget.primaryAction != null ||
            (canRead && canPay))
          Row(
            children: [
              if (widget.orderAction != null)
                Expanded(flex: 2, child: widget.orderAction!),
              if (widget.orderAction != null &&
                  (widget.primaryAction != null || (canRead && canPay)))
                const SizedBox(width: 10),
              if (widget.primaryAction != null)
                Expanded(flex: 3, child: widget.primaryAction!)
              else if (canRead && canPay)
                Expanded(
                  flex: 3,
                  child: FilledButton(
                    key: const ValueKey('table-bill-checkout'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFDC2626),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor:
                          (pending?.totalCents ?? 0) > 0 || widget.recording
                          ? const Color(0xFFDC2626)
                          : null,
                      disabledForegroundColor:
                          (pending?.totalCents ?? 0) > 0 || widget.recording
                          ? Colors.white
                          : null,
                    ),
                    onPressed:
                        !loading &&
                            !failed &&
                            !checkout &&
                            widget.checkoutAllowed &&
                            !reducing &&
                            pending != null &&
                            pending.orderCount > 0 &&
                            pending.totalCents > 0
                        ? pay
                        : null,
                    child: Text(
                      pending != null &&
                              pending.totalCents == 0 &&
                              !widget.recording &&
                              !loading &&
                              !failed
                          ? t('billSettled')
                          : '${t('tableCheckoutTitle')}${pending != null && pending.totalCents > 0 ? ' ¥${formatCents(pending.totalCents)}' : ''}',
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
