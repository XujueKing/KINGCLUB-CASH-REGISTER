import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'order_command.dart';
import 'table_snapshot.dart';

/// Recovers original commands only. Neither a receipt nor a socket hint is payment.
class LiveOrderRecoveryPanel extends StatefulWidget {
  const LiveOrderRecoveryPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.onBack,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;

  @override
  State<LiveOrderRecoveryPanel> createState() => _LiveOrderRecoveryPanelState();
}

class _LiveOrderRecoveryPanelState extends State<LiveOrderRecoveryPanel>
    with WidgetsBindingObserver {
  List<PendingOrder> entries = [];
  bool busy = false, foreground = true, failed = false, confirming = false;
  int epoch = 0;
  String? message;
  String t(String key) => tr(widget.language, key);
  bool current(int value) => mounted && foreground && value == epoch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(invalidate);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(load());
    });
  }

  @override
  void didUpdateWidget(covariant LiveOrderRecoveryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.auth, widget.auth)) {
      oldWidget.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
      invalidate();
    }
  }

  void invalidate() {
    ++epoch;
    if (!mounted) return;
    setState(() {
      entries = [];
      message = null;
      failed = false;
    });
    if (!busy && foreground) unawaited(load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    invalidate();
  }

  void finish(int generation) {
    if (!mounted) return;
    setState(() {
      busy = false;
      confirming = false;
    });
    if (foreground && generation != epoch) unawaited(load());
  }

  Future<void> read(int generation) async {
    final result = await widget.auth.pendingOrders();
    if (current(generation)) {
      setState(() {
        entries = result;
      });
    }
  }

  Future<void> load() async {
    if (busy || !foreground || !mounted) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      failed = false;
      entries = [];
    });
    try {
      await read(generation);
    } catch (_) {
      if (current(generation)) {
        setState(() {
          failed = true;
        });
      }
    } finally {
      finish(generation);
    }
  }

  Future<void> run(PendingOrder item, String action) async {
    if (busy || !foreground) return;
    final generation = ++epoch;
    final auth = widget.auth, identity = widget.auth.session;
    setState(() {
      busy = true;
      confirming = action != 'query';
    });
    try {
      if (action != 'query') {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              t(
                action == 'retry'
                    ? 'orderRecoveryRetry'
                    : 'orderRecoveryCancel',
              ),
            ),
            content: Text(
              '${item.tableRef}\n${item.requestId}\nCNY ${formatCents(item.totalCents)}\n\n${t('orderRecoveryConfirm')}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(t('cancel')),
              ),
              FilledButton(
                key: const ValueKey('order-recovery-confirm'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(t('confirm')),
              ),
            ],
          ),
        );
        if (accepted != true) return;
      }
      if (!current(generation) ||
          !identical(auth, widget.auth) ||
          !identical(identity, auth.session)) {
        return;
      }
      setState(() {
        confirming = false;
        message = null;
        failed = false;
      });
      final result = action == 'cancel'
          ? await auth.cancelOrder(item.requestId, confirmed: true)
          : await auth.recoverOrder(
              item.requestId,
              retryOriginal: action == 'retry',
            );
      if (current(generation)) {
        setState(() {
          message = switch (result.state) {
            OrderRequestState.confirmed => 'orderRecoveryConfirmed',
            OrderRequestState.cancelled => 'orderRecoveryCancelled',
            OrderRequestState.notObserved => 'orderRecoveryUnknown',
          };
        });
      }
    } catch (_) {
      if (current(generation)) {
        setState(() {
          message = 'orderRecoveryUnconfirmed';
        });
      }
    } finally {
      try {
        if (current(generation)) await read(generation);
      } catch (_) {
        if (current(generation)) {
          setState(() {
            entries = [];
            failed = true;
          });
        }
      }
      finish(generation);
    }
  }

  @override
  void dispose() {
    ++epoch;
    widget.auth.removeListener(invalidate);
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
          spacing: 16,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: busy ? null : widget.onBack,
              child: Text(t('ordersBack')),
            ),
            Text(
              t('orderRecoveryTitle'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            OutlinedButton(
              key: const ValueKey('order-recovery-refresh'),
              onPressed: busy || !foreground ? null : () => unawaited(load()),
              child: Text(t('ordersRefresh')),
            ),
          ],
        ),
      ),
      if (busy && !confirming) const LinearProgressIndicator(),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(t('orderRecoveryNotice')),
            if (message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  t(message!),
                  key: const ValueKey('order-recovery-result'),
                ),
              ),
            if (failed) Text(t('orderRecoveryFailed')),
            if (!busy && !failed && foreground && entries.isEmpty)
              Text(t('orderRecoveryEmpty')),
            for (final item in entries)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('${t('tables')}: ${item.tableRef}'),
                      Text('${t('openingRequest')}: ${item.requestId}'),
                      Text(
                        'CNY ${formatCents(item.totalCents)} · ${t(item.paymentTiming == 'prepay' ? 'livePrepay' : 'livePostpay')}',
                      ),
                      Text(t('orderRecoveryUnknown')),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          for (final action in ['query', 'retry', 'cancel'])
                            OutlinedButton(
                              key: ValueKey(
                                'order-recovery-$action-${item.requestId}',
                              ),
                              onPressed: busy || !foreground
                                  ? null
                                  : () => unawaited(run(item, action)),
                              child: Text(
                                t(switch (action) {
                                  'query' => 'openingQuery',
                                  'retry' => 'orderRecoveryRetry',
                                  _ => 'orderRecoveryCancel',
                                }),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}
