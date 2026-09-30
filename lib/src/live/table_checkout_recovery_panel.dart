import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'table_checkout_command.dart';
import 'table_checkout_dialog.dart';
import 'table_snapshot.dart';

/// Local original-request index, independent of current table pagination or a
/// newer table session. Opening a row never automatically queries or charges.
class TableCheckoutRecoveryPanel extends StatefulWidget {
  const TableCheckoutRecoveryPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.onBack,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  @override
  State<TableCheckoutRecoveryPanel> createState() =>
      _TableCheckoutRecoveryPanelState();
}

class _TableCheckoutRecoveryPanelState extends State<TableCheckoutRecoveryPanel>
    with WidgetsBindingObserver {
  List<TableCheckoutCommand> entries = [];
  bool foreground = true, loading = false, failed = false, opening = false;
  int epoch = 0;
  Timer? expiry;
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
    expiry?.cancel();
    if (mounted) {
      setState(() {
        entries = [];
        loading = false;
        failed = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    invalidate();
    if (foreground && !opening) unawaited(load());
  }

  @override
  void didUpdateWidget(covariant TableCheckoutRecoveryPanel old) {
    super.didUpdateWidget(old);
    if (old.auth != widget.auth) {
      old.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
      invalidate();
    }
  }

  @override
  void dispose() {
    epoch++;
    expiry?.cancel();
    widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    if (!mounted || !foreground || loading || opening) return;
    final ticket = ++epoch, identity = widget.auth.session;
    expiry?.cancel();
    setState(() {
      loading = true;
      failed = false;
      entries = [];
    });
    bool current() =>
        mounted &&
        foreground &&
        ticket == epoch &&
        identical(identity, widget.auth.session);
    try {
      if (identity == null || !identity.expiresAt.isAfter(DateTime.now())) {
        throw const FormatException();
      }
      final rows = <TableCheckoutCommand>[];
      for (final channel in ['wechat', 'alipay', 'cash', 'member_balance']) {
        if (identity.permissions.contains(
          'payment.${channel == 'member_balance' ? 'balance' : channel}',
        )) {
          rows.addAll(await widget.auth.pendingTableCheckouts(channel));
          if (!current()) return;
        }
      }
      final remaining = identity.expiresAt.difference(DateTime.now());
      if (remaining <= Duration.zero ||
          rows.length > 100 ||
          rows.any((row) => !row.belongsTo(identity)) ||
          rows.map((row) => row.requestId).toSet().length != rows.length) {
        throw const FormatException();
      }
      if (!current()) return;
      setState(() => entries = List.unmodifiable(rows));
      expiry = Timer(remaining, invalidate);
    } catch (_) {
      if (current()) {
        setState(() {
          failed = true;
          entries = [];
        });
      }
    } finally {
      if (current()) setState(() => loading = false);
    }
  }

  Future<void> open(TableCheckoutCommand entry) async {
    final identity = widget.auth.session, ticket = epoch;
    if (!foreground ||
        loading ||
        opening ||
        !entries.contains(entry) ||
        identity == null ||
        !identity.expiresAt.isAfter(DateTime.now()) ||
        !entry.belongsTo(identity)) {
      return;
    }
    setState(() => opening = true);
    try {
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          if (!mounted ||
              !foreground ||
              ticket != epoch ||
              !identical(identity, widget.auth.session)) {
            final route = ModalRoute.of(ctx);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (ctx.mounted && route != null && route.isActive) {
                Navigator.of(ctx).removeRoute(route);
              }
            });
            return const SizedBox();
          }
          return TableCheckoutDialog(
            auth: widget.auth,
            language: widget.language,
            tableRef: entry.tableRef,
            sessionRef: entry.sessionRef,
            originalRequestId: entry.requestId,
          );
        },
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
          children: [
            OutlinedButton(
              onPressed: opening ? null : widget.onBack,
              child: Text(t('ordersBack')),
            ),
            Text(t('tableCheckoutRecoveryTitle')),
            OutlinedButton(
              onPressed: !foreground || loading || opening
                  ? null
                  : () => unawaited(load()),
              child: Text(t('ordersRefresh')),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(t('tableCheckoutRecoveryNotice')),
      ),
      if (loading) const LinearProgressIndicator(),
      Expanded(
        child: !foreground
            ? const SizedBox()
            : failed
            ? Center(child: Text(t('tableCheckoutReview')))
            : entries.isEmpty
            ? Center(child: Text(t('provider_empty')))
            : ListView.builder(
                itemCount: entries.length,
                itemBuilder: (_, index) {
                  final entry = entries[index];
                  final label = entry.accountType != null
                      ? 'balance_${entry.accountType}'
                      : entry.channel == 'cash'
                      ? 'receiptCash'
                      : 'provider_${entry.channel}';
                  return ListTile(
                    key: ValueKey(entry.requestId),
                    title: Text('${entry.tableRef} · ${entry.sessionRef}'),
                    subtitle: Text(
                      '${entry.requestId}\n${t(label)} · CNY ${formatCents(entry.totalCents)}',
                    ),
                    trailing: OutlinedButton(
                      onPressed: loading || opening
                          ? null
                          : () => unawaited(open(entry)),
                      child: Text(t('tableCheckoutQuery')),
                    ),
                  );
                },
              ),
      ),
    ],
  );
}
