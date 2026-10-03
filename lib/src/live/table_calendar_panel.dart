import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'order_snapshot.dart';
import 'table_snapshot.dart';
import 'table_reservation_dialog.dart';

DateTime tableBusinessDay(DateTime now) {
  final local = now.toLocal().subtract(const Duration(hours: 6));
  return DateTime(local.year, local.month, local.day);
}

String tableCalendarLabel(DateTime date, DateTime now, UiLanguage language) {
  final businessToday = tableBusinessDay(now);
  final days = DateTime.utc(date.year, date.month, date.day)
      .difference(
        DateTime.utc(
          businessToday.year,
          businessToday.month,
          businessToday.day,
        ),
      )
      .inDays;
  final label = switch (days) {
    0 => tr(language, 'tableToday'),
    -1 => tr(language, 'tableYesterday'),
    1 => tr(language, 'tableTomorrow'),
    _ => '${date.year}/${date.month}/${date.day}',
  };
  return days == 0 ? '$label ${_time(now)}' : label;
}

String _time(DateTime value) {
  final d = value.toLocal();
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

/// Calendar is a read-only view of original sessions and orders, not a second till.
class TableCalendarPanel extends StatefulWidget {
  const TableCalendarPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.date,
    this.revision = 0,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final DateTime date;
  final int revision;
  @override
  State<TableCalendarPanel> createState() => _TableCalendarPanelState();
}

class _TableCalendarPanelState extends State<TableCalendarPanel>
    with WidgetsBindingObserver {
  final sessions = <Map<String, dynamic>>[];
  final orders = <LiveOrder>[];
  List<Map<String, dynamic>> reservations = [], tables = [];
  bool appReady = false;
  String? next, orderNext;
  Map<String, dynamic>? selected;
  bool loading = false, failed = false, foreground = true;
  int epoch = 0;
  String t(String key) => tr(widget.language, key);
  String get dateKey => widget.date.toIso8601String().substring(0, 10);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void didUpdateWidget(covariant TableCalendarPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision &&
        !loading &&
        selected == null &&
        foreground) {
      load();
    }
  }

  @override
  void dispose() {
    ++epoch;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    ++epoch;
    setState(() {
      sessions.clear();
      orders.clear();
      selected = null;
      loading = false;
    });
    if (foreground) load();
  }

  Future<void> load({bool more = false}) async {
    final identity = widget.auth.session, generation = ++epoch;
    if (identity == null || !foreground) return;
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final raw = await widget.auth.readTableCalendar(
        selectedDate: dateKey,
        afterSession: more ? next : null,
      );
      if (!mounted ||
          generation != epoch ||
          !identical(identity, widget.auth.session)) {
        return;
      }
      final result =
          (raw as Map<String, dynamic>)['result'] as Map<String, dynamic>;
      if (result['store']['storeRef'] != identity.storeRef ||
          result['operator']['employeeRef'] != identity.employeeRef ||
          result['selectedDate'] != dateKey ||
          result['reservationsAvailable'] != true) {
        throw const FormatException();
      }
      final rows = (result['historySessions'] as List)
          .cast<Map<String, dynamic>>();
      var previous = more ? next! : '';
      if (rows.length > 50) throw const FormatException();
      for (final row in rows) {
        final ref = row['sessionRef'] as String;
        if (ref.compareTo(previous) <= 0 ||
            !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(ref) ||
            !RegExp(r'^[A-Za-z0-9_-]{1,64}$')
                .hasMatch(row['tableRef'] as String) ||
            !{'open', 'clearing', 'closed'}.contains(row['status'])) {
          throw const FormatException();
        }
        DateTime.parse(row['openedAt'] as String);
        previous = ref;
      }
      final cursor = result['nextAfterSession'] as String?;
      if (cursor != null && (rows.length != 50 || cursor != previous)) {
        throw const FormatException();
      }
      setState(() {
        if (!more) sessions.clear();
        reservations = (result['reservations'] as List)
            .cast<Map<String, dynamic>>();
        tables = (result['availableTables'] as List)
            .cast<Map<String, dynamic>>();
        appReady = result['appReservationsAvailable'] == true;
        sessions.addAll(rows);
        next = cursor;
      });
    } catch (_) {
      if (mounted && generation == epoch) setState(() => failed = true);
    } finally {
      if (mounted && generation == epoch) setState(() => loading = false);
    }
  }

  Future<void> open(Map<String, dynamic> row, {bool more = false}) async {
    final identity = widget.auth.session, generation = ++epoch;
    if (identity == null || !foreground) return;
    setState(() {
      loading = true;
      failed = false;
      selected = row;
      if (!more) orders.clear();
    });
    try {
      final cursor = more ? orderNext : null;
      final raw = await widget.auth.readOrders(
        tableRef: row['tableRef'],
        sessionRef: row['sessionRef'],
        afterOrder: cursor,
      );
      if (!mounted ||
          generation != epoch ||
          !identical(identity, widget.auth.session)) {
        return;
      }
      final result = OrderSnapshot.parse(
        raw,
        storeRef: identity.storeRef,
        tableRef: row['tableRef'],
        sessionRef: row['sessionRef'],
        afterOrder: cursor,
      );
      setState(() {
        orders.addAll(result.orders);
        orderNext = result.nextAfterOrder;
      });
    } catch (_) {
      if (mounted && generation == epoch) setState(() => failed = true);
    } finally {
      if (mounted && generation == epoch) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final future = widget.date.isAfter(tableBusinessDay(now));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (loading) const LinearProgressIndicator(),
        if (selected == null &&
            widget.auth.session?.permissions.contains('table.open') == true &&
            !widget.date.isBefore(tableBusinessDay(now)))
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              onPressed: loading || tables.isEmpty
                  ? null
                  : () async {
                      final saved = await showDialog<bool>(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) => TableReservationDialog(
                          auth: widget.auth,
                          language: widget.language,
                          date: widget.date,
                          tables: tables,
                        ),
                      );
                      if (mounted && saved == true) load();
                    },
              icon: const Icon(Icons.add),
              label: Text(t('reserveTable')),
            ),
          ),
        if (selected == null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(t('tableHistoryDay')),
          ),
        if (selected != null)
          Row(
            children: [
              IconButton(
                onPressed: loading
                    ? null
                    : () => setState(() {
                        selected = null;
                        failed = false;
                      }),
                icon: const Icon(Icons.arrow_back),
              ),
              Text(
                '${selected!['tableName']} · ${_time(DateTime.parse(selected!['openedAt']))} · ${t('tableHistory')}',
              ),
            ],
          ),
        if (failed)
          TextButton(
            onPressed: loading
                ? null
                : () => selected == null ? load() : open(selected!),
            child: Text(t('liveReadFailed')),
          ),
        Expanded(
          child: ListView(
            children: selected == null
                ? [
                    if (!loading && !failed && !appReady)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(t('reserveAppPending')),
                      ),
                    for (final r in reservations)
                      Card(
                        color: const Color(0xFFFACC15),
                        child: ListTile(
                          title: Text(
                            '${r['tableName']} · ${r['guestName'] == '' ? t('reserveApp') : r['guestName']} · ${r['partySize']} ${t('reservePeople')}',
                          ),
                          subtitle: Text(
                            '${_time(DateTime.parse(r['startsAt']))} – ${_time(DateTime.parse(r['endsAt']))}',
                          ),
                          trailing:
                              r['source'] == 'app' ||
                                  widget.auth.session?.permissions.contains(
                                        'table.open',
                                      ) !=
                                      true
                              ? null
                              : TextButton(
                                  onPressed: loading
                                      ? null
                                      : () async {
                                          setState(() => loading = true);
                                          try {
                                            await widget.auth
                                                .saveTableReservation({
                                                  'action': 'cancel',
                                                  'tableRef': r['tableRef'],
                                                  'reservationRef':
                                                      r['reservationRef'],
                                                });
                                            if (mounted) await load();
                                          } catch (_) {
                                            if (mounted) {
                                              setState(() {
                                                loading = false;
                                                failed = true;
                                              });
                                            }
                                          }
                                        },
                                  child: Text(t('reserveCancel')),
                                ),
                        ),
                      ),
                    if (!loading &&
                        !failed &&
                        reservations.isEmpty &&
                        future &&
                        appReady)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(t('reserveNone')),
                      ),
                    if (!loading && !failed && sessions.isEmpty && !future)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(t('tableHistoryEmpty')),
                      ),
                    for (final row in sessions)
                      Card(
                        child: ListTile(
                          title: Text(
                            '${row['tableName']} · ${_time(DateTime.parse(row['openedAt']))}',
                          ),
                          subtitle: Text(
                            t(
                              row['status'] == 'closed'
                                  ? 'tableClosed'
                                  : row['status'] == 'clearing'
                                  ? 'cleaning'
                                  : 'tableOpen',
                            ),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: loading ? null : () => open(row),
                        ),
                      ),
                    if (next != null)
                      TextButton(
                        onPressed: loading ? null : () => load(more: true),
                        child: Text(t('tableMoreHistory')),
                      ),
                  ]
                : [
                    if (!loading && !failed && orders.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(t('ordersEmpty')),
                      ),
                    for (final order in orders)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '${_time(order.createdAt)} · ${t('order_${order.status}')} · ${order.currency} ${formatCents(order.totalCents)}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              for (final item in order.items)
                                Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Text(
                                    '${item.name(widget.language)}  × ${item.quantity}     ${formatCents(item.subtotalCents)}',
                                  ),
                                ),
                              if (order.refundedCents > 0)
                                Text(
                                  '${t('liveRefunded')} ${formatCents(order.refundedCents)}',
                                ),
                            ],
                          ),
                        ),
                      ),
                    if (orderNext != null)
                      TextButton(
                        onPressed: loading
                            ? null
                            : () => open(selected!, more: true),
                        child: Text(t('tableMoreHistory')),
                      ),
                  ],
          ),
        ),
      ],
    );
  }
}
