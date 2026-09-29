import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'opening_journal.dart';
import 'opening_snapshot.dart';
import 'table_snapshot.dart';

class LiveOpeningPanel extends StatefulWidget {
  const LiveOpeningPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.onBack,
    this.tableId,
    this.currency,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  final String? tableId, currency;
  @override
  State<LiveOpeningPanel> createState() => _LiveOpeningPanelState();
}

class _LiveOpeningPanelState extends State<LiveOpeningPanel>
    with WidgetsBindingObserver {
  final count = TextEditingController();
  OpeningContext? data;
  List<PendingOpening> pending = [];
  bool busy = false,
      confirming = false,
      foreground = true,
      failed = false,
      arrival = false,
      reservation = false;
  int epoch = 0;
  String? message;
  String t(String key) => tr(widget.language, key);
  bool current(int generation) => mounted && foreground && generation == epoch;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(identityChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(load());
    });
  }

  void identityChanged() {
    ++epoch;
    if (!mounted) return;
    setState(() {
      data = null;
      pending = [];
      arrival = reservation = false;
      failed = true;
      message = null;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      ++epoch;
      setState(() {
        data = null;
        pending = [];
        arrival = reservation = false;
        message = null;
      });
    } else if (!busy) {
      unawaited(load());
    }
  }

  Future<void> refreshData(int generation) async {
    final entries = await widget.auth.pendingOpenings();
    if (!current(generation)) return;
    setState(() {
      pending = entries;
    });
    if (widget.tableId != null) {
      final context = await widget.auth.readOpeningContext(
        tableId: widget.tableId!,
      );
      if (current(generation)) {
        setState(() {
          data = context;
        });
      }
    }
  }

  Future<void> load() async {
    if (busy || !foreground) return;
    final generation = ++epoch;
    setState(() {
      busy = true;
      failed = false;
      data = null;
      pending = [];
      arrival = reservation = false;
    });
    try {
      await refreshData(generation);
    } catch (_) {
      if (current(generation)) {
        setState(() {
          failed = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
        if (foreground && generation != epoch && widget.auth.session != null) {
          unawaited(load());
        }
      }
    }
  }

  Future<bool> confirm(String key, String? details) async {
    final generation = epoch;
    final identity = widget.auth.session;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t(key)),
        content: Text('${details ?? ''}\n\n${t('openingConfirmNotice')}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(t('cancel')),
          ),
          FilledButton(
            key: const ValueKey('opening-dialog-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t('confirm')),
          ),
        ],
      ),
    );
    return accepted == true &&
        current(generation) &&
        identical(identity, widget.auth.session);
  }

  Future<void> run(
    Future<OpeningLookup> Function() action,
    String? confirmation, {
    String? details,
  }) async {
    if (busy || !foreground) return;
    // Reserve the UI before the dialog so two taps cannot enqueue confirmations.
    setState(() {
      busy = true;
      confirming = confirmation != null;
    });
    if (confirmation != null && !await confirm(confirmation, details)) {
      if (mounted) {
        setState(() {
          busy = false;
          confirming = false;
        });
        if (foreground && data == null) unawaited(load());
      }
      return;
    }
    final generation = ++epoch;
    setState(() {
      confirming = false;
      failed = false;
      message = null;
      arrival = reservation = false;
    });
    try {
      final result = await action();
      if (current(generation)) {
        setState(() {
          message = switch (result.state) {
            OpeningLookupState.confirmed => 'openingConfirmed',
            OpeningLookupState.cancelled => 'openingCancelled',
            OpeningLookupState.notObserved => 'openingUnknown',
          };
        });
      }
    } catch (_) {
      if (current(generation)) {
        setState(() {
          message = 'openingUnconfirmed';
        });
      }
    }
    try {
      if (current(generation)) {
        setState(() {
          data = null;
        });
        await refreshData(generation);
      }
    } catch (_) {
      if (current(generation)) {
        setState(() {
          failed = true;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
        if (foreground && generation != epoch && widget.auth.session != null) {
          unawaited(load());
        }
      }
    }
  }

  void submit() {
    final context = data, size = int.tryParse(count.text);
    final confirmedArrival = arrival, confirmedReservation = reservation;
    if (context == null || size == null || !canSubmit) return;
    unawaited(
      run(
        () => widget.auth.submitOpening(
          context: context,
          partySize: size,
          memberRefs: [],
          arrivalConfirmed: confirmedArrival,
          reservationChecked: confirmedReservation,
        ),
        'openingSubmit',
        details:
            '${context.tableName} · ${t('guests')}: $size\n${context.businessDate} · ${t(context.paymentTiming == 'prepay' ? 'livePrepay' : 'livePostpay')}',
      ),
    );
  }

  bool get canSubmit {
    final context = data, size = int.tryParse(count.text);
    return !busy &&
        !failed &&
        foreground &&
        context != null &&
        context.openingEnabled &&
        context.tableStatus == 'active' &&
        context.activeSessionRef == null &&
        context.mode != 'aa' &&
        arrival &&
        reservation &&
        size != null &&
        size >= 1 &&
        size <= 65535 &&
        (context.mode == 'manual' || size <= context.maximumSeats) &&
        (context.minimumPeople == null || size >= context.minimumPeople!) &&
        !pending.any((p) => p.tableId == context.tableId);
  }

  @override
  void dispose() {
    ++epoch;
    widget.auth.removeListener(identityChanged);
    WidgetsBinding.instance.removeObserver(this);
    count.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = data;
    return Column(
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
                t(widget.tableId == null ? 'openingPending' : 'openingSubmit'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              OutlinedButton(
                key: const ValueKey('opening-refresh'),
                onPressed: busy ? null : () => unawaited(load()),
                child: Text(t('openingRefresh')),
              ),
            ],
          ),
        ),
        if (busy && !confirming) const LinearProgressIndicator(),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            children: [
              Text(t('openingNotice')),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    t(message!),
                    key: const ValueKey('opening-result'),
                  ),
                ),
              if (failed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(t('openingReadFailed')),
                ),
              if (value != null)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          value.tableName,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        Text(
                          '${t('liveBusinessDate')}: ${value.businessDate} · ${t(value.paymentTiming == 'prepay' ? 'livePrepay' : 'livePostpay')}',
                        ),
                        Text(
                          '${t('openingRule')}: ${t('openingRule_${value.mode}')} · ${t('openingRevision')}: ${value.revision}',
                        ),
                        if (value.ruleSource == 'manual_default')
                          Text(t('openingDefaultRule')),
                        if (value.minimumPeople != null)
                          Text(
                            '${t('openingMinimumPeople')}: ${value.minimumPeople}',
                          ),
                        if (value.minimumSpendCents != null)
                          Text(
                            '${t('openingMinimumSpend')}: ${widget.currency ?? ''} ${formatCents(value.minimumSpendCents!)}',
                          ),
                        Text(
                          '${t('guests')}: ${value.minimumSeats ?? '—'}–${value.maximumSeats}',
                        ),
                        if (!value.openingEnabled) Text(t('openingDisabled')),
                        if (value.activeSessionRef != null)
                          Text(t('openingOccupied')),
                        if (value.tableStatus != 'active')
                          Text(t('tableDisabled')),
                        if (value.mode == 'aa') Text(t('openingAaUnavailable')),
                        const SizedBox(height: 16),
                        TextField(
                          key: const ValueKey('opening-party-size'),
                          controller: count,
                          enabled: !busy,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(5),
                          ],
                          decoration: InputDecoration(
                            labelText: t('guests'),
                            border: const OutlineInputBorder(),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        CheckboxListTile(
                          key: const ValueKey('opening-arrival'),
                          contentPadding: EdgeInsets.zero,
                          value: arrival,
                          onChanged: busy
                              ? null
                              : (v) => setState(() {
                                  arrival = v == true;
                                }),
                          title: Text(t('openingArrival')),
                        ),
                        CheckboxListTile(
                          key: const ValueKey('opening-reservation'),
                          contentPadding: EdgeInsets.zero,
                          value: reservation,
                          onChanged: busy
                              ? null
                              : (v) => setState(() {
                                  reservation = v == true;
                                }),
                          title: Text(t('openingReservation')),
                        ),
                        FilledButton(
                          key: const ValueKey('opening-submit'),
                          onPressed: canSubmit ? submit : null,
                          child: Text(t('openingSubmit')),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                t('openingPending'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (pending.isEmpty && !busy && !failed)
                Text(t('openingNoPending')),
              for (final item in pending)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('${t('tables')}: ${item.tableId}'),
                        Text('${t('openingRequest')}: ${item.requestId}'),
                        Text(t('openingUnknown')),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              key: ValueKey('opening-query-${item.requestId}'),
                              onPressed: busy
                                  ? null
                                  : () => unawaited(
                                      run(
                                        () => widget.auth.recoverOpening(
                                          item.requestId,
                                        ),
                                        null,
                                      ),
                                    ),
                              child: Text(t('openingQuery')),
                            ),
                            OutlinedButton(
                              key: ValueKey('opening-retry-${item.requestId}'),
                              onPressed: busy
                                  ? null
                                  : () => unawaited(
                                      run(
                                        () => widget.auth.recoverOpening(
                                          item.requestId,
                                          retryOriginal: true,
                                        ),
                                        'openingRetry',
                                        details:
                                            '${item.tableId}\n${item.requestId}',
                                      ),
                                    ),
                              child: Text(t('openingRetry')),
                            ),
                            OutlinedButton(
                              key: ValueKey('opening-cancel-${item.requestId}'),
                              onPressed: busy
                                  ? null
                                  : () => unawaited(
                                      run(
                                        () => widget.auth.cancelOpening(
                                          item.requestId,
                                          confirmed: true,
                                        ),
                                        'openingCancel',
                                        details:
                                            '${item.tableId}\n${item.requestId}',
                                      ),
                                    ),
                              child: Text(t('openingCancel')),
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
}
