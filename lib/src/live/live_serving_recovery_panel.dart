import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'serving_command.dart';

class LiveServingRecoveryPanel extends StatefulWidget {
  const LiveServingRecoveryPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.onBack,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  @override
  State<LiveServingRecoveryPanel> createState() =>
      _LiveServingRecoveryPanelState();
}

class _LiveServingRecoveryPanelState extends State<LiveServingRecoveryPanel>
    with WidgetsBindingObserver {
  List<PendingServing> entries = [];
  final retryable = <String>{};
  int epoch = 0;
  bool busy = false, foreground = true, failed = false;
  bool confirming = false;
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
  void didUpdateWidget(covariant LiveServingRecoveryPanel old) {
    super.didUpdateWidget(old);
    if (!identical(old.auth, widget.auth)) {
      old.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
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
    final result = await widget.auth.pendingServing();
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

  Future<void> resolve(PendingServing entry, {bool retry = false}) async {
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
              title: Text(t(entry.recall ? 'billRecallWait' : 'servingRetry')),
              content: SingleChildScrollView(
                child: Text(
                  '${entry.orderRef}\n${entry.productRef}\n${entry.before} → ${entry.after}\n\n${t(entry.recall ? 'billRecallWaitNotice' : 'servingRetryNotice')}',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(t('cashPrepareCancel')),
                ),
                FilledButton(
                  key: const ValueKey('serving-retry-confirm'),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(t('servingRetry')),
                ),
              ],
            );
          },
        );
        dialog = null;
        if (mounted) setState(() => confirming = false);
        if (!current(generation) || approved != true) return;
      }
      final result = await widget.auth.recoverServing(
        entry.requestId,
        retryOriginal: retry,
      );
      if (!current(generation)) return;
      setState(() {
        message = result.confirmed
            ? (entry.recall ? 'billRecallConfirmed' : 'servingConfirmed')
            : 'servingUnresolved';
        if (result.confirmed) {
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
            Text(t('servingRecoveryTitle')),
            OutlinedButton(
              key: const ValueKey('serving-pending-refresh'),
              onPressed: busy ? null : () => unawaited(load()),
              child: Text(t('ordersRefresh')),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Text(t('servingRecoveryNotice')),
      ),
      if (busy && !confirming) const LinearProgressIndicator(),
      if (failed)
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(t('servingFailed')),
        ),
      if (message != null)
        Padding(padding: const EdgeInsets.all(12), child: Text(t(message!))),
      Expanded(
        child: entries.isEmpty
            ? Center(child: Text(busy ? '' : t('servingNoPending')))
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
                          Text(
                            '${entry.tableRef} · ${entry.orderRef}\n${entry.productRef}',
                          ),
                          Text(
                            '${entry.recall ? t('billRecall') : t('billServed')} ${entry.before} → ${entry.after} / ${entry.quantity}',
                          ),
                          Wrap(
                            spacing: 16,
                            children: [
                              OutlinedButton(
                                key: ValueKey(
                                  'serving-lookup-${entry.requestId}',
                                ),
                                onPressed: busy
                                    ? null
                                    : () => unawaited(resolve(entry)),
                                child: Text(t('servingLookup')),
                              ),
                              if (retryable.contains(entry.requestId))
                                OutlinedButton(
                                  key: ValueKey(
                                    'serving-retry-${entry.requestId}',
                                  ),
                                  onPressed: busy
                                      ? null
                                      : () => unawaited(
                                          resolve(entry, retry: true),
                                        ),
                                  child: Text(t('servingRetry')),
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
