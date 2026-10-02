import 'bill_product_card.dart';

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
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef, sessionRef;
  final int revision;
  final bool checkoutAllowed, fillHeight;
  final Widget? leading;
  final int draftCents;
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
    unawaited(load());
  }

  void reset() {
    epoch++;
    setState(() {
      orders = [];
      snapshot = null;
      loading = false;
      failed = false;
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
      reset();
    } else if (old.revision != widget.revision && foreground) {
      unawaited(load());
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
    });
    try {
      final raw = await widget.auth.readOrders(
        tableRef: widget.tableRef,
        sessionRef: widget.sessionRef,
        afterOrder: cursor,
      );
      if (!mounted ||
          ticket != epoch ||
          !foreground ||
          !identical(identity, widget.auth.session)) {
        return;
      }
      final next = OrderSnapshot.parse(
        raw,
        storeRef: identity!.storeRef,
        tableRef: widget.tableRef,
        sessionRef: widget.sessionRef,
        afterOrder: cursor,
      );
      setState(() {
        orders = [...previous, ...next.orders];
        snapshot = next;
        loading = false;
      });
    } catch (_) {
      if (mounted && ticket == epoch) {
        setState(() {
          failed = true;
          loading = false;
        });
      }
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

  Widget status(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
    ),
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
    final visible = orders
        .where(
          (o) =>
              o.status != 'expired' && (filter == 'all' || o.status == filter),
        )
        .toList();
    final canPay = [
      'payment.cash',
      'payment.wechat',
      'payment.alipay',
      'payment.balance',
    ].any((p) => widget.auth.session?.permissions.contains(p) == true);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.leading != null && filter != 'paid') widget.leading!,
        if (canRead) ...[
          const Divider(),
          Text(
            t('tableBillSubmitted'),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (loading) const LinearProgressIndicator(),
          if (failed)
            TextButton(
              onPressed: () => unawaited(load()),
              child: Text(t('tableBillRetry')),
            ),
          if (!loading && !failed && visible.isEmpty) Text(t('billNoItems')),
          for (final order in visible) ...[
            for (final item in order.items)
              BillProductCard(
                key: ValueKey(
                  'bill-card-${order.reference}-${item.productRef}',
                ),
                language: widget.language,
                name: item.name(widget.language),
                specification: item.specification(widget.language),
                quantity: item.quantity,
                priceCents: item.priceCents,
                totalCents: item.subtotalCents,
                thumbnailPath: item.thumbnailPath,
                base: widget.auth.session?.base,
                footer: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    status(
                      t(
                        order.status == 'paid'
                            ? 'tableBillPaid'
                            : 'tableBillUnpaid',
                      ),
                      order.status == 'paid'
                          ? const Color(0xff216344)
                          : const Color(0xff994a16),
                    ),
                    if (order.refund != null)
                      status(t('tableBillRefunded'), const Color(0xff666666))
                    else if (order.status == 'paid') ...[
                      if (!item.servingKnown)
                        status(
                          t('billProgressUnknown'),
                          const Color(0xff666666),
                        ),
                      if (item.servingKnown && item.remainingQuantity! > 0)
                        status(
                          '${t('billNotServed')} × ${item.remainingQuantity}',
                          const Color(0xff994a16),
                        ),
                      if (item.servingKnown && item.servedQuantity! > 0)
                        status(
                          '${t('billServed')} × ${item.servedQuantity}',
                          const Color(0xff216344),
                        ),
                    ] else if (item.servingKnown &&
                        snapshot?.paymentTiming == 'postpay' &&
                        order.cashierOrder)
                      status(
                        '${t('billServed')} × ${item.servedQuantity} / ${item.quantity}',
                        const Color(0xff526c5f),
                      ),
                  ],
                ),
              ),
            if (order.refund != null)
              Text(
                '${t('tableBillRefunded')} ${formatCents(order.refund!.totalCents)}',
              ),
          ],
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
        if (canRead)
          Wrap(
            spacing: 6,
            children: [
              for (final entry in {
                'all': 'all',
                'pending': 'tableBillUnpaid',
                'paid': 'tableBillPaid',
              }.entries)
                ChoiceChip(
                  key: ValueKey('bill-filter-${entry.key}'),
                  label: Text(t(entry.value)),
                  selected: filter == entry.key,
                  onSelected: (_) => setState(() => filter = entry.key),
                ),
            ],
          ),
        if (widget.fillHeight)
          Expanded(child: SingleChildScrollView(child: content))
        else
          content,
        if (canRead && pending != null && paid != null) ...[
          const Divider(height: 12),
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
