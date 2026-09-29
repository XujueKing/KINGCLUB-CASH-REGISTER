import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../auth/staff_session.dart';
import '../network/cashier_realtime_client.dart';
import '../strings.dart';
import 'table_snapshot.dart';
import 'live_orders_panel.dart';
import 'live_opening_panel.dart';
import 'live_catalog_panel.dart';
import 'live_order_members_panel.dart';
import 'live_order_recovery_panel.dart';
import 'live_cash_recovery_panel.dart';
import 'live_serving_recovery_panel.dart';
import 'live_table_clear_panel.dart';

class LiveTablesPanel extends StatefulWidget {
  const LiveTablesPanel({
    super.key,
    required this.auth,
    required this.language,
    this.enableRealtime = const bool.fromEnvironment('CASHIER_REALTIME'),
    this.realtimeFactory,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final bool enableRealtime;
  final CashierRealtimeClient Function(StaffSession)? realtimeFactory;
  @override
  State<LiveTablesPanel> createState() => _LiveTablesPanelState();
}

class _LiveTablesPanelState extends State<LiveTablesPanel>
    with WidgetsBindingObserver {
  TableSnapshot? snapshot;
  LiveTable? selected;
  LiveTable? orderingTable;
  bool opening = false;
  bool catalog = false;
  bool orderRecovery = false;
  bool cashRecovery = false;
  bool servingRecovery = false;
  bool tableClear = false;
  LiveTable? clearingTable;
  String? openingTable, openingCurrency;
  final cursors = <String?>[null];
  int page = 0, epoch = 0;
  bool loading = false, failed = false;
  bool foreground = true, refreshQueued = false;
  int realtimeRevision = 0;
  CashierRealtimeClient? realtime;
  Timer? refreshDebounce;
  String t(String key) => tr(widget.language, key);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final session = widget.auth.session;
    if (widget.enableRealtime && session != null) {
      realtime =
          widget.realtimeFactory?.call(session) ??
          CashierRealtimeClient(session);
      realtime!.addListener(realtimeChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(load());
        realtime?.start();
      }
    });
  }

  void realtimeChanged() {
    if (!mounted) return;
    setState(() {});
    if (realtime!.revision != realtimeRevision) {
      realtimeRevision = realtime!.revision;
      queueRefresh();
    }
  }

