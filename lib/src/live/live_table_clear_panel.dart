import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'table_clear_command.dart';
import 'table_snapshot.dart';

class LiveTableClearPanel extends StatefulWidget {
  const LiveTableClearPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.onBack,
    this.table,
    this.revision = 0,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  final LiveTable? table;
  final int revision;
  @override
  State<LiveTableClearPanel> createState() => _LiveTableClearPanelState();
}

class _LiveTableClearPanelState extends State<LiveTableClearPanel>
    with WidgetsBindingObserver {
  List<PendingTableClear> entries = [];
  final retryable = <String>{};
  int epoch = 0;
  bool busy = false, foreground = true, failed = false;
  bool confirming = false;
  bool attempted = false;
  String? message;
  BuildContext? dialog;
  String t(String key) => tr(widget.language, key);
  bool current(int generation) => mounted && foreground && generation == epoch;
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
  void didUpdateWidget(covariant LiveTableClearPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.auth, widget.auth)) {
      old.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
      invalidate();
    } else if (old.revision != widget.revision ||
        old.table?.session?.reference != widget.table?.session?.reference) {
      invalidate();
    }
  }

  void invalidate() {
    ++epoch;
    final ctx = dialog;
    if (ctx != null && ctx.mounted && ModalRoute.of(ctx)?.isCurrent == true) {
      Navigator.of(ctx).pop(false);
    }
    if (!mounted) return;
    setState(() {
      entries = [];
      retryable.clear();
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
    final result = await widget.auth.pendingTableClear();
    if (current(generation)) setState(() => entries = result);
  }

  Future<void> load() async {
    if (!mounted || busy || !foreground) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      failed = false;
      entries = [];
      retryable.clear();
    });
    try {
      await read(generation);
    } catch (_) {
      if (current(generation)) setState(() => failed = true);
    } finally {
      finish(generation);
    }
  }

  bool get canClear {
    final table = widget.table;
    final identity = widget.auth.session;
    return !attempted &&
        !failed &&
        foreground &&
        identity != null &&
        identity.expiresAt.isAfter(DateTime.now()) &&
        identity.permissions.contains('table.clear') &&
        table?.status == 'active' &&
        table?.session != null &&
        {'open', 'clearing'}.contains(table!.session!.status) &&
        !entries.any((entry) => entry.sessionRef == table.session!.reference);
  }

  Future<void> clearTable() async {
    if (busy || !canClear) return;
    final generation = epoch;
    final table = widget.table!;
    setState(() {
      busy = true;
      confirming = true;
      message = null;
    });
    try {
      final approved = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          dialog = ctx;
          return AlertDialog(
            title: Text(t('tableClearConfirm')),
            content: SingleChildScrollView(
              child: Text(
                '${table.name}\n${table.reference}\n${table.session!.reference}\n\n${t('tableClearConfirmNotice')}',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(t('tableClearCancel')),
              ),
              FilledButton(
                key: const ValueKey('tableClear-confirm-submit'),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(t('tableClearConfirm')),
              ),
            ],
          );
        },
      );
      dialog = null;
      if (mounted) setState(() => confirming = false);
      if (!current(generation) || approved != true || !canClear) return;
      setState(() => attempted = true);
      final result = await widget.auth.confirmTableClear(
        tableRef: table.reference,
        sessionRef: table.session!.reference,
        confirmed: true,
      );
      if (!current(generation)) return;
      setState(
        () => message = result.confirmed
            ? 'tableClearConfirmed'
            : 'tableClearUnresolved',
      );
    } catch (_) {
      if (current(generation)) setState(() => failed = true);
    } finally {
      dialog = null;
      if (current(generation)) {
        try {
          await read(generation);
        } catch (_) {
          if (current(generation)) setState(() => failed = true);
        }
      }
      finish(generation);
    }
  }

  Future<void> resolve(PendingTableClear entry, {bool retry = false}) async {
    if (busy ||
        !foreground ||
        (retry && !retryable.contains(entry.requestId))) {
      return;
    }
    final generation = epoch;
    setState(() {
      busy = true;
      message = null;
      failed = false;
    });
    try {
      if (retry) {
        setState(() => confirming = true);
        final approved = await showDialog<bool>(
          context: context,
          builder: (ctx) {
            dialog = ctx;
            return AlertDialog(
              title: Text(t('tableClearRetry')),
              content: SingleChildScrollView(
                child: Text(
                  '${entry.tableRef}\n${entry.sessionRef}\n\n${t('tableClearRetryNotice')}',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(t('tableClearCancel')),
                ),
                FilledButton(
                  key: const ValueKey('tableClear-retry-confirm'),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(t('tableClearRetry')),
                ),
              ],
            );
          },
        );
        dialog = null;
        if (mounted) setState(() => confirming = false);
        if (!current(generation) || approved != true) return;
      }
      final result = await widget.auth.recoverTableClear(
        entry.requestId,
        retryOriginal: retry,
      );
      if (!current(generation)) return;
      setState(() {
        message = result.confirmed
            ? 'tableClearConfirmed'
            : 'tableClearUnresolved';
        if (result.confirmed) {
          if (entry.sessionRef == widget.table?.session?.reference) {
            attempted = true;
          }
          retryable.remove(entry.requestId);
        } else {
          retryable.add(entry.requestId);
        }
      });
      await read(generation);
    } catch (_) {
      if (current(generation)) {
        setState(() {
          failed = true;
          retryable.remove(entry.requestId);
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
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            OutlinedButton(
              onPressed: busy ? null : widget.onBack,
              child: Text(t('ordersBack')),
            ),
            Text(t('tableClearRecoveryTitle')),
            OutlinedButton(
              key: const ValueKey('tableClear-pending-refresh'),
              onPressed: busy ? null : () => unawaited(load()),
              child: Text(t('ordersRefresh')),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(t('tableClearRecoveryNotice')),
      ),
      if (widget.table?.session != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 16,
            children: [
              Text(
                '${widget.table!.name} · ${widget.table!.session!.reference}',
              ),
              FilledButton(
                key: const ValueKey('tableClear-open'),
                onPressed: busy || !canClear
                    ? null
                    : () => unawaited(clearTable()),
                child: Text(t('tableClearConfirm')),
              ),
            ],
          ),
        ),
      if (busy && !confirming) const LinearProgressIndicator(),
      if (failed)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(t('tableClearFailed')),
        ),
      if (message != null)
        Padding(padding: const EdgeInsets.all(12), child: Text(t(message!))),
      Expanded(
        child: entries.isEmpty
            ? Center(
                child: Text(busy || failed ? '' : t('tableClearNoPending')),
              )
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${entry.tableRef}\n${entry.sessionRef}'),
                          Text(entry.requestId),
                          Wrap(
                            spacing: 16,
                            children: [
                              OutlinedButton(
                                key: ValueKey(
                                  'tableClear-lookup-${entry.requestId}',
                                ),
                                onPressed: busy
                                    ? null
                                    : () => unawaited(resolve(entry)),
                                child: Text(t('tableClearLookup')),
                              ),
                              if (retryable.contains(entry.requestId))
                                OutlinedButton(
                                  key: ValueKey(
                                    'tableClear-retry-${entry.requestId}',
                                  ),
                                  onPressed: busy
                                      ? null
                                      : () => unawaited(
                                          resolve(entry, retry: true),
                                        ),
                                  child: Text(t('tableClearRetry')),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );
}
