import 'bar_bill_header.dart';
import 'opening_snapshot.dart';
import 'bar_counter_strip.dart';
import 'quick_opening_dialog.dart';
import 'catalog_snapshot.dart';
import 'table_members_panel.dart';

import 'dart:async';
import 'dart:convert';

import '../auth/session_vault.dart';

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
import 'table_status_color.dart';
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
    this.onStoreName,
    required this.auth,
    required this.language,
    this.enableRealtime = const bool.fromEnvironment('CASHIER_REALTIME'),
    this.realtimeFactory,
  });
  final bool? menuVisible;
  final ValueChanged<bool>? onMenuChanged;
  final ValueChanged<String>? onStoreName;
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
  int? selectedBarSeat;
  final Map<String, CatalogProduct> initialBarProducts = {};
  final Set<String> barDrafts = {};
  bool emptyBarMenu = false;
  int selectedFloor = 1;

  int tableFloor(LiveTable table) =>
      {'C1', 'C2', 'K1', 'K2'}.contains(table.name.trim()) ||
          RegExp(r'^天字\s*(1|一|壹)\s*号$').hasMatch(table.name.trim())
      ? 2
      : 1;
  final List<List<String>> barGroups = [];
  String get barGroupKey =>
      'bar_groups_${widget.auth.session?.base}_${widget.auth.session?.storeRef}';
  Future<void> restoreBarGroups() async {
    try {
      final saved = await PlatformSecretStorage().read(barGroupKey);
      if (!mounted || saved == null) return;
      final groups = jsonDecode(saved);
      if (groups is! List || groups.length > 4) return;
      final parsed = <List<String>>[];
      for (final group in groups) {
        if (group is! List ||
            group.length < 2 ||
            group.length > 8 ||
            group.any(
              (s) =>
                  s is! String || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(s),
            ))
          return;
        parsed.add(group.cast<String>());
      }
      setState(
        () => barGroups
          ..clear()
          ..addAll(parsed),
      );
    } catch (_) {
      /* Display grouping is not payment evidence. */
    }
  }

  Future<void> saveBarGroups() async {
    try {
      await PlatformSecretStorage().write(barGroupKey, jsonEncode(barGroups));
    } catch (_) {
      /* Payment requests have their own durable journal. */
    }
  }

  String barText(String zh, String en, String tw, String th) =>
      [zh, en, tw, th][widget.language.index];
  List<LiveTable> mergedSeats(LiveTable? selected) {
    if (selected?.session == null) return [];
    final refs = barGroups
        .where((g) => g.contains(selected!.session!.reference))
        .firstOrNull;
    if (refs == null) return [];
    final seats =
        snapshot?.tables
            .where((t) => t.isBarSeat && refs.contains(t.session?.reference))
            .toList() ??
        <LiveTable>[];
    seats.sort((a, b) => a.barSeatNumber!.compareTo(b.barSeatNumber!));
    return seats.length == refs.length ? seats : [];
  }

  Future<void> mergeBarSeats(LiveTable current) async {
    final seats =
        snapshot?.tables
            .where(
              (t) =>
                  t.parentBarRef == current.parentBarRef &&
                  t.session?.status == 'open' &&
                  t.session?.businessDate == current.session?.businessDate &&
                  (t.session?.pendingCents ?? 0) > 0,
            )
            .toList() ??
        <LiveTable>[];
    seats.sort((a, b) => a.barSeatNumber!.compareTo(b.barSeatNumber!));
    final selected = {current.session!.reference};
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            barText('合并支付', 'Combine payment', '合併支付', 'รวมการชำระเงิน'),
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final seat in seats)
                  CheckboxListTile(
                    title: Text('B${seat.barSeatNumber}'),
                    secondary: Text(
                      '¥ ${formatCents(seat.session!.pendingCents)}',
                    ),
                    value: selected.contains(seat.session!.reference),
                    onChanged: seat.reference == current.reference
                        ? null
                        : (checked) => update(() {
                            if (checked == true)
                              selected.add(seat.session!.reference);
                            else
                              selected.remove(seat.session!.reference);
                          }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(t('cancel')),
            ),
            FilledButton(
              onPressed: selected.length < 2
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: Text(barText('合并', 'Combine', '合併', 'รวม')),
            ),
          ],
        ),
      ),
    );
    if (!mounted || approved != true) return;
    final chosen = seats
        .where((s) => selected.contains(s.session!.reference))
        .toList();
    setState(() {
      barGroups.removeWhere((g) => g.any(selected.contains));
      barGroups.add(chosen.map((s) => s.session!.reference).toList());
      focusedTableRef = chosen.first.reference;
      selectedBarSeat = chosen.first.barSeatNumber;
    });
    widget.onMenuChanged?.call(false);
    unawaited(saveBarGroups());
  }

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
  bool autoSeatPending = false;

  void selectDefaultBarSeat() {
    if (!autoSeatPending || snapshot == null) return;
    autoSeatPending = false;
    if (focusedTableRef != null) return;
    final seats =
        snapshot!.tables
            .where(
              (seat) =>
                  seat.isBarSeat &&
                  seat.status == 'active' &&
                  seat.reservation == null &&
                  !barDrafts.contains(seat.reference) &&
                  (seat.session == null ||
                      (seat.session!.status == 'open' &&
                          seat.session!.linkedMembers == 0 &&
                          !seat.session!.hasConsumption)),
            )
            .toList()
          ..sort((a, b) => a.barSeatNumber!.compareTo(b.barSeatNumber!));
    if (seats.isNotEmpty) {
      focusedTableRef = seats.first.reference;
      selectedBarSeat = seats.first.barSeatNumber;
      selectedDate = null;
      emptyBarMenu = true;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              barText(
                '吧台暂无空位，请选择桌台',
                'No free bar seat. Select a table.',
                '吧台暫無空位，請選擇桌台',
                'ไม่มีที่นั่งบาร์ว่าง กรุณาเลือกโต๊ะ',
              ),
            ),
          ),
        );
      });
    }
  }

  @override
  void didUpdateWidget(covariant LiveTablesPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.menuVisible == true && oldWidget.menuVisible != true) {
      autoSeatPending = focusedTableRef == null;
      selectDefaultBarSeat();
    }
  }

  @override
  void initState() {
    super.initState();
    autoSeatPending = widget.menuVisible == true;
    unawaited(restoreBarGroups());
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
      unawaited(load());
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
        selectDefaultBarSeat();
        page = requestedPage;
        loading = false;
      });
      widget.onStoreName?.call(value.storeName);
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
        if (loading && data == null) const LinearProgressIndicator(),
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
                    final ordinaryTables = data.tables
                        .where(
                          (t) =>
                              !t.isBarCounter &&
                              !t.isBarSeat &&
                              tableFloor(t) == selectedFloor,
                        )
                        .toList();
                    final counters = data.tables
                        .where((t) => t.isBarCounter)
                        .toList();
                    final grid = Column(
                      children: [
                        workspaceHeader(),
                        if (data.tables.isEmpty) Text(t('liveNoTables')),
                        Expanded(
                          child: SwipeGrid(
                            key: ValueKey(
                              'table-page-$page-floor-$selectedFloor',
                            ),
                            columns: columns,
                            tileHeight: (focused == null ? 124 : 104) * scale,
                            itemCount: ordinaryTables.length,
                            itemBuilder: (context, index) =>
                                tableCard(ordinaryTables[index], data.currency),
                            hasPrevious: page > 0,
                            hasNext: data.nextAfterTable != null,
                            loading: loading,
                            onPrevious: () => unawaited(load(target: page - 1)),
                            onNext: next,
                          ),
                        ),
                        for (final bar in counters) ...[
                          const Divider(height: 16, thickness: 1),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: BarCounterStrip(
                              table: bar,
                              draftSeats: {
                                for (final seat in data.tables.where(
                                  (s) =>
                                      s.parentBarRef == bar.reference &&
                                      barDrafts.contains(s.reference),
                                ))
                                  seat.barSeatNumber!,
                              },
                              groups: [
                                for (final refs in barGroups)
                                  if (data.tables
                                          .where(
                                            (t) =>
                                                t.parentBarRef ==
                                                    bar.reference &&
                                                refs.contains(
                                                  t.session?.reference,
                                                ),
                                          )
                                          .length ==
                                      refs.length)
                                    (data.tables
                                        .where(
                                          (t) =>
                                              t.parentBarRef == bar.reference &&
                                              refs.contains(
                                                t.session?.reference,
                                              ),
                                        )
                                        .map((t) => t.barSeatNumber!)
                                        .toList()
                                      ..sort()),
                              ],
                              seatTables: {
                                for (final seat in data.tables.where(
                                  (t) => t.parentBarRef == bar.reference,
                                ))
                                  seat.barSeatNumber!: seat,
                              },
                              seatAmounts: {
                                for (final seat in data.tables.where(
                                  (t) => t.parentBarRef == bar.reference,
                                ))
                                  seat.barSeatNumber!:
                                      (seat.session?.paidCents ?? 0) +
                                      (seat.session?.pendingCents ?? 0),
                              },
                              selectedSeat:
                                  focusedTableRef == bar.reference ||
                                      focused?.parentBarRef == bar.reference
                                  ? selectedBarSeat
                                  : null,
                              onSeat: (seat) {
                                final target = data.tables
                                    .where(
                                      (t) =>
                                          t.parentBarRef == bar.reference &&
                                          t.barSeatNumber == seat,
                                    )
                                    .firstOrNull;
                                if (target != null) {
                                  unawaited(selectBarSeat(target));
                                  return;
                                }
                                setState(() {
                                  focusedTableRef = bar.reference;
                                  selectedBarSeat = seat;
                                });
                                widget.onMenuChanged?.call(false);
                              },
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                      ],
                    );
                    if (focused?.isBarSeat == true &&
                        focused?.session == null) {
                      final seat = focused!;
                      final menu = widget.menuVisible ?? emptyBarMenu;
                      void showMenu(bool value) {
                        setState(() => emptyBarMenu = value);
                        widget.onMenuChanged?.call(value);
                      }

                      return Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: menu
                                ? LiveCatalogPanel(
                                    auth: widget.auth,
                                    language: widget.language,
                                    header: workspaceHeader(),
                                    paymentTiming: 'prepay',
                                    onBack: () => showMenu(false),
                                    canAdd: (p) =>
                                        !enteringBar &&
                                        p.inventoryKnown &&
                                        p.available > 0,
                                    onSelect: (p) =>
                                        unawaited(startBarProduct(seat, p)),
                                  )
                                : grid,
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: TableBillPanel(
                                auth: widget.auth,
                                language: widget.language,
                                tableRef: seat.reference,
                                sessionRef: '',
                                revision: 0,
                                emptySeat: true,
                                checkoutAllowed: false,
                                fillHeight: true,
                                headerBuilder: (filter) => BarBillHeader(
                                  number: seat.barSeatNumber!,
                                  color: Colors.white,
                                  language: widget.language,
                                  filter: filter,
                                  member: IconButton(
                                    key: const ValueKey('empty-bar-member'),
                                    onPressed: () => linkEmptyBarMember(seat),
                                    icon: const CircleAvatar(
                                      radius: 16,
                                      backgroundColor: Color(0xffdedede),
                                      child: Icon(
                                        Icons.person,
                                        color: Color(0xff9e9e9e),
                                        size: 23,
                                      ),
                                    ),
                                  ),
                                ),
                                orderAction: OutlinedButton(
                                  onPressed: () => showMenu(!menu),
                                  child: Text(
                                    menu ? t('ordersBack') : t('ordering'),
                                  ),
                                ),
                                primaryAction: FilledButton(
                                  onPressed: null,
                                  child: Text(t('billSettled')),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }
                    final combined = mergedSeats(focused);
                    if (combined.length > 1) {
                      final leader = combined.first;
                      final label = combined
                          .map((s) => 'B${s.barSeatNumber}')
                          .join('+');
                      return Row(
                        children: [
                          Expanded(flex: 2, child: grid),
                          const VerticalDivider(width: 1),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: TableBillPanel(
                                key: ValueKey(
                                  'bar-combined-${combined.map((s) => s.session!.reference).join('-')}',
                                ),
                                auth: widget.auth,
                                language: widget.language,
                                tableRef: leader.reference,
                                sessionRef: leader.session!.reference,
                                revision: realtimeRevision,
                                fillHeight: true,
                                changesAllowed: false,
                                seatSessions: [
                                  for (final seat in combined)
                                    {
                                      'tableRef': seat.reference,
                                      'sessionRef': seat.session!.reference,
                                    },
                                ],
                                headerBuilder: (filter) => Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            label,
                                            style: const TextStyle(
                                              fontSize: 22,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                        TextButton(
                                          onPressed: () {
                                            setState(
                                              () => barGroups.removeWhere(
                                                (g) => g.contains(
                                                  leader.session!.reference,
                                                ),
                                              ),
                                            );
                                            unawaited(saveBarGroups());
                                          },
                                          child: Text(
                                            barText(
                                              '分开显示',
                                              'Separate',
                                              '分開顯示',
                                              'แสดงแยก',
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            barText(
                                              '消费明细',
                                              'Bill',
                                              '消費明細',
                                              'รายการ',
                                            ),
                                          ),
                                        ),
                                        filter,
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }
                    if (focused?.isBarCounter == true &&
                        selectedBarSeat != null) {
                      return Row(
                        children: [
                          Expanded(flex: 2, child: grid),
                          const VerticalDivider(
                            width: 1,
                            thickness: 1,
                            color: Color(0xffd7e2dc),
                          ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 18,
                                        ),
                                        decoration: BoxDecoration(
                                          color: const Color(0xff64716b),
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Text(
                                          'B$selectedBarSeat',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 22,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      IconButton(
                                        onPressed: () => setState(
                                          () => focusedTableRef = null,
                                        ),
                                        icon: const Icon(Icons.close),
                                      ),
                                    ],
                                  ),
                                  const Divider(),
                                  Text(
                                    [
                                      '座位独立账单尚未启用',
                                      'Seat billing is not enabled yet',
                                      '座位獨立帳單尚未啟用',
                                      'ยังไม่เปิดใช้งานบิลแยกที่นั่ง',
                                    ][widget.language.index],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    }
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
                          initialProduct: initialBarProducts[table.reference],
                          onInitialProductConsumed: () =>
                              initialBarProducts.remove(table.reference),
                          onDraftChanged: (value) {
                            if (mounted &&
                                barDrafts.contains(table.reference) != value)
                              setState(() {
                                if (value)
                                  barDrafts.add(table.reference);
                                else
                                  barDrafts.remove(table.reference);
                              });
                          },
                          onMergePayment:
                              table.isBarSeat &&
                                  (table.session?.pendingCents ?? 0) > 0
                              ? () => mergeBarSeats(table)
                              : null,
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
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        Expanded(
          child: Row(
            children: [
              Text(
                t((widget.menuVisible ?? emptyBarMenu) ? 'ordering' : 'tables'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (!(widget.menuVisible ?? emptyBarMenu)) ...[
                const SizedBox(width: 14),
                for (final floor in [1, 2]) ...[
                  ChoiceChip(
                    key: ValueKey('table-floor-$floor'),
                    label: Text(
                      floor == 1
                          ? barText('一楼', '1F', '一樓', 'ชั้น 1')
                          : barText('二楼', '2F', '二樓', 'ชั้น 2'),
                    ),
                    selected: selectedFloor == floor,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => selectedFloor = floor),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ],
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
              initialDate: selectedDate ?? tableBusinessDay(now),
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
              selectedDate ?? tableBusinessDay(DateTime.now()),
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

  bool enteringBar = false;
  Future<String> ensureBarSession(LiveTable table) async {
    if (table.session != null) return table.session!.reference;
    final pending = await widget.auth.pendingOpenings();
    for (final request in pending.where((p) => p.tableId == table.reference)) {
      await widget.auth.recoverOpening(request.requestId, retryOriginal: true);
    }
    final opening = await widget.auth.readOpeningContext(
      tableId: table.reference,
    );
    if (opening.activeSessionRef == null) {
      final result = await widget.auth.submitOpening(
        context: opening,
        partySize: 1,
        memberRefs: [],
        arrivalConfirmed: true,
        reservationChecked: true,
        selectedRule: {'mode': 'manual'},
      );
      if (result.state != OpeningLookupState.confirmed)
        throw StateError('BAR_OPENING_PENDING');
    }
    await load();
    final session = snapshot?.tables
        .where((t) => t.reference == table.reference)
        .firstOrNull
        ?.session;
    if (session == null) throw StateError('BAR_SESSION_UNAVAILABLE');
    return session.reference;
  }

  Future<void> startBarProduct(LiveTable table, CatalogProduct product) async {
    if (enteringBar || !product.inventoryKnown || product.available < 1) return;
    setState(() => enteringBar = true);
    try {
      await ensureBarSession(table);
      if (!mounted) return;
      setState(() {
        initialBarProducts[table.reference] = product;
        focusedTableRef = table.reference;
        barDrafts.add(table.reference);
      });
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t('liveReadFailed'))));
    } finally {
      if (mounted) setState(() => enteringBar = false);
    }
  }

  Future<void> linkEmptyBarMember(LiveTable table) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(barText('关联会员', 'Link member', '關聯會員', 'เชื่อมโยงสมาชิก')),
        content: SizedBox(
          width: 400,
          child: TableMembersPanel(
            auth: widget.auth,
            language: widget.language,
            tableRef: table.reference,
            ensureSession: () => ensureBarSession(table),
            onLinked: () => Navigator.pop(dialogContext),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(t('cancel')),
          ),
        ],
      ),
    );
    if (mounted) await load();
  }

  Future<void> selectBarSeat(LiveTable table) async {
    if (enteringBar) return;
    selectedBarSeat = table.barSeatNumber;
    await selectTable(table);
  }

  Future<void> selectTable(LiveTable table) async {
    if (table.isBarCounter || table.isBarSeat) {
      if (table.status != 'active') return;
      setState(() {
        focusedTableRef = table.reference;
        emptyBarMenu = false;
      });
      widget.onMenuChanged?.call(false);
      return;
    }
    if (table.status == 'active' &&
        table.session == null &&
        widget.auth.session?.permissions.contains('table.open') == true) {
      final opened = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => QuickOpeningDialog(
          auth: widget.auth,
          table: table,
          language: widget.language,
        ),
      );
      if (!mounted || opened != true) return;
      await load();
      if (!mounted) return;
    }
    setState(() => focusedTableRef = table.reference);
  }

  Color tableColor(LiveTable table) => tableStatusColor(table);

  Widget tableCard(LiveTable table, String currency) {
    final selected = focusedTableRef == table.reference;
    final session = table.session;
    final empty = table.status == 'active' && session == null;
    final textColor = empty ? const Color(0xFF263C30) : Colors.white;
    return Material(
      key: ValueKey('live-table-${table.reference}'),
      color: tableColor(table),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: selected
              ? (tableColor(table) == Colors.white
                    ? const Color(0xff2563eb)
                    : Color.lerp(tableColor(table), Colors.black, 0.65)!)
              : empty
              ? const Color(0xFFABBCAF)
              : tableColor(table),
          width: selected ? 2 : 1,
        ),
      ),
      child: Ink(
        decoration: BoxDecoration(
          gradient: tableStatusGradient(tableColor(table)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: loading ? null : () => unawaited(selectTable(table)),
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
                              if (tableFloor(table) == 2)
                                Text(
                                  table.name.startsWith('K')
                                      ? 'KTV'
                                      : barText(
                                          '私人餐饮',
                                          'Private dining',
                                          '私人餐飲',
                                          'ห้องอาหารส่วนตัว',
                                        ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 10),
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
                          width: table.maximumSeats <= 12
                              ? 46
                              : table.maximumSeats <= 16
                              ? 62
                              : 78,
                          child: Column(
                            children: [
                              Expanded(
                                child: LayoutBuilder(
                                  builder: (context, bounds) {
                                    final visible = table.maximumSeats;
                                    final columns = visible <= 12
                                        ? 3
                                        : visible <= 16
                                        ? 4
                                        : 5;
                                    final rows = (visible / columns)
                                        .ceil()
                                        .clamp(1, 100);
                                    final size =
                                        ((bounds.maxHeight - (rows - 1) * 2) /
                                                rows)
                                            .clamp(0.0, 14.0)
                                            .clamp(
                                              0.0,
                                              (bounds.maxWidth -
                                                      (columns - 1) * 2) /
                                                  columns,
                                            );
                                    return Align(
                                      alignment: Alignment.topRight,
                                      child: SizedBox(
                                        width:
                                            columns * size + (columns - 1) * 2,
                                        child: Wrap(
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
                                                color:
                                                    i <
                                                        (session?.partySize ??
                                                            0)
                                                    ? textColor.withValues(
                                                        alpha: 0.9,
                                                      )
                                                    : textColor.withValues(
                                                        alpha: 0.18,
                                                      ),
                                              ),
                                          ],
                                        ),
                                      ),
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
