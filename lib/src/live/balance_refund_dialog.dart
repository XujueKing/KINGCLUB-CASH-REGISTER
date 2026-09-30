import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'balance_refund_command.dart';
import 'balance_refund_context.dart';
import 'balance_refund_result.dart';
import 'table_snapshot.dart';

class BalanceRefundDialog extends StatefulWidget {
  const BalanceRefundDialog({
    super.key,
    required this.auth,
    required this.orderRef,
    required this.language,
    this.recoveryOnly = false,
  });
  final StaffAuthController auth;
  final String orderRef;
  final UiLanguage language;
  final bool recoveryOnly;
  @override
  State<BalanceRefundDialog> createState() => _BalanceRefundDialogState();
}

class _BalanceRefundDialogState extends State<BalanceRefundDialog>
    with WidgetsBindingObserver {
  final reason = TextEditingController();
  final quantities = <String, TextEditingController>{};
  final reasons = <String, TextEditingController>{};
  final physical = <String, bool>{};
  BalanceRefundContext? snapshot;
  List<PendingBalanceRefund> pending = [];
  bool busy = false, foreground = true, consent = false;
  int epoch = 0;
  String status = '';
  String t(String key) => tr(widget.language, key);
  bool current(int ticket) => mounted && foreground && ticket == epoch;
  @override
  void initState() {
    super.initState();
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(invalidate);
    if (foreground) unawaited(load());
  }

  void clearForm() {
    for (final c in [...quantities.values, ...reasons.values]) {
      c.dispose();
    }
    quantities.clear();
    reasons.clear();
    physical.clear();
    reason.clear();
    consent = false;
  }

  void invalidate() {
    epoch++;
    if (!mounted) return;
    setState(() {
      clearForm();
      snapshot = null;
      pending = [];
      status = 'refundReload';
    });
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
    clearForm();
    reason.dispose();
    super.dispose();
  }

  Future<void> load() async {
    if (busy || !foreground) return;
    final ticket = ++epoch;
    setState(() {
      busy = true;
      clearForm();
      snapshot = null;
      pending = [];
      status = '';
    });
    try {
      final entries = await widget.auth.pendingBalanceRefunds();
      if (!current(ticket)) return;
      final matches = entries
          .where((e) => e.orderRef == widget.orderRef)
          .toList();
      if (matches.isNotEmpty) {
        setState(() => pending = matches);
        return;
      }
      if (widget.recoveryOnly) {
        setState(() => status = 'refundRecoveryEmpty');
        return;
      }
      final result = await widget.auth.balanceRefundContext(widget.orderRef);
      if (!current(ticket)) return;
      setState(() {
        snapshot = result;
        if (result.alreadyRefunded) status = 'refundDone';
        for (final source in result.sources) {
          quantities[source.originalMovementRef] = TextEditingController();
          reasons[source.originalMovementRef] = TextEditingController();
          physical[source.originalMovementRef] = false;
        }
      });
    } catch (_) {
      if (current(ticket)) setState(() => status = 'refundUnavailable');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submit() async {
    final original = snapshot;
    if (busy ||
        !foreground ||
        original == null ||
        original.alreadyRefunded ||
        !consent) {
      return;
    }
    final choices = <Map<String, dynamic>>[];
    for (final source in original.sources) {
      final ref = source.originalMovementRef;
      final qty = int.tryParse(quantities[ref]!.text);
      if (qty == null ||
          qty < 0 ||
          qty > source.issuedQuantity ||
          reasons[ref]!.text.trim().isEmpty ||
          (qty > 0 && physical[ref] != true)) {
        setState(() => status = 'refundDecisionsRequired');
        return;
      }
      choices.add({
        'originalMovementRef': ref,
        'returnQuantity': qty,
        'physicalReturnConfirmed': physical[ref]!,
        'reason': reasons[ref]!.text,
      });
    }
    if (reason.text.trim().isEmpty) {
      setState(() => status = 'refundDecisionsRequired');
      return;
    }
    final ticket = epoch;
    await perform(
      () => widget.auth.confirmBalanceRefund(
        context: original,
        reason: reason.text,
        dispositions: choices,
        confirmed: consent,
        stillCurrent: () => current(ticket),
      ),
    );
  }

  Future<void> recover(
    PendingBalanceRefund command, {
    bool retry = false,
  }) async {
    if (busy || !foreground || (retry && !consent)) return;
    final ticket = epoch;
    await perform(
      () => widget.auth.recoverBalanceRefund(
        command.refundRef,
        retryOriginal: retry,
        stillCurrent: () => current(ticket),
      ),
    );
  }

  Future<void> perform(Future<BalanceRefundResult> Function() operation) async {
    final ticket = epoch;
    setState(() {
      busy = true;
      status = '';
    });
    try {
      final result = await operation();
      if (!mounted || !current(ticket)) return;
      if (result.confirmed) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() {
        status = 'refundNotObserved';
        consent = false;
      });
    } catch (_) {
      if (current(ticket)) {
        setState(() {
          status = 'refundUnknown';
          consent = false;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
    // Always reload the durable original before another submission can be offered.
    if (current(ticket)) {
      final message = status;
      await load();
      if (mounted && foreground && status.isEmpty) {
        setState(() => status = message);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final enabled = foreground && !busy;
    return AlertDialog(
      title: Text(t('refundTitle')),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.orderRef),
              Text(t('refundNotice')),
              if (busy) const LinearProgressIndicator(),
              if (status.isNotEmpty) Text(t(status)),
              for (final command in pending) ...[
                Text(
                  '${command.refundRef}\n${t('balance_${command.params['accountType']}')} · CNY ${formatCents(command.params['expectedTotalCents'] as int)}',
                ),
                Text('${t('refundReason')}: ${command.params['reason']}'),
                for (final d in command.params['dispositions'] as List)
                  Text(
                    '${d['originalMovementRef']} · ${t('refundReturnQuantity')}: ${d['returnQuantity']} · ${d['reason']}',
                  ),
                OutlinedButton(
                  onPressed: enabled ? () => recover(command) : null,
                  child: Text(t('refundQuery')),
                ),
                FilledButton(
                  onPressed: enabled && consent
                      ? () => recover(command, retry: true)
                      : null,
                  child: Text(t('refundRetry')),
                ),
              ],
              if (s != null && !s.alreadyRefunded && pending.isEmpty) ...[
                Text(
                  '${t('balance_${s.accountType}')} · CNY ${formatCents(s.totalCents!)}',
                ),
                Text(
                  '${t('refundPrincipal')}: ${formatCents(s.principalCents!)} · ${t('refundGift')}: ${formatCents(s.giftCents!)}',
                ),
                TextField(
                  controller: reason,
                  enabled: enabled,
                  maxLength: 500,
                  onChanged: (_) => setState(() => consent = false),
                  decoration: InputDecoration(labelText: t('refundReason')),
                ),
                for (final source in s.sources)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Text(
                            '${source.productRef} · ${source.batchRef} · ${source.originalMovementRef}',
                          ),
                          Text(
                            '${t('refundIssued')}: ${source.issuedQuantity}',
                          ),
                          TextField(
                            controller: quantities[source.originalMovementRef],
                            enabled: enabled,
                            onChanged: (_) => setState(() => consent = false),
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                            ],
                            decoration: InputDecoration(
                              labelText: t('refundReturnQuantity'),
                            ),
                          ),
                          TextField(
                            controller: reasons[source.originalMovementRef],
                            enabled: enabled,
                            maxLength: 500,
                            onChanged: (_) => setState(() => consent = false),
                            decoration: InputDecoration(
                              labelText: t('refundDispositionReason'),
                            ),
                          ),
                          CheckboxListTile(
                            value: physical[source.originalMovementRef]!,
                            title: Text(t('refundPhysical')),
                            onChanged: enabled
                                ? (value) => setState(() {
                                    physical[source.originalMovementRef] =
                                        value ?? false;
                                    consent = false;
                                  })
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
              if (pending.isNotEmpty || (s != null && !s.alreadyRefunded))
                CheckboxListTile(
                  value: consent,
                  title: Text(t('refundConsent')),
                  onChanged: enabled
                      ? (value) => setState(() => consent = value ?? false)
                      : null,
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.of(context).pop(false),
          child: Text(t('cancel')),
        ),
        OutlinedButton(
          onPressed: enabled ? load : null,
          child: Text(t('refundReload')),
        ),
        if (s != null && !s.alreadyRefunded && pending.isEmpty)
          FilledButton(
            onPressed: enabled && consent ? submit : null,
            child: Text(t('refundSubmit')),
          ),
      ],
    );
  }
}
