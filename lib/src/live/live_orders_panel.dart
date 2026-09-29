import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'order_snapshot.dart';
import 'live_cash_recovery_panel.dart';
import 'table_snapshot.dart';

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
  bool cashBusy = false, cashRecovery = false;
  BuildContext? cashDialog;
  void closeCashDialog() {
    final ctx = cashDialog;
    if (ctx != null && ctx.mounted && ModalRoute.of(ctx)?.isCurrent == true) {
      Navigator.of(ctx).pop(false);
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
    if (cashBusy || loading || !cashEligible(order)) return;
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

  String t(String key) => tr(widget.language, key);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(authChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(load());
    });
  }

  void authChanged() {
    ++epoch;
    closeCashDialog();
    if (mounted) {
      setState(() {
        data = null;
        loading = false;
        failed = true;
        cashRecovery = false;
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
    if (oldWidget.revision != widget.revision ||
        oldWidget.table.reference != widget.table.reference ||
        oldWidget.table.session?.reference != widget.table.session?.reference) {
      ++epoch;
      closeCashDialog();
      data = null;
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
      data = null;
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
    ++epoch;
    debounce?.cancel();
    widget.auth.removeListener(authChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => cashRecovery
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
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 20,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: cashBusy ? null : widget.onBack,
                    child: Text(t('ordersBack')),
                  ),
                  Text('${widget.table.name} · ${t('ordersDetails')}'),
                  OutlinedButton(
                    key: const ValueKey('orders-refresh'),
                    onPressed: loading || cashBusy
                        ? null
                        : () => unawaited(load(reset: true)),
                    child: Text(t('ordersRefresh')),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(t('ordersSnapshotNotice')),
            ),
            if (data != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '${t('liveObserved')}: ${data!.observedAt.toLocal()}',
                ),
              ),
            if (loading || cashBusy) const LinearProgressIndicator(),
            Expanded(
              child: failed
                  ? Center(child: Text(t('liveReadFailed')))
                  : data == null
                  ? const SizedBox()
                  : data!.orders.isEmpty
                  ? Center(child: Text(t('ordersEmpty')))
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: data!.orders.length,
                      itemBuilder: (context, index) {
                        final order = data!.orders[index];
                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  '${order.reference} · ${t('order_${order.status}')} · ${order.currency} ${formatCents(order.totalCents)}',
                                ),
                                Text('${order.createdAt.toLocal()}'),
                                if (cashEligible(order))
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: OutlinedButton(
                                      key: ValueKey(
                                        'cash-prepare-${order.reference}',
                                      ),
                                      onPressed: cashBusy
                                          ? null
                                          : () => unawaited(prepareCash(order)),
                                      child: Text(t('cashPrepare')),
                                    ),
                                  ),
                                for (final item in order.items)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Text(
                                      '${item.name(widget.language)} · ${item.specification(widget.language)} · ${item.quantity} × ${formatCents(item.priceCents)} = ${formatCents(item.subtotalCents)}',
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
                    onPressed: loading || cashBusy || page == 0
                        ? null
                        : () => unawaited(load(target: page - 1)),
                    child: Text(t('livePrevious')),
                  ),
                  Text('${t('livePage')} ${page + 1}'),
                  OutlinedButton(
                    onPressed:
                        loading || cashBusy || data?.nextAfterOrder == null
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
