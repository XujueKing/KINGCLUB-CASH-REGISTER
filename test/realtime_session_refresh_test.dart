import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/live_tables_panel.dart';
import 'package:kingclub_cash_register/src/live/paid_order_alerts.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show PanelRealtime;
import 'staff_refresh_workspace_test.dart' show RefreshAuth;

class TrackingRealtime extends PanelRealtime {
  TrackingRealtime(super.session);
  bool closed = false;
  @override
  void dispose() {
    closed = true;
    super.dispose();
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
    'tables rotate realtime credentials without replacing page state',
    (tester) async {
      tester.view.physicalSize = const Size(1366, 768);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = RefreshAuth();
      final clients = <TrackingRealtime>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveTablesPanel(
              auth: auth,
              language: UiLanguage.en,
              enableRealtime: true,
              realtimeFactory: (session) {
                final client = TrackingRealtime(session);
                clients.add(client);
                return client;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final state = tester.state(find.byType(LiveTablesPanel));
      expect(clients.single.running, isTrue);
      auth.begin();
      await tester.pump();
      expect(clients.length, 1);
      auth.finish();
      await tester.pumpAndSettle();
      expect(clients.length, 2);
      expect(clients.first.closed, isTrue);
      expect(clients.last.session, same(auth.session));
      expect(clients.last.running, isTrue);
      expect(tester.state(find.byType(LiveTablesPanel)), same(state));
      final reads = auth.fixture.requested.length;
      clients.last.changed();
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(auth.fixture.requested.length, greaterThan(reads));
      auth.revoke();
      await tester.pump();
      expect(clients.last.closed, isTrue);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );

  testWidgets('paid order alerts rotate credentials and close on revocation', (
    tester,
  ) async {
    final auth = RefreshAuth();
    final clients = <TrackingRealtime>[];
    final alerts = PaidOrderAlerts(
      auth,
      enableRealtime: true,
      realtimeFactory: (session) {
        final client = TrackingRealtime(session);
        clients.add(client);
        return client;
      },
    );
    await alerts.start();
    expect(clients.single.running, isTrue);
    auth.begin();
    expect(clients.length, 1);
    auth.finish();
    await tester.pump();
    expect(clients.length, 2);
    expect(clients.first.closed, isTrue);
    expect(clients.last.session, same(auth.session));
    expect(clients.last.running, isTrue);
    auth.revoke();
    expect(clients.last.closed, isTrue);
    alerts.dispose();
    auth.dispose();
  });
}