  void queueRefresh() {
    if (!foreground || !mounted) return;
    refreshQueued = true;
    refreshDebounce ??= Timer(const Duration(milliseconds: 400), () {
      refreshDebounce = null;
      if (!mounted || !foreground || loading) return;
      refreshQueued = false;
      unawaited(load(reset: true));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      foreground = true;
      unawaited(load());
      realtime?.start();
    } else {
      foreground = false;
      realtime?.stop();
      refreshDebounce?.cancel();
      refreshDebounce = null;
      refreshQueued = false;
      ++epoch;
      setState(() {
        snapshot = null;
        loading = false;
      });
    }
  }

  Future<void> load({int? target, bool reset = false}) async {
    final generation = ++epoch;
    final session = widget.auth.session;
    if (session == null) return;
    if (reset) {
      cursors
        ..clear()
        ..add(null);
      page = 0;
    }
    final requestedPage = target ?? page;
    final cursor = cursors[requestedPage];
    setState(() {
      loading = true;
      failed = false;
      snapshot = null;
    });
    try {
      final raw = await widget.auth.readWorkbench(afterTable: cursor);
      if (!mounted ||
          generation != epoch ||
          !identical(session, widget.auth.session)) {
        return;
      }
      final value = TableSnapshot.parse(
        raw,
        storeRef: session.storeRef,
        employeeRef: session.employeeRef,
        afterTable: cursor,
      );
      if (value.nextAfterTable != null &&
          cursors.take(requestedPage + 1).contains(value.nextAfterTable)) {
        throw const FormatException();
      }
      setState(() {
        snapshot = value;
        page = requestedPage;
        loading = false;
      });
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() {
          failed = true;
          loading = false;
          snapshot = null;
        });
      }
    } finally {
      if (mounted && generation == epoch && refreshQueued) queueRefresh();
    }
  }

  void next() {
    final cursor = snapshot?.nextAfterTable;
    if (cursor == null || loading) return;
    cursors.removeRange(page + 1, cursors.length);
    cursors.add(cursor);
    unawaited(load(target: page + 1));
  }

  @override
  void dispose() {
    ++epoch;
    refreshDebounce?.cancel();
    realtime?.removeListener(realtimeChanged);
    realtime?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (tableClear) {
      return LiveTableClearPanel(
        auth: widget.auth,
        language: widget.language,
        table: clearingTable,
        revision: realtimeRevision,
        onBack: () {
          setState(() {
            tableClear = false;
            clearingTable = null;
          });
          unawaited(load(reset: true));
        },
      );
    }
    if (servingRecovery) {
      return LiveServingRecoveryPanel(
        auth: widget.auth,
        language: widget.language,
        onBack: () {
          setState(() => servingRecovery = false);
          unawaited(load(reset: true));
        },
      );
    }
    if (cashRecovery) {
      return LiveCashRecoveryPanel(
        auth: widget.auth,
        language: widget.language,
        onBack: () {
          setState(() {
            cashRecovery = false;
          });
          unawaited(load(reset: true));
        },
      );
    }
    if (orderRecovery) {
      return LiveOrderRecoveryPanel(
        auth: widget.auth,
        language: widget.language,
        onBack: () {
          setState(() {
            orderRecovery = false;
          });
          unawaited(load(reset: true));
        },
      );
    }
    if (orderingTable != null) {
      return LiveOrderMembersPanel(
        auth: widget.auth,
        language: widget.language,
        tableRef: orderingTable!.reference,
        sessionRef: orderingTable!.session!.reference,
        revision: realtimeRevision,
        onBack: () {
          setState(() {
            orderingTable = null;
          });
          unawaited(load(reset: true));
        },
      );
    }
    if (catalog) {
      return LiveCatalogPanel(
        auth: widget.auth,
        language: widget.language,
        revision: realtimeRevision,
        onBack: () {
          setState(() {
            catalog = false;
          });
          unawaited(load(reset: true));
        },
      );
    }
    if (opening) {
      return LiveOpeningPanel(
        auth: widget.auth,
        language: widget.language,
        tableId: openingTable,
        currency: openingCurrency,
        onBack: () {
          setState(() {
            opening = false;
            openingTable = null;
            openingCurrency = null;
          });
          unawaited(load(reset: true));
        },
      );
    }
    if (selected != null) {
      return LiveOrdersPanel(
        key: ValueKey(selected!.session!.reference),
        auth: widget.auth,
        language: widget.language,
        table: selected!,
        revision: realtimeRevision,
        onBack: () {
          setState(() {
            selected = null;
          });
          unawaited(load(reset: true));
        },
      );
    }
    final data = snapshot;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
          child: Wrap(
            spacing: 20,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                data?.storeName ?? widget.auth.session?.storeRef ?? '',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(widget.auth.session?.displayName ?? ''),
              if (widget.auth.session?.permissions.contains('table.clear') ==
                  true)
                OutlinedButton(
                  key: const ValueKey('tableClear-recovery-open'),
                  onPressed: () => setState(() {
                    tableClear = true;
                    clearingTable = null;
                  }),
                  child: Text(t('tableClearRecoveryTitle')),
                ),
              if (widget.auth.session?.permissions.contains('orders.serve') ==
                  true)
                OutlinedButton(
                  key: const ValueKey('serving-recovery-open'),
                  onPressed: () => setState(() => servingRecovery = true),
                  child: Text(t('servingRecoveryTitle')),
                ),
              if (widget.auth.session?.permissions.contains('orders.create') ==
                  true)
                OutlinedButton(
                  key: const ValueKey('order-recovery-open'),
                  onPressed: () => setState(() {
                    orderRecovery = true;
                  }),
                  child: Text(t('orderRecoveryTitle')),
                ),
              if (widget.auth.session?.permissions.contains('payment.cash') ==
                  true)
                OutlinedButton(
                  key: const ValueKey('cash-recovery-open'),
                  onPressed: () => setState(() {
                    cashRecovery = true;
                  }),
                  child: Text(t('cashRecoveryTitle')),
                ),
              if (widget.auth.session?.permissions.contains('orders.create') ==
                  true)
                OutlinedButton(
                  key: const ValueKey('catalog-open'),
                  onPressed: () => setState(() {
                    catalog = true;
                  }),
                  child: Text(t('catalogTitle')),
                ),
              if (widget.auth.session?.permissions.contains('table.open') ==
                  true)
                OutlinedButton(
                  key: const ValueKey('opening-pending'),
                  onPressed: () => setState(() {
                    opening = true;
                    openingTable = null;
                    openingCurrency = null;
                  }),
                  child: Text(t('openingPending')),
                ),
              OutlinedButton(
                key: const ValueKey('live-refresh'),
                onPressed: loading ? null : () => unawaited(load(reset: true)),
                child: Text(t('liveRefresh')),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            t(realtime == null ? 'liveReadOnly' : 'liveRealtimeReadOnly'),
          ),
        ),
        if (realtime != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
            child: Text(
              t(switch (realtime!.state) {
                CashierRealtimeState.offline => 'realtimeOffline',
                CashierRealtimeState.connecting => 'realtimeConnecting',
                CashierRealtimeState.connected => 'realtimeConnected',
              }),
            ),
          ),
        if (data != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Text(
              '${t('liveObserved')}: ${data.observedAt.toLocal()} · ${t('liveBusinessDate')}: ${data.businessDate}',
            ),
          ),
        if (loading) const LinearProgressIndicator(),
        Expanded(
          child: failed
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(t('liveReadFailed')),
                  ),
                )
              : data == null
              ? const SizedBox()
              : data.tables.isEmpty
              ? Center(child: Text(t('liveNoTables')))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: data.tables.length,
                  itemBuilder: (context, index) =>
                      tableCard(data.tables[index], data.currency),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: 20,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: loading || page == 0
                    ? null
                    : () => unawaited(load(target: page - 1)),
                child: Text(t('livePrevious')),
              ),
              Text('${t('livePage')} ${page + 1}'),
              OutlinedButton(
                key: const ValueKey('live-next'),
                onPressed: loading || data?.nextAfterTable == null
                    ? null
                    : next,
                child: Text(t('liveNext')),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget tableCard(LiveTable table, String currency) {
    final session = table.session;
    return Card(
      key: ValueKey('live-table-${table.reference}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                Text(table.name, style: Theme.of(context).textTheme.titleLarge),
                Text(t(table.stateLabel)),
                Text(
                  '${t('guests')}: ${session?.partySize ?? '—'} / ${table.maximumSeats}',
                ),
              ],
            ),
            if (session != null) ...[
              if (table.status == 'active' &&
                  widget.auth.session?.permissions.contains('table.clear') ==
                      true)
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton(
                    key: ValueKey('tableClear-table-${table.reference}'),
                    onPressed: () => setState(() {
                      tableClear = true;
                      clearingTable = table;
                    }),
                    child: Text(t('tableClearConfirm')),
                  ),
                ),
              if (table.status == 'active' &&
                  session.status == 'open' &&
                  widget.auth.session?.permissions.contains('orders.create') ==
                      true)
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton(
                    key: ValueKey('order-members-open-${table.reference}'),
                    onPressed: () => setState(() {
                      orderingTable = table;
                    }),
                    child: Text(t('orderMembersTitle')),
                  ),
                ),
              if (widget.auth.session?.permissions.contains('orders.read') ==
                  true)
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton(
                    key: ValueKey('orders-open-${table.reference}'),
                    onPressed: () => setState(() {
                      selected = table;
                    }),
                    child: Text(t('ordersDetails')),
                  ),
                ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 24,
                runSpacing: 8,
                children: [
                  Text(
                    t(
                      session.paymentTiming == 'prepay'
                          ? 'livePrepay'
                          : 'livePostpay',
                    ),
                  ),
                  Text('${t('elapsed')}: ${session.elapsedMinutes}'),
                  Text(
                    '${t('livePaid')}: $currency ${formatCents(session.paidCents)}',
                  ),
                  Text(
                    '${t('livePending')}: $currency ${formatCents(session.pendingCents)}',
                  ),
                ],
              ),
            ],
            if (session == null &&
                table.status == 'active' &&
                widget.auth.session?.permissions.contains('table.open') == true)
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton(
                  key: ValueKey('opening-table-${table.reference}'),
                  onPressed: () => setState(() {
                    opening = true;
                    openingTable = table.reference;
                    openingCurrency = currency;
                  }),
                  child: Text(t('openingSubmit')),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
