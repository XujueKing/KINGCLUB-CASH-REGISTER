import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kingclub_cash_register/src/live/paid_order_alerts.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';
import 'live_tables_panel_test.dart' show TableAuth;
import 'support/table_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('new payments ring once, stale viewing cannot clear newer orders, tables clear independently', () async {
    FlutterSecureStorage.setMockInitialValues({});
    var sounds = 0;
    const channel = MethodChannel('cn.kingclub.cashier/order-alert');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (_) async { sounds++; return null; });
    final auth = TableAuth();
    final raw = tableFixture(count: 2);
    final tables = raw['result']['tables'] as List;
    for (final t in tables) { t['session']['appPaidOrders'] = 2; }
    auth.reply = raw;
    final alerts = PaidOrderAlerts(auth);
    await alerts.refresh();
    expect(alerts.count, 0);
    for (final t in tables) { t['session']['appPaidOrders'] = 3; }
    await alerts.refresh();
    await alerts.refresh();
    expect(sounds, 1);
    expect(alerts.count, 2);
    final old = LiveTable(Map<String,dynamic>.from(tables[0]));
    tables[0]['session']['appPaidOrders'] = 4;
    await alerts.refresh();
    alerts.viewed(old);
    expect(alerts.count, 2);
    alerts.viewed(LiveTable(Map<String,dynamic>.from(tables[0])));
    expect(alerts.hasTable('test-000'), false);
    expect(alerts.hasTable('test-001'), true);
    expect(sounds, 2);
    await alerts.writes;
    alerts.dispose(); auth.dispose();
  });
}
