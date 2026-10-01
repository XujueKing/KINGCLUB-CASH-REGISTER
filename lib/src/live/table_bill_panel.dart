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
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef, sessionRef;
  final int revision;
  final bool checkoutAllowed;
  @override
  State<TableBillPanel> createState() => _TableBillPanelState();
}

class _TableBillPanelState extends State<TableBillPanel>
    with WidgetsBindingObserver {
  List<LiveOrder> orders = [];
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

  @override
  Widget build(BuildContext context) {
    if (!canRead) {
      return const SizedBox.shrink();
    }
    final pending = snapshot?.sessionSummary?.buckets['pending'];
    final canPay = [
      'payment.cash',
      'payment.wechat',
      'payment.alipay',
      'payment.balance',
    ].any((p) => widget.auth.session?.permissions.contains(p) == true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        for (final order in orders.where((o) => o.status != 'expired')) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              t(order.status == 'paid' ? 'tableBillPaid' : 'tableBillUnpaid'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          for (final item in order.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${item.name(widget.language)} · ${item.specification(widget.language)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  SizedBox(
                    width: 42,
                    child: Text(
                      '×${item.quantity}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  SizedBox(
                    width: 80,
                    child: Text(
                      formatCents(item.subtotalCents),
                      textAlign: TextAlign.right,
                    ),
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
        if (pending != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '${t('tableBillUnpaid')}  ${snapshot!.sessionSummary!.currency} ${formatCents(pending.totalCents)}',
              key: const ValueKey('table-bill-pending'),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        if (canPay)
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
