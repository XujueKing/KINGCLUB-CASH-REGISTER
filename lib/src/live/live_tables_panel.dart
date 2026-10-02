import 'dart:async';

import 'table_calendar_panel.dart';

import 'swipe_grid.dart';

import 'provider_recovery_panel.dart';
import 'voucher_report_panel.dart';
import 'voucher_lookup_panel.dart';
import 'balance_refund_recovery_panel.dart';
import 'recharge_recovery_panel.dart';
import 'recharge_collect_panel.dart';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../auth/staff_auth_controller.dart';
import '../auth/staff_session.dart';
import '../network/cashier_realtime_client.dart';
import '../strings.dart';
import 'table_snapshot.dart';
import 'table_bill_panel.dart';
import 'live_orders_panel.dart';
import 'table_checkout_recovery_panel.dart';
import 'live_opening_panel.dart';
import 'live_catalog_panel.dart';
import 'live_order_members_panel.dart';
import 'live_order_recovery_panel.dart';
import 'live_cash_recovery_panel.dart';
import 'live_serving_recovery_panel.dart';
import 'live_table_clear_panel.dart';
import 'live_cart_drafts_panel.dart';

class LiveTablesPanel extends StatefulWidget {
  const LiveTablesPanel({
    super.key,
    this.menuVisible,
    this.onMenuChanged,
    required this.auth,
    required this.language,
    this.enableRealtime = const bool.fromEnvironment('CASHIER_REALTIME'),
    this.realtimeFactory,
  });
  final bool? menuVisible;
  final ValueChanged<bool>? onMenuChanged;
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
  String? focusedTableRef;
  LiveTable? orderingTable;
  bool opening = false;
  bool voucherReport = false;
  bool voucherLookup = false;
  bool catalog = false;
  bool orderRecovery = false;
  bool cartDrafts = false;
  bool cashRecovery = false;
  bool tableCheckoutRecovery = false;
  bool providerRecovery = false;
  bool refundRecovery = false;
  bool rechargeRecovery = false;
  bool rechargeCollect = false;
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
  Timer? clockTimer;
  DateTime? selectedDate;
  String t(String key) => tr(widget.language, key);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    clockTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && foreground) setState(() {});
    });
    foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final session = widget.auth.session;
    if (widget.enableRealtime && session != null) {
      realtime =
          widget.realtimeFactory?.call(session) ??
          CashierRealtimeClient(session);
      realtime!.addListener(realtimeChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && foreground) {
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
    if (!mounted || !foreground) return;
    final generation = ++epoch;
    final session = widget.auth.session;
    if (session == null) return;
    final previousPage = page;
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
      if (requestedPage != previousPage) snapshot = null;
    });
    try {
      final raw = await widget.auth.readWorkbench(afterTable: cursor);
      if (!mounted ||
          !foreground ||
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
    clockTimer?.cancel();
    ++epoch;
    refreshDebounce?.cancel();
    realtime?.removeListener(realtimeChanged);
    realtime?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (voucherLookup) {
      return VoucherLookupPanel(
        auth: widget.auth,
        language: widget.language,
        onBack: () {
          setState(() => voucherLookup = false);
          unawaited(load(reset: true));
        },
      );
    }
    if (voucherReport) {
      return VoucherReportPanel(
        auth: widget.auth,
        language: widget.language,
        onBack: () {
          setState(() => voucherReport = false);
          unawaited(load(reset: true));
        },
      );
    }
    if (tableCheckoutRecovery) {
      return TableCheckoutRecoveryPanel(
        auth: widget.auth,
        language: widget.language,
        onBack: () {
          setState(() => tableCheckoutRecovery = false);
          unawaited(load(reset: true));
        },
      );
    }
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
    if (providerRecovery) {
      return ProviderRecoveryPanel(
        auth: widget.auth,
        language: widget.language,
        onBack: () {
          setState(() => providerRecovery = false);
          unawaited(load(reset: true));
        },
      );
    }
    if (refundRecovery) {
      return BalanceRefundRecoveryPanel(
        auth: widget.auth,
        language: widget.language,
        onBack: () {
          setState(() => refundRecovery = false);
          unawaited(load(reset: true));
        },
      );
    }
    if (rechargeRecovery) {
      return RechargeRecoveryPanel(
        auth: widget.auth,
        language: widget.language,
        onBack: () {
          setState(() => rechargeRecovery = false);
          unawaited(load(reset: true));
        },
      );
    }
    if (rechargeCollect) {
      return RechargeCollectPanel(
        auth: widget.auth,
        language: widget.language,
        onBack: () {
          setState(() => rechargeCollect = false);
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
    if (cartDrafts) {
      return LiveCartDraftsPanel(
        auth: widget.auth,
        language: widget.language,
        revision: realtimeRevision,
        onBack: () {
          setState(() => cartDrafts = false);
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
    final data = snapshot;
    if (selectedDate != null) {
      return Column(
        children: [
          workspaceHeader(),
          Expanded(
            child: TableCalendarPanel(
              key: ValueKey(selectedDate),
              auth: widget.auth,
              language: widget.language,
              date: selectedDate!,
                revision: realtimeRevision,
            ),
          ),
        ],
      );
    }
    final focused = data?.tables
        .where((table) => table.reference == focusedTableRef)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (data == null) workspaceHeader(),
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
              : LayoutBuilder(
                  builder: (context, box) {
                    final scale = MediaQuery.textScalerOf(context)
                        .scale(1)
                        .clamp(1.0, 2.0);
                    final detailWidth = focused == null
                        ? 0.0
                        : box.maxWidth / 3;
                    final columns =
                        ((box.maxWidth - detailWidth - 24) /
                                ((focused == null ? 190 : 160) * scale))
                            .floor()
                            .clamp(1, 8);
                    final grid = Column(
                      children: [
                        workspaceHeader(),
                        if (data.tables.isEmpty) Text(t('liveNoTables')),
                        Expanded(
                          child: SwipeGrid(
                            key: ValueKey('table-page-$page'),
                            columns: columns,
                            tileHeight: (focused == null ? 124 : 104) * scale,
                            itemCount: data.tables.length,
                            itemBuilder: (context, index) =>
                                tableCard(data.tables[index], data.currency),
                            hasPrevious: page > 0,
                            hasNext: data.nextAfterTable != null,
                            loading: loading,
                            onPrevious: () => unawaited(load(target: page - 1)),
                            onNext: next,
                          ),
                        ),
                      ],
                    );
                    if (focused?.session != null &&
                        widget.auth.session?.permissions.contains(
                              'orders.read',
                            ) ==
                            true) {
                      final table = focused!;
                      final actions = Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: t('orderOperations'),
                            icon: const Icon(Icons.more_horiz),
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (dialogContext) => Dialog(
                                insetPadding: const EdgeInsets.all(24),
                                child: LiveOrdersPanel(
                                  auth: widget.auth,
                                  language: widget.language,
                                  table: table,
                                  revision: realtimeRevision,
                                  onBack: () => Navigator.pop(dialogContext),
                                ),
                              ),
                            ),
                          ),
                          if (widget.auth.session?.permissions.contains(
                                'table.clear',
                              ) ==
                              true)
                            IconButton(
                              key: ValueKey(
                                'tableClear-table-${table.reference}',
                              ),
                              tooltip: t('tableClearConfirm'),
                              icon: const Icon(
                                Icons.cleaning_services_outlined,
                              ),
                              onPressed: () => setState(() {
                                tableClear = true;
                                clearingTable = table;
                              }),
                            ),
                        ],
                      );
                      if (table.session!.status == 'open' &&
                          widget.auth.session?.permissions.contains(
                                'orders.create',
                              ) ==
                              true) {
                        return LiveOrderMembersPanel(
                          key: ValueKey(
                            'workspace-${table.session!.reference}',
                          ),
                          auth: widget.auth,
                          language: widget.language,
                          tableRef: table.reference,
                          sessionRef: table.session!.reference,
                          revision: realtimeRevision,
                          menuVisible: widget.menuVisible,
                          onMenuChanged: widget.onMenuChanged,
                          tablePanel: grid,
                          liveTable: table,
                          menuHeader: workspaceHeader(),
                          tableActions: actions,
                          onBack: () => setState(() => focusedTableRef = null),
                        );
                      }
                      return Row(
                        children: [
                          Expanded(flex: 2, child: grid),
                          Expanded(
                            flex: 1,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: TableBillPanel(
                                auth: widget.auth,
                                language: widget.language,
                                tableRef: table.reference,
                                sessionRef: table.session!.reference,
                                revision: realtimeRevision,
                                fillHeight: true,
                                leading: Row(
                                  children: [
                                    Expanded(child: Text(table.name)),
                                    actions,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: grid),
                        if (focused != null)
                          SizedBox(
                            width: detailWidth,
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(0, 4, 12, 8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: IconButton(
                                      key: const ValueKey('table-detail-back'),
                                      tooltip: t('ordersBack'),
                                      onPressed: () => setState(
                                        () => focusedTableRef = null,
                                      ),
                                      icon: const Icon(Icons.close),
                                    ),
                                  ),
                                  IgnorePointer(
                                    ignoring: loading,
                                    child: tableDetails(focused, data.currency),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget workspaceHeader() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            snapshot?.storeName ??
                widget.auth.session?.storeName ??
                t('tables'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
        ),
        if (realtime != null &&
            realtime!.state != CashierRealtimeState.connected)
          Text(
            t(
              realtime!.state == CashierRealtimeState.connecting
                  ? 'realtimeConnecting'
                  : 'realtimeOffline',
            ),
            style: const TextStyle(color: Color(0xffb45309), fontSize: 12),
          ),
        IconButton(
          key: const ValueKey('table-tools'),
          tooltip: t('tableTools'),
          onPressed: foreground ? showTools : null,
          icon: const Icon(Icons.more_horiz),
        ),
        if (selectedDate != null)
          TextButton(
            onPressed: () => setState(() => selectedDate = null),
            child: Text(t('ordersBack')),
          ),
        TextButton.icon(
          key: const ValueKey('table-calendar'),
          onPressed: () async {
            final now = DateTime.now();
            final date = await showDatePicker(
              context: context,
              builder: (context, child) => Localizations.override(
                context: context,
                locale: switch (widget.language) {
                  UiLanguage.zh => const Locale('zh', 'CN'),
                  UiLanguage.tw => const Locale('zh', 'TW'),
                  UiLanguage.en => const Locale('en'),
                  UiLanguage.th => const Locale('th'),
                },
                delegates: GlobalMaterialLocalizations.delegates,
                child: child,
              ),
              initialDate: selectedDate ?? now,
              firstDate: DateTime(2020),
              lastDate: DateTime(now.year + 3, 12, 31),
            );
            if (!mounted || date == null) return;
            setState(() {
              selectedDate = date;
              focusedTableRef = null;
            });
          },
          icon: const Icon(Icons.calendar_month_outlined, size: 18),
          label: Text(
            tableCalendarLabel(
              selectedDate ?? DateTime.now(),
              DateTime.now(),
              widget.language,
            ),
          ),
        ),
      ],
    ),
  );

  void showTools() {
    final toolsSession = widget.auth.session;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t('tableTools')),
        content: SizedBox(
          width: 640,
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: toolButtons()
                  .map(
                    (button) => OutlinedButton(
                      key: button.key,
                      onPressed: button.onPressed == null
                          ? null
                          : () {
                              Navigator.of(dialogContext).pop();
                              if (mounted &&
                                  foreground &&
                                  identical(
                                    widget.auth.session,
                                    toolsSession,
                                  )) {
                                button.onPressed!();
                              }
                            },
                      child: button.child!,
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(t('staffCancelSelection')),
          ),
        ],
      ),
    );
  }

  List<OutlinedButton> toolButtons() => [
    OutlinedButton(
      key: const ValueKey('live-refresh'),
      onPressed: loading
          ? null
          : () {
              setState(() => realtimeRevision++);
              unawaited(load(reset: true));
            },
      child: Text(t('liveRefresh')),
    ),
    if (const bool.fromEnvironment('CASHIER_VOUCHER_LOOKUP') &&
        [
          'voucher.douyin',
          'voucher.meituan',
        ].any((p) => widget.auth.session?.permissions.contains(p) == true))
      OutlinedButton(
        key: const ValueKey('voucher-lookup-open'),
        onPressed: foreground
            ? () => setState(() => voucherLookup = true)
            : null,
        child: Text(t('voucherLookupTitle')),
      ),
    if (const bool.fromEnvironment('CASHIER_VOUCHER_REPORT') &&
        widget.auth.session?.permissions.contains('report.read') == true)
      OutlinedButton(
        key: const ValueKey('voucher-report-open'),
        onPressed: foreground
            ? () => setState(() => voucherReport = true)
            : null,
        child: Text(t('voucherReportTitle')),
      ),
    if ([
      'payment.wechat',
      'payment.alipay',
      'payment.cash',
      'payment.balance',
    ].any(
      (permission) =>
          widget.auth.session?.permissions.contains(permission) == true,
    ))
      OutlinedButton(
        key: const ValueKey('table-checkout-recovery-open'),
        onPressed: foreground
            ? () => setState(() => tableCheckoutRecovery = true)
            : null,
        child: Text(t('tableCheckoutRecoveryTitle')),
      ),
    if (widget.auth.session?.permissions.contains('table.clear') == true)
      OutlinedButton(
        key: const ValueKey('tableClear-recovery-open'),
        onPressed: () => setState(() {
          tableClear = true;
          clearingTable = null;
        }),
        child: Text(t('tableClearRecoveryTitle')),
      ),
    if (widget.auth.session?.permissions.contains('orders.serve') == true)
      OutlinedButton(
        key: const ValueKey('serving-recovery-open'),
        onPressed: () => setState(() => servingRecovery = true),
        child: Text(t('servingRecoveryTitle')),
      ),
    if (widget.auth.session?.permissions.contains('orders.create') == true)
      OutlinedButton(
        key: const ValueKey('order-recovery-open'),
        onPressed: () => setState(() {
          orderRecovery = true;
        }),
        child: Text(t('orderRecoveryTitle')),
      ),
    if (widget.auth.session?.permissions.contains('orders.create') == true)
      OutlinedButton(
        key: const ValueKey('cart-drafts-open'),
        onPressed: () => setState(() => cartDrafts = true),
        child: Text(t('cartDraftsTitle')),
      ),
    if (const bool.fromEnvironment(
          'CASHIER_BALANCE_REFUND',
          defaultValue: false,
        ) &&
        widget.auth.session?.permissions.contains('payment.refund') == true)
      OutlinedButton(
        key: const ValueKey('balance-refund-recovery-open'),
        onPressed: () => setState(() => refundRecovery = true),
        child: Text(t('refundRecoveryTitle')),
      ),
    if (const bool.fromEnvironment(
          'CASHIER_STORE_RECHARGE',
          defaultValue: false,
        ) &&
        [
          'payment.wechat',
          'payment.alipay',
        ].any((p) => widget.auth.session?.permissions.contains(p) == true))
      OutlinedButton(
        key: const ValueKey('recharge-recovery-open'),
        onPressed: () => setState(() => rechargeRecovery = true),
        child: Text(t('rechargeRecoveryTitle')),
      ),
    if (const bool.fromEnvironment(
          'CASHIER_STORE_RECHARGE',
          defaultValue: false,
        ) &&
        [
          'payment.wechat',
          'payment.alipay',
        ].any((p) => widget.auth.session?.permissions.contains(p) == true))
      OutlinedButton(
        key: const ValueKey('recharge-collect-open'),
        onPressed: () => setState(() => rechargeCollect = true),
        child: Text(t('rechargeCollectTitle')),
      ),
    if (widget.auth.session?.permissions.contains('payment.cash') == true)
      OutlinedButton(
        key: const ValueKey('cash-recovery-open'),
        onPressed: () => setState(() {
          cashRecovery = true;
        }),
        child: Text(t('cashRecoveryTitle')),
      ),
    if ([
      'payment.wechat',
      'payment.alipay',
      'payment.balance',
    ].any((p) => widget.auth.session?.permissions.contains(p) == true))
      OutlinedButton(
        key: const ValueKey('provider-recovery-open'),
        onPressed: () => setState(() => providerRecovery = true),
        child: Text(t('provider_recovery')),
      ),
    if (widget.auth.session?.permissions.contains('orders.create') == true)
      OutlinedButton(
        key: const ValueKey('catalog-open'),
        onPressed: () => setState(() {
          catalog = true;
        }),
        child: Text(t('catalogTitle')),
      ),
    if (widget.auth.session?.permissions.contains('table.open') == true)
      OutlinedButton(
        key: const ValueKey('opening-pending'),
        onPressed: () => setState(() {
          opening = true;
          openingTable = null;
          openingCurrency = null;
        }),
        child: Text(t('openingPending')),
      ),
  ];

  Color tableColor(LiveTable table) => table.status != 'active'
      ? const Color(0xFF64748B)
      : table.session == null
      ? (table.reservation == null ? Colors.white : const Color(0xFFFACC15))
      : table.session!.status == 'clearing'
      ? const Color(0xFF15803D)
      : table.session!.temporaryHold || table.session!.pendingCents > 0
      ? const Color(0xFFDC2626)
      : const Color(0xFF1D4ED8);

  Widget tableCard(LiveTable table, String currency) {
    final session = table.session;
    final empty = table.status == 'active' && session == null;
    final textColor = empty ? const Color(0xFF263C30) : Colors.white;
    return Material(
      key: ValueKey('live-table-${table.reference}'),
      color: tableColor(table),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: empty ? const Color(0xFFABBCAF) : tableColor(table),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: loading
            ? null
            : () => setState(() => focusedTableRef = table.reference),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: DefaultTextStyle(
            style: TextStyle(color: textColor, fontSize: 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              table.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 23,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (session != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                tableOpeningLabel(
                                  session,
                                  widget.language,
                                  snapshot?.observedAt ?? DateTime.now(),
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      SizedBox(
                        width: 46,
                        child: Column(
                          children: [
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, bounds) {
                                  final visible = table.maximumSeats.clamp(
                                    0,
                                    12,
                                  );
                                  final rows = (visible / 3).ceil().clamp(1, 4);
                                  final size =
                                      ((bounds.maxHeight - (rows - 1) * 2) /
                                              rows)
                                          .clamp(4.0, 16.0) *
                                      0.875;
                                  return Wrap(
                                    spacing: 2,
                                    runSpacing: 2,
                                    children: [
                                      for (var i = 0; i < visible; i++)
                                        Container(
                                          key: ValueKey(
                                            'table-seat-${table.reference}-$i',
                                          ),
                                          width: size,
                                          height: size,
                                          color: i < (session?.partySize ?? 0)
                                              ? textColor.withValues(alpha: 0.9)
                                              : textColor.withValues(
                                                  alpha: 0.18,
                                                ),
                                        ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              t(table.stateLabel),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (table.tableMode != null &&
                              table.tableMode != 'manual')
                            Flexible(
                              child: Text(
                                ' (${t('tableKind_${table.tableMode}')})',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 10),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Tooltip(
                      message: t('tableConsumptionTotal'),
                      child: Text(
                        '${currency == 'CNY' ? '\u00a5' : currency} ${formatCents((session?.paidCents ?? 0) + (session?.pendingCents ?? 0))}',
                        key: ValueKey('table-total-${table.reference}'),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget tableDetails(LiveTable table, String currency) {
    final session = table.session;
    final active = table.status == 'active';
    final accent = !active
        ? const Color(0xFF737A77)
        : session == null
        ? const Color(0xFF68766F)
        : session.status == 'clearing'
        ? const Color(0xFFA45C20)
        : const Color(0xFF1E6550);
    final actions = <Widget>[
      if (session != null) ...[
        if (active &&
            session.status == 'open' &&
            widget.auth.session?.permissions.contains('orders.create') == true)
          OutlinedButton(
            key: ValueKey('order-members-open-${table.reference}'),
            onPressed: () => setState(() {
              focusedTableRef = null;
              orderingTable = table;
            }),
            child: Text(t('tableOrderStart')),
          ),
        if (active &&
            widget.auth.session?.permissions.contains('table.clear') == true)
          TextButton(
            key: ValueKey('tableClear-table-${table.reference}'),
            onPressed: () => setState(() {
              focusedTableRef = null;
              tableClear = true;
              clearingTable = table;
            }),
            child: Text(t('tableClearConfirm')),
          ),
      ],
      if (session == null &&
          active &&
          widget.auth.session?.permissions.contains('table.open') == true)
        OutlinedButton(
          key: ValueKey('opening-table-${table.reference}'),
          onPressed: () => setState(() {
            focusedTableRef = null;
            opening = true;
            openingTable = table.reference;
            openingCurrency = currency;
          }),
          child: Text(t('openingSubmit')),
        ),
    ];
    return Container(
      key: ValueKey('table-detail-${table.reference}'),
      decoration: BoxDecoration(
        color: session == null ? Colors.white : const Color(0xFFF0F7F3),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: session == null
              ? const Color(0xFFDBE3DE)
              : const Color(0xFFBCD4C7),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  table.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                t(table.stateLabel),
                style: TextStyle(color: accent, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '${t('guests')}: ${session?.partySize ?? '—'} / ${table.maximumSeats}',
            style: const TextStyle(color: Color(0xFF586B60)),
          ),
          const SizedBox(height: 6),
          if (session != null) ...[
            Text(
              '${t(session.paymentTiming == 'prepay' ? 'livePrepay' : 'livePostpay')} · ${t('elapsed')}: ${session.elapsedMinutes}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF586B60)),
            ),
            const SizedBox(height: 8),
            Text(
              '${t('livePaid')}: $currency ${formatCents(session.paidCents)}',
              style: const TextStyle(fontSize: 12),
            ),
            Text(
              '${t('livePending')}: $currency ${formatCents(session.pendingCents)}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
            if (session.refundedOrders > 0)
              Text(
                '${t('liveRefunded')}: $currency ${formatCents(session.refundedCents)} (${session.refundedOrders})',
                style: const TextStyle(fontSize: 12),
              ),
          ],
          const SizedBox(height: 16),
          if (actions.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 0, children: actions),
        ],
      ),
    );
  }
}

String tableOpeningLabel(
  TableSessionSnapshot session,
  UiLanguage language,
  DateTime observedAt,
) {
  String t(String key) => tr(language, key);
  final minutes = session.elapsedMinutes;
  final elapsed = minutes < 60
      ? '$minutes${t('tableMinutes')}'
      : minutes < 1440
      ? '${minutes ~/ 60}${t('tableHours')}'
      : '${minutes ~/ 1440}${t('tableDays')}';
  final opened = session.openedAt?.toLocal();
  if (opened == null) return '($elapsed)';
  final now = observedAt.toLocal();
  final days = DateTime.utc(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime.utc(opened.year, opened.month, opened.day)).inDays;
  final day = days == 0
      ? t('tableToday')
      : days == 1
      ? t('tableYesterday')
      : '${opened.year == now.year ? '' : '${opened.year}/'}${opened.month}/${opened.day}';
  final time =
      '${opened.hour.toString().padLeft(2, '0')}:${opened.minute.toString().padLeft(2, '0')}';
  return '$day $time ($elapsed)';
}
