import '../auth/staff_auth_controller.dart';
import 'order_snapshot.dart';
import 'table_snapshot.dart';

/// Reuses the calendar and original order reads; never creates a second bill.
class TableHistoryData {
  TableHistoryData(this.snapshot, this.sessions, this.bills);
  final TableSnapshot snapshot;
  final List<Map<String, dynamic>> sessions;
  final Map<String, ({OrderSnapshot snapshot, List<LiveOrder> orders})> bills;

  List<Map<String, String>> scopes(String tableRef) => [
    for (final row in sessions.where((r) => r['tableRef'] == tableRef))
      {'tableRef': tableRef, 'sessionRef': row['sessionRef'] as String},
  ];

  static Future<TableHistoryData> read(
    StaffAuthController auth,
    TableSnapshot current,
    String date,
  ) async {
    final identity = auth.session!;
    final rows = <Map<String, dynamic>>[];
    final definitions = <String, Map<String, dynamic>>{};
    final reservations = <Map<String, dynamic>>[];
    String? after;
    do {
      final raw = await auth.readTableCalendar(
        selectedDate: date,
        afterSession: after,
      );
      final result = (raw as Map)['result'] as Map;
      if (!identical(identity, auth.session) ||
          result['store']['storeRef'] != identity.storeRef ||
          result['operator']['employeeRef'] != identity.employeeRef ||
          result['selectedDate'] != date)
        throw const FormatException();
      final page = (result['historySessions'] as List)
          .cast<Map<String, dynamic>>();
      var previous = after ?? '';
      for (final row in page) {
        final ref = row['sessionRef'] as String;
        if (ref.compareTo(previous) <= 0 ||
            !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(ref))
          throw const FormatException();
        previous = ref;
      }
      rows.addAll(page);
      after = result['nextAfterSession'] as String?;
      if (after != null && (page.length != 50 || after != previous))
        throw const FormatException();
      for (final table
          in (result['availableTables'] as List).cast<Map<String, dynamic>>()) {
        definitions[table['tableRef'] as String] = table;
      }
      if (reservations.isEmpty)
        reservations.addAll(
          (result['reservations'] as List).cast<Map<String, dynamic>>(),
        );
    } while (after != null);

    final bills = <String, List<LiveOrder>>{};
    final snapshots = <String, OrderSnapshot>{};
    final timing = <String, String>{};
    // A few independent reads at a time, including every page of each session.
    for (var start = 0; start < rows.length; start += 4) {
      await Future.wait(
        rows.skip(start).take(4).map((row) async {
          final orders = <LiveOrder>[];
          String? cursor;
          do {
            final raw = await auth.readOrders(
              tableRef: row['tableRef'],
              sessionRef: row['sessionRef'],
              afterOrder: cursor,
            );
            if (!identical(identity, auth.session))
              throw const FormatException();
            final page = OrderSnapshot.parse(
              raw,
              storeRef: identity.storeRef,
              tableRef: row['tableRef'],
              sessionRef: row['sessionRef'],
              afterOrder: cursor,
            );
            orders.addAll(page.orders);
            timing[row['sessionRef']] = page.paymentTiming;
            snapshots[row['sessionRef']] = page;
            cursor = page.nextAfterOrder;
          } while (cursor != null);
          bills[row['sessionRef']] = orders;
        }),
      );
    }
    // Include retired tables that still have a session on this business day.
    for (final row in rows) {
      definitions.putIfAbsent(
        row['tableRef'],
        () => {
          'tableRef': row['tableRef'],
          'tableName': row['tableName'],
          'maximumSeats': row['partySize'] ?? 0,
        },
      );
    }
    final tables = <LiveTable>[];
    final tableBills =
        <String, ({OrderSnapshot snapshot, List<LiveOrder> orders})>{};
    final orderedRefs = <String>{
      for (final table in current.tables)
        if (definitions.containsKey(table.reference)) table.reference,
      ...definitions.keys,
    };
    for (final ref in orderedRefs) {
      final definition = definitions[ref]!;
      final live = current.tables.where((t) => t.reference == ref).firstOrNull;
      final sessions = rows.where((r) => r['tableRef'] == ref).toList()
        ..sort(
          (a, b) =>
              (a['openedAt'] as String).compareTo(b['openedAt'] as String),
        );
      final orders = [for (final row in sessions) ...bills[row['sessionRef']]!];
      final last = sessions.lastOrNull;
      if (last != null) {
        tableBills[ref] = (
          snapshot: snapshots[last['sessionRef']]!,
          orders: List.unmodifiable(orders),
        );
      }
      final refunded = orders.where((o) => o.refundedCents > 0).toList();
      tables.add(
        LiveTable({
          'tableRef': ref,
          'tableName': last?['tableName'] ?? definition['tableName'],
          'tableStatus': 'active',
          'minimumSeats': null,
          'maximumSeats': definition['maximumSeats'],
          'parentBarRef': live?.parentBarRef,
          'barSeatNumber': live?.barSeatNumber,
          'aaParty': reservations
              .where((r) => r['tableRef'] == ref)
              .firstOrNull?['aaParty'],
          'reservation': reservations
              .where((r) => r['tableRef'] == ref)
              .firstOrNull,
          'session': last == null
              ? null
              : {
                  'sessionRef': last['sessionRef'],
                  'status': last['status'],
                  'paymentTiming': timing[last['sessionRef']],
                  'businessDate': date,
                  'partySize': last['partySize'],
                  'partyRevision': 0,
                  'openedAt': last['openedAt'],
                  'elapsedMinutes': 0,
                  'paidCents': orders.fold<int>(
                    0,
                    (sum, o) => sum + o.netPaidCents,
                  ),
                  'pendingCents': orders
                      .where((o) => o.status == 'pending')
                      .fold<int>(0, (sum, o) => sum + o.totalCents),
                  'paidOrders': orders.where((o) => o.status == 'paid').length,
                  'pendingOrders': orders
                      .where((o) => o.status == 'pending')
                      .length,
                  'refundedCents': refunded.fold<int>(
                    0,
                    (sum, o) => sum + o.refundedCents,
                  ),
                  'refundedOrders': refunded.length,
                  'hasConsumption': orders.isNotEmpty,
                },
        }),
      );
    }
    return TableHistoryData(
      TableSnapshot.history(current, date, tables),
      rows,
      tableBills,
    );
  }
}
