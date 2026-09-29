import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'order_snapshot.dart';
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
    if (mounted) {
      setState(() {
        data = null;
        loading = false;
        failed = true;
      });
    }
  }

  @override
  void didUpdateWidget(covariant LiveOrdersPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) schedule();
  }

  void schedule() {
    if (!foreground) return;
    queued = true;
    debounce ??= Timer(const Duration(milliseconds: 400), () {
      debounce = null;
      if (!mounted || !foreground || loading) return;
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
    if (!mounted || !foreground) return;
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 20,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: widget.onBack,
              child: Text(t('ordersBack')),
            ),
            Text('${widget.table.name} · ${t('ordersDetails')}'),
            OutlinedButton(
              key: const ValueKey('orders-refresh'),
              onPressed: loading ? null : () => unawaited(load(reset: true)),
              child: Text(t('ordersRefresh')),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(t('ordersReadOnly')),
      ),
      if (data != null)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text('${t('liveObserved')}: ${data!.observedAt.toLocal()}'),
        ),
      if (loading) const LinearProgressIndicator(),
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
              onPressed: loading || page == 0
                  ? null
                  : () => unawaited(load(target: page - 1)),
              child: Text(t('livePrevious')),
            ),
            Text('${t('livePage')} ${page + 1}'),
            OutlinedButton(
              onPressed: loading || data?.nextAfterOrder == null
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
