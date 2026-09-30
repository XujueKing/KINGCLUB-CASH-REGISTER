import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'balance_refund_command.dart';
import 'balance_refund_dialog.dart';
import 'table_snapshot.dart';

/// Device/employee scoped originals, independent of current table and pagination.
class BalanceRefundRecoveryPanel extends StatefulWidget {
  const BalanceRefundRecoveryPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.onBack,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  @override
  State<BalanceRefundRecoveryPanel> createState() =>
      _BalanceRefundRecoveryPanelState();
}

class _BalanceRefundRecoveryPanelState extends State<BalanceRefundRecoveryPanel>
    with WidgetsBindingObserver {
  List<PendingBalanceRefund> entries = [];
  bool loading = false, failed = false, foreground = true, opening = false;
  int epoch = 0;
  String t(String key) => tr(widget.language, key);
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
    if (!mounted) return;
    setState(() {
      entries = [];
      loading = false;
      failed = false;
    });
    if (foreground) unawaited(load());
  }

  @override
  void didUpdateWidget(covariant BalanceRefundRecoveryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.auth != widget.auth) {
      oldWidget.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
      invalidate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    invalidate();
  }

  @override
  void dispose() {
    epoch++;
    widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    if (!mounted || !foreground) return;
    final ticket = ++epoch;
    setState(() {
      loading = true;
      entries = [];
      failed = false;
    });
    try {
      final result = await widget.auth.pendingBalanceRefunds();
      if (mounted && foreground && epoch == ticket) {
        setState(() => entries = result);
      }
    } catch (_) {
      if (mounted && epoch == ticket) setState(() => failed = true);
    } finally {
      if (mounted && epoch == ticket) setState(() => loading = false);
    }
  }

  Future<void> open(PendingBalanceRefund entry) async {
    if (opening || loading || !foreground || !entries.contains(entry)) return;
    setState(() => opening = true);
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => BalanceRefundDialog(
          auth: widget.auth,
          orderRef: entry.orderRef,
          language: widget.language,
          recoveryOnly: true,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => opening = false);
        if (foreground) await load();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: opening ? null : widget.onBack,
              child: Text(t('ordersBack')),
            ),
            Text(t('refundRecoveryTitle')),
            OutlinedButton(
              onPressed: loading || opening || !foreground ? null : load,
              child: Text(t('refundReload')),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Text(t('refundRecoveryNotice')),
      ),
      if (loading) const LinearProgressIndicator(),
      Expanded(
        child: !foreground
            ? const SizedBox.shrink()
            : failed
            ? Center(child: Text(t('refundUnavailable')))
            : loading
            ? const SizedBox.shrink()
            : entries.isEmpty
            ? Center(child: Text(t('refundRecoveryEmpty')))
            : ListView.builder(
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return Card(
                    key: ValueKey(entry.refundRef),
                    margin: const EdgeInsets.all(12),
                    child: ListTile(
                      title: Text(
                        '${entry.orderRef} · ${t('balance_${entry.params['accountType']}')} · CNY ${formatCents(entry.params['expectedTotalCents'] as int)}',
                      ),
                      subtitle: Text(entry.refundRef),
                      trailing: OutlinedButton(
                        onPressed: opening ? null : () => open(entry),
                        child: Text(t('refundQuery')),
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );
}
