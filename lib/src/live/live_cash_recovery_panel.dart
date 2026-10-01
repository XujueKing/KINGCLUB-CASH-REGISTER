import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import '../network/ccsop_client.dart';
import 'cash_command.dart';
import 'table_snapshot.dart';

class LiveCashRecoveryPanel extends StatefulWidget {
  const LiveCashRecoveryPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.onBack,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  @override
  State<LiveCashRecoveryPanel> createState() => _LiveCashRecoveryPanelState();
}

class _LiveCashRecoveryPanelState extends State<LiveCashRecoveryPanel>
    with WidgetsBindingObserver {
  List<PendingCash> entries = [];
  final allowed = <String, bool>{};
  final prepared = <String, bool>{};
  bool busy = false, foreground = true, failed = false, confirming = false;
  int epoch = 0;
  String? message;
  BuildContext? dialog;
  String t(String key) => tr(widget.language, key);
  bool current(int value) => mounted && foreground && epoch == value;
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
  void didUpdateWidget(covariant LiveCashRecoveryPanel old) {
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
      Navigator.of(ctx).pop();
    }
    if (!mounted) return;
    setState(() {
      entries = [];
      allowed.clear();
      prepared.clear();
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
    final result = await widget.auth.pendingCash();
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
      allowed.clear();
      prepared.clear();
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

  int? amount(String raw) {
    if (!RegExp(r'^(0|[1-9][0-9]{0,6})(\.[0-9]{1,2})?$').hasMatch(raw)) {
      return null;
    }
    final parts = raw.split('.'),
        value =
            int.parse(parts[0]) * 100 +
            (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
    return value >= 1 && value <= 100000000 ? value : null;
  }

  Future<Object?> ask(PendingCash item, String action) async {
    var input = item.receivedCents == null
        ? ''
        : formatCents(item.receivedCents!);
    try {
      return await showDialog<Object>(
        context: context,
        builder: (ctx) {
          dialog = ctx;
          return StatefulBuilder(
            builder: (ctx, update) {
              final received = amount(input),
                  valid = received != null && received >= item.totalCents;
              return AlertDialog(
                title: Text(
                  t(
                    action == 'pay'
                        ? 'cashConfirm'
                        : action == 'return'
                        ? 'cashReturnClose'
                        : action == 'close'
                        ? 'cashClose'
                        : 'cashRetry',
                  ),
                ),
                content: SizedBox(
                  width: 460,
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          '${item.orderRef}\n${item.requestId}\n${t('cashDue')}: CNY ${formatCents(item.totalCents)}',
                        ),
                        const SizedBox(height: 16),
                        Text(
                          t(
                            action == 'pay'
                                ? 'cashReceivedNotice'
                                : action == 'return'
                                ? 'cashReturnNotice'
                                : action == 'close'
                                ? 'cashCloseNotice'
                                : 'cashRetryNotice',
                          ),
                        ),
                        if (action == 'pay') ...[
                          const SizedBox(height: 16),
                          TextFormField(
                            key: const ValueKey('cash-received-input'),
                            initialValue: input,
                            readOnly: item.receivedCents != null,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText: t('cashReceived'),
                              suffixText: 'CNY',
                            ),
                            onChanged: (value) => update(() {
                              input = value;
                            }),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            valid
                                ? '${t('cashChange')}: CNY ${formatCents(received - item.totalCents)}'
                                : t('cashAmountInvalid'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(t('cancel')),
                  ),
                  FilledButton(
                    key: const ValueKey('cash-decision-confirm'),
                    onPressed: action == 'pay' && !valid
                        ? null
                        : () => Navigator.pop(
                            ctx,
                            action == 'pay' ? received : true,
                          ),
                    child: Text(
                      t(
                        action == 'pay'
                            ? 'cashReceivedConfirm'
                            : action == 'return'
                            ? 'cashReturnedConfirm'
                            : action == 'close'
                            ? 'cashNotReceivedConfirm'
                            : 'confirm',
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      );
    } finally {
      dialog = null;
    }
  }

  Future<void> run(PendingCash item, String action) async {
    if (busy || !foreground) return;
    final generation = ++epoch,
        auth = widget.auth,
        identity = widget.auth.session;
    setState(() {
      busy = true;
      confirming = action != 'query';
    });
    try {
      final decision = action == 'query' ? null : await ask(item, action);
      if (action != 'query' && decision == null) return;
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
      final result = action == 'pay'
          ? await auth.confirmCash(
              item.requestId,
              receivedCents: decision as int,
              cashReceivedConfirmed: true,
            )
          : action == 'return'
          ? await auth.closeCash(item.requestId, cashReturnedConfirmed: true)
          : action == 'close'
          ? await auth.closeCash(item.requestId, noCashCollectedConfirmed: true)
          : await auth.recoverCash(
              item.requestId,
              retryOriginalPreparation: action == 'retry',
            );
      if (current(generation)) {
        setState(() {
          prepared[item.requestId] = result.state == CashState.prepared;
          allowed[item.requestId] =
              result.state == CashState.prepared && result.canConfirmCash;
          message = t(switch (result.state) {
            CashState.confirmed => 'cashPaid',
            CashState.closed => 'cashClosed',
            CashState.notObserved => 'cashUnknown',
            CashState.needsLookup => 'cashNeedsLookup',
            CashState.prepared =>
              result.canConfirmCash ? 'cashPrepared' : 'cashCannotConfirm',
          });
          if (result.state == CashState.confirmed) {
            message =
                '$message\n${t('cashReceived')}: CNY ${formatCents(result.receivedCents!)} · ${t('cashChange')}: CNY ${formatCents(result.changeCents!)}';
          }
        });
      }
    } catch (error) {
      if (current(generation)) {
        setState(() {
          prepared[item.requestId] = false;
          message = t(
            error is CcsopFailure && error.code == 'ORDERING_OUT_OF_STOCK'
                ? 'cashStockUnavailable'
                : 'cashUnconfirmed',
          );
          allowed[item.requestId] = false;
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
              t('cashRecoveryTitle'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            OutlinedButton(
              key: const ValueKey('cash-refresh'),
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
            Text(t('cashRecoveryNotice')),
            if (message != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(message!, key: const ValueKey('cash-result')),
              ),
            if (failed) Text(t('cashLoadFailed')),
            if (!busy && !failed && foreground && entries.isEmpty)
              Text(t('cashEmpty')),
            for (final item in entries)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(item.orderRef),
                      Text('${t('openingRequest')}: ${item.requestId}'),
                      Text(
                        '${t('cashDue')}: CNY ${formatCents(item.totalCents)}',
                      ),
                      Text(
                        t(
                          item.closeRequested && item.receivedCents != null
                              ? 'cashReturnedConfirm'
                              : item.receivedCents != null
                              ? 'cashDecisionReceived'
                              : item.closeRequested
                              ? 'cashDecisionClose'
                              : item.intentRef == null
                              ? 'cashUnknown'
                              : 'cashNeedsLookup',
                        ),
                      ),
                      if (item.receivedCents != null)
                        Text(
                          '${t('cashReceived')}: CNY ${formatCents(item.receivedCents!)}',
                        ),
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        children: [
                          for (final action in [
                            'query',
                            if (item.initial) 'retry',
                            if (item.intentRef != null && !item.closeRequested)
                              'pay',
                            if (item.intentRef != null &&
                                item.receivedCents != null &&
                                !item.closeRequested)
                              'return',
                            if (item.intentRef != null &&
                                item.receivedCents == null)
                              'close',
                          ])
                            OutlinedButton(
                              key: ValueKey('cash-$action-${item.requestId}'),
                              onPressed:
                                  busy ||
                                      !foreground ||
                                      (action == 'return' &&
                                          prepared[item.requestId] != true) ||
                                      (action == 'pay' &&
                                          allowed[item.requestId] != true)
                                  ? null
                                  : () => unawaited(run(item, action)),
                              child: Text(
                                t(switch (action) {
                                  'query' => 'openingQuery',
                                  'retry' => 'cashRetry',
                                  'pay' => 'cashConfirm',
                                  'return' => 'cashReturnClose',
                                  _ => 'cashClose',
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
