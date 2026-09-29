import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'cart_draft.dart';
import 'table_snapshot.dart';

/// Local drafts, including unreachable old sessions. Never cancels an order.
class LiveCartDraftsPanel extends StatefulWidget {
  const LiveCartDraftsPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.onBack,
    this.revision = 0,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  final int revision;
  @override
  State<LiveCartDraftsPanel> createState() => _LiveCartDraftsPanelState();
}

class _LiveCartDraftsPanelState extends State<LiveCartDraftsPanel>
    with WidgetsBindingObserver {
  List<CartDraft> entries = [];
  Set<String> pendingTables = {};
  bool busy = false, failed = false, foreground = true;
  int epoch = 0;
  BuildContext? dialog;
  String t(String key) => tr(widget.language, key);
  bool current(int generation) => mounted && foreground && generation == epoch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(invalidate);
    unawaited(load());
  }

  void invalidate() {
    ++epoch;
    final ctx = dialog;
    if (ctx != null && ctx.mounted && ModalRoute.of(ctx)?.isCurrent == true) {
      Navigator.of(ctx).pop();
    }
    if (!mounted) return;
    setState(() {
      entries = [];
      pendingTables = {};
      failed = false;
    });
    if (foreground && !busy) unawaited(load());
  }

  @override
  void didUpdateWidget(covariant LiveCartDraftsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.auth != widget.auth) {
      oldWidget.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
    }
    if (oldWidget.auth != widget.auth || oldWidget.revision != widget.revision) {
      invalidate();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    invalidate();
  }

  void finish(int generation) {
    if (!mounted) return;
    setState(() => busy = false);
    if (foreground && generation != epoch) unawaited(load());
  }

  Future<void> load() async {
    if (!mounted || busy || !foreground) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      failed = false;
      entries = [];
    });
    try {
      final pending = await widget.auth.pendingOrders();
      if (!current(generation)) return;
      final drafts = await widget.auth.cartDrafts();
      if (!current(generation)) return;
      final sorted = [...drafts]
        ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
      setState(() {
        entries = sorted;
        pendingTables = pending.map((p) => p.tableRef).toSet();
      });
    } catch (_) {
      if (current(generation)) setState(() => failed = true);
    } finally {
      finish(generation);
    }
  }

  Future<void> discard(CartDraft draft) async {
    if (busy || !foreground || pendingTables.contains(draft.tableRef)) return;
    final generation = ++epoch, identity = widget.auth.session;
    setState(() => busy = true);
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          dialog = ctx;
          return AlertDialog(
            title: Text(t('cartDraftDiscard')),
            content: SingleChildScrollView(
              child: Text(
                '${draft.tableRef}\n${draft.sessionRef}\n${draft.memberRef}\n\n${t('cartDraftLocalDeleteNotice')}',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(t('cancel')),
              ),
              FilledButton(
                key: const ValueKey('drafts-delete-confirm'),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(t('confirm')),
              ),
            ],
          );
        },
      );
      dialog = null;
      if (!current(generation) ||
          !identical(identity, widget.auth.session) ||
          accepted != true) {
        return;
      }
      await widget.auth.discardCartDraft(draft, confirmed: true);
      if (!current(generation)) return;
      // Reread after all outcomes; never blindly remove a newer local edit.
      ++epoch;
    } catch (_) {
      if (current(generation)) {
        setState(() {
          failed = true;
          entries = [];
        });
      }
    } finally {
      dialog = null;
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
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 16,
          children: [
            Text(
              t('cartDraftsTitle'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            OutlinedButton(
              key: const ValueKey('drafts-refresh'),
              onPressed: busy || !foreground ? null : () => unawaited(load()),
              child: Text(t('liveRefresh')),
            ),
            TextButton(
              onPressed: busy ? null : widget.onBack,
              child: Text(t('ordersBack')),
            ),
          ],
        ),
      ),
      if (busy && dialog == null) const LinearProgressIndicator(),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(t('cartDraftsNotice')),
            if (failed) Text(t('cartDraftFailed')),
            if (!busy && !failed && entries.isEmpty) Text(t('cartDraftsEmpty')),
            for (final draft in entries)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${draft.tableRef} · ${draft.sessionRef}'),
                      Text(draft.memberRef),
                      Text(
                        '${t('cartDraftSavedAt')}: ${draft.savedAt.toLocal()}',
                      ),
                      Text(
                        '${t('cartDraftEstimate')}: CNY ${formatCents(draft.lines.fold<int>(0, (sum, line) => sum + (line['quantity'] as int) * (line['priceCents'] as int)))}',
                      ),
                      if (pendingTables.contains(draft.tableRef))
                        Text(t('cartPending')),
                      TextButton(
                        key: ValueKey(
                          'drafts-delete-${draft.encode()['editVersion']}',
                        ),
                        onPressed:
                            busy ||
                                !foreground ||
                                pendingTables.contains(draft.tableRef)
                            ? null
                            : () => unawaited(discard(draft)),
                        child: Text(t('cartDraftDiscard')),
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
