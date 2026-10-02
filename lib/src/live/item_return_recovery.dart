import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'item_return_command.dart';

/// Available even when the original product was removed from the current bill.
class ItemReturnRecovery extends StatefulWidget {
  const ItemReturnRecovery({
    super.key,
    required this.auth,
    required this.language,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  @override
  State<ItemReturnRecovery> createState() => _ItemReturnRecoveryState();
}

class _ItemReturnRecoveryState extends State<ItemReturnRecovery>
    with WidgetsBindingObserver {
  List<PendingItemReturn> entries = [];
  final retryable = <String>{};
  bool busy = false, failed = false, foreground = true;
  int epoch = 0;
  String t(String key) => tr(widget.language, key);
  bool current(int value) => mounted && foreground && epoch == value;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(invalidate);
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant ItemReturnRecovery old) {
    super.didUpdateWidget(old);
    if (old.auth != widget.auth) {
      old.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
      invalidate();
    }
  }

  void invalidate() {
    ++epoch;
    if (!mounted) return;
    setState(() {
      entries = [];
      retryable.clear();
    });
    if (!busy && foreground) unawaited(load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    invalidate();
  }

  @override
  void dispose() {
    ++epoch;
    widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    if (busy || !foreground) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      final rows = await widget.auth.pendingItemReturns();
      if (current(generation)) setState(() => entries = rows);
    } catch (_) {
      if (current(generation)) setState(() => failed = true);
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (foreground && generation != epoch) unawaited(load());
      }
    }
  }

  Future<void> resolve(PendingItemReturn entry, {bool retry = false}) async {
    if (busy || !foreground) return;
    final generation = epoch;
    if (retry) {
      final agreed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t('servingRetry')),
          content: Text(t('itemReturnRetryNotice')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('cashPrepareCancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('servingRetry')),
            ),
          ],
        ),
      );
      if (!current(generation) || agreed != true) return;
    }
    setState(() {
      busy = true;
      failed = false;
    });
    try {
      final result = await widget.auth.recoverItemReturn(
        entry.requestId,
        retryOriginal: retry,
      );
      if (!current(generation)) return;
      setState(() {
        if (result.confirmed) {
          entries = entries
              .where((e) => e.requestId != entry.requestId)
              .toList();
          retryable.remove(entry.requestId);
        } else {
          retryable.add(entry.requestId);
        }
      });
    } catch (_) {
      if (current(generation)) setState(() => failed = true);
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (foreground && generation != epoch) unawaited(load());
      }
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: Text(t('itemReturnPending'))),
              IconButton(
                key: const ValueKey('item-return-refresh'),
                onPressed: busy ? null : load,
                icon: const Icon(Icons.refresh),
                tooltip: t('ordersRefresh'),
              ),
            ],
          ),
          if (failed) Text(t('liveReadFailed')),
          if (!busy && !failed && entries.isEmpty) Text(t('servingNoPending')),
          if (busy) const LinearProgressIndicator(),
          if (entries.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final entry in entries)
                    ListTile(
                      title: Text(
                        '${entry.params['tableRef']} · ${entry.orderRef}',
                      ),
                      subtitle: Text(
                        '${entry.productRef} × ${entry.params['quantity']}',
                      ),
                      trailing: Wrap(
                        children: [
                          TextButton(
                            key: ValueKey(
                              'item-return-lookup-${entry.requestId}',
                            ),
                            onPressed: busy ? null : () => resolve(entry),
                            child: Text(t('servingLookup')),
                          ),
                          if (retryable.contains(entry.requestId))
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => resolve(entry, retry: true),
                              child: Text(t('servingRetry')),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
