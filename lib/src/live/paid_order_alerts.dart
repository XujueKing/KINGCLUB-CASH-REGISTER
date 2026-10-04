import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/staff_auth_controller.dart';
import '../network/cashier_realtime_client.dart';
import 'table_snapshot.dart';

/// Per-device acknowledgement; viewing one table never clears another table.
class PaidOrderAlerts extends ChangeNotifier {
  PaidOrderAlerts(this.auth);
  final StaffAuthController auth;
  final _storage = const FlutterSecureStorage();
  final Map<String, int> seen = {}, acknowledged = {};
  final Map<String, String> tables = {};
  CashierRealtimeClient? socket;
  Timer? timer;
  bool closed = false, reading = false, initialized = false;
  Future<void> writes = Future.value();
  String get key =>
      'paid-order-alerts-v1:${auth.session?.base}:${auth.session?.storeRef}';
  int get count => tables.values.toSet().where(hasTable).length;
  bool hasTable(String table) => tables.entries.any(
    (e) => e.value == table && (seen[e.key] ?? 0) > (acknowledged[e.key] ?? 0),
  );
  Future<void> start() async {
    try {
      final raw = await _storage.read(key: key);
      if (raw != null) {
        final data = jsonDecode(raw) as Map;
        seen.addAll(Map<String, int>.from(data['seen']));
        acknowledged.addAll(Map<String, int>.from(data['ack']));
        initialized = true;
      }
    } catch (_) {
      /* Fresh baseline if no device checkpoint is available. */
    }
    if (closed || auth.session == null) return;
    if (const bool.fromEnvironment('CASHIER_REALTIME')) {
      socket = CashierRealtimeClient(auth.session!);
      socket!.addListener(refresh);
      socket!.start();
    }
    timer = Timer.periodic(const Duration(seconds: 30), (_) => refresh());
    await refresh();
  }

  Future<void> refresh() async {
    if (closed || reading || auth.session == null) return;
    reading = true;
    final identity = auth.session!;
    try {
      final current = <LiveTable>[];
      String? cursor;
      final cursors = <String>{};
      do {
        final raw = await auth.readWorkbench(afterTable: cursor);
        if (closed || !identical(identity, auth.session)) return;
        final page = TableSnapshot.parse(
          raw,
          storeRef: identity.storeRef,
          employeeRef: identity.employeeRef,
          afterTable: cursor,
        );
        current.addAll(page.tables);
        cursor = page.nextAfterTable;
        if (cursor != null && !cursors.add(cursor)) return;
      } while (cursor != null);
      var sound = false;
      tables.clear();
      for (final table in current) {
        final session = table.session;
        if (session == null) continue;
        final id = session.reference, value = session.appPaidOrders;
        tables[id] = table.reference;
        if (!initialized) acknowledged[id] = value;
        if (initialized && value > (seen[id] ?? 0)) sound = true;
        // Refunds must not reset the acknowledgement watermark.
        if (value > (seen[id] ?? 0)) seen[id] = value;
      }
      initialized = true;
      seen.removeWhere((id, _) => !tables.containsKey(id));
      acknowledged.removeWhere((id, _) => !tables.containsKey(id));
      persist();
      notifyListeners();
      if (sound) {
        try {
          await const MethodChannel('cn.kingclub.cashier/order-alert')
              .invokeMethod<void>('play');
        } catch (_) {
          /* Visual alert remains available without audio hardware. */
        }
      }
    } catch (_) {
      /* Keep unread markers and retry after reconnect. */
    } finally {
      reading = false;
    }
  }

  void viewed(LiveTable table) {
    final session = table.session;
    if (session == null) return;
    final id = session.reference;
    if (session.appPaidOrders > (acknowledged[id] ?? 0)) {
      acknowledged[id] = session.appPaidOrders;
      persist();
      notifyListeners();
    }
  }

  void persist() {
    final target = key, value = jsonEncode({'seen': seen, 'ack': acknowledged});
    writes = writes
        .then((_) => _storage.write(key: target, value: value))
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    closed = true;
    timer?.cancel();
    socket?.dispose();
    super.dispose();
  }
}
