import 'bill_product_group.dart';
import 'workspace_read_cache.dart';
import 'bill_product_card.dart';
import 'balance_refund_dialog.dart';
import 'bill_serving_dialog.dart';
import 'catalog_snapshot.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
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
    this.fillHeight = false,
    this.leading,
    this.draftCents = 0,
    this.headerBuilder,
    this.onAddProduct,
    this.draftCards = const {},
    this.onQuickAddProduct,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef, sessionRef;
  final int revision;
  final bool checkoutAllowed, fillHeight;
  final Widget? leading;
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

  Future<void> load({bool more = false}) async {
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
      inventory.clear();
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
      if (mounted && ticket == epoch) setState(() => inventory.addAll(found));
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

  Future<void> openGroup(BillProductGroup group) async {
    if (loading || failed || !foreground) return;
    final generation = epoch, identity = widget.auth.session;
    if (group.lines.length == 1) {
      return openItem(group.lines.single.order, group.lines.single.item);
    }
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(t('billChooseOriginal')),
        children: [
          if (widget.onAddProduct != null)
            SimpleDialogOption(
              key: const ValueKey('bill-add-product'),
              onPressed: () => Navigator.pop(context, -1),
              child: Text(t('billAddOrder')),
            ),
          for (var i = 0; i < group.lines.length; i++)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, i),
              child: Text(
                '${group.lines[i].item.quantity} × ${formatCents(group.lines[i].item.priceCents)} · '
                '${t(group.lines[i].order.refund != null
                    ? 'tableBillRefunded'
                    : group.lines[i].order.status == 'paid'
                    ? 'tableBillPaid'
                    : 'tableBillUnpaid')} · '
                '${group.lines[i].order.createdAt.toLocal()}',
              ),
            ),
        ],
      ),
    );
    if (!mounted ||
        !foreground ||
        generation != epoch ||
        !identical(identity, widget.auth.session) ||
        loading ||
        failed) {
      return;
    }
    if (selected == -1) {
      await widget.onAddProduct?.call(group.productRef);
      return;
    }
    if (selected != null) {
      await openItem(group.lines[selected].order, group.lines[selected].item);
    }
  }

  Future<void> openItem(LiveOrder order, OrderItem item) async {
    if (loading || failed || !foreground) return;
    final generation = epoch, identity = widget.auth.session;
    final canServe =
        identity?.permissions.contains('orders.serve') == true &&
        order.refund == null &&
        item.servingKnown &&
        item.remainingQuantity! > 0 &&
        {'open', 'clearing'}.contains(snapshot?.sessionStatus) &&
        (order.status == 'paid' ||
            (snapshot?.paymentTiming == 'postpay' &&
                order.status == 'pending' &&
                order.cashierOrder));
    final canRefund =
        const bool.fromEnvironment('CASHIER_BALANCE_REFUND') &&
        widget.auth.session?.permissions.contains('payment.refund') == true &&
        order.cashierOrder &&
        order.status == 'paid' &&
        order.refund == null;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.name(widget.language)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${t('billItemQuantity')}: ${item.quantity}'),
            if (item.servingKnown)
              Text('${t('billServed')}: ${item.servedQuantity}'),
            const SizedBox(height: 12),
            Text(t('billSubmittedQuantityUnavailable')),
            if (!item.servingKnown) Text(t('billProgressUnknown')),
            if ((item.servedQuantity ?? 0) > 0) Text(t('billServedReturnOnly')),
            if (!canRefund) Text(t('billReturnUnavailable')),
            if (canRefund) Text(t('billReturnOrderScope')),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(t('staffCancelSelection')),
          ),
          if (canServe)
            FilledButton(
              key: const ValueKey('bill-serve-product'),
              onPressed: () => Navigator.pop(context, 'serve'),
              child: Text(t('servingConfirm')),
            ),
          if (widget.onAddProduct != null)
            FilledButton(
              key: const ValueKey('bill-add-product'),
              onPressed: () => Navigator.pop(context, 'add'),
              child: Text(t('billAddOrder')),
            ),
          if (canRefund)
            FilledButton(
              onPressed: () => Navigator.pop(context, 'refund'),
              child: Text(t('billReturnAction')),
            ),
        ],
      ),
    );
    if (!mounted ||
        !foreground ||
        generation != epoch ||
        !identical(identity, widget.auth.session) ||
        loading ||
        failed) {
      return;
    }
    if (action == 'add') {
      await widget.onAddProduct?.call(item.productRef);
      return;
    }
    if (action == 'serve') {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => BillServingDialog(
          auth: widget.auth,
          language: widget.language,
          tableRef: widget.tableRef,
          sessionRef: widget.sessionRef,
          order: order,
          item: item,
          isCurrent: () =>
              mounted &&
              foreground &&
              generation == epoch &&
              identical(identity, widget.auth.session) &&
              !loading &&
              !failed,
        ),
      );
      if (mounted && foreground) await load();
      return;
    }
    if (action != 'refund') return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BalanceRefundDialog(
        auth: widget.auth,
        orderRef: order.reference,
        language: widget.language,
      ),
    );
    if (mounted && foreground) await load();
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

  Widget amount(String label, int cents, String key) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      key: ValueKey(key),
      children: [
        Expanded(child: Text(t(label))),
        Text(
          'CNY ${formatCents(cents)}',
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
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
          if (loading && snapshot != null)
            Text(t('billSyncing'), style: const TextStyle(fontSize: 10)),
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
              onMinus: !loading && !failed ? draftFor(group)?.onMinus : null,
              onPlus:
                  !loading &&
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
          amount(
            'billTotal',
            paid.totalCents + pending.totalCents + widget.draftCents,
            'table-bill-total',
          ),
          amount('billPaidAmount', paid.totalCents, 'table-bill-paid'),
          amount(
            'billUnpaidAmount',
            pending.totalCents + widget.draftCents,
            'table-bill-pending',
          ),
          if ((summary?.buckets['refunded']?.totalCents ?? 0) > 0)
            amount(
              'tableBillRefunded',
              summary!.buckets['refunded']!.totalCents,
              'table-bill-refunded',
            ),
        ],
        if (canRead && canPay)
          FilledButton(
            key: const ValueKey('table-bill-checkout'),
            onPressed:
                !loading &&
                    !failed &&
                    !checkout &&
                    widget.checkoutAllowed &&
                    pending != null &&
                    pending.orderCount > 0
                ? pay
                : null,
            child: Text(t('tableCheckoutTitle')),
          ),
      ],
    );
  }
}
