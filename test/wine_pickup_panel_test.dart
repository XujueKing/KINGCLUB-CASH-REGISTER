import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/wine_pickup_panel.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;
import 'wine_storage_dialog_test.dart' show MemoryStorage;

class PickupAuth extends TableAuth {
  final calls = <Map<String, dynamic>>[];
  bool loseReply = false;
  Map<String, dynamic>? receipt;
  @override
  Future<Map<String, dynamic>> wineStorage(Map<String, dynamic> p) async {
    calls.add(p);
    if (p['action'] == 'inventory')
      return {
        'state': 'inventory',
        'nickname': 'Member',
        'memberNumber': 'KM0000000001',
        'locations': ['A1-1'],
        'items': [
          {
            'itemRef': 'test-item',
            'name': 'Test wine',
            'quantity': 1,
            'remainingPercent': 50,
            'locationCode': 'A1-1',
            'specification': '750ml',
          },
        ],
      };
    if (p['action'] == 'collectionLookup')
      return receipt == null
          ? {'state': 'not_observed'}
          : {'state': 'confirmed', 'receipt': receipt};
    receipt = {
      'itemRef': 'test-item',
      'served': true,
      'collectedQuantity': 1,
      'quantity': 0,
      'name': 'Test wine',
    };
    if (loseReply) throw StateError('lost response');
    return {'state': 'confirmed', 'receipt': receipt};
  }
}

void main() {
  for (final lost in [false, true])
    testWidgets(
      'member then physical bottle, lost response $lost never repeats collection',
      (tester) async {
        final scans = StreamController<String>.broadcast(),
            auth = PickupAuth()..loseReply = lost,
            vault = MemoryStorage();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WinePickupPanel(
                auth: auth,
                language: UiLanguage.en,
                tableRef: 'test-table',
                sessionRef: 'H00000000001',
                scannerEvents: scans.stream,
                storage: vault,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        scans.add('KC:W:' + 'B' * 32);
        await tester.pumpAndSettle();
        expect(auth.calls.where((c) => c['action'] == 'collect'), isEmpty);
        scans.add('KC:M:' + 'A' * 32);
        await tester.pumpAndSettle();
        expect(find.textContaining('A1-1'), findsOneWidget);
        scans.add('KC:W:' + 'B' * 32);
        await tester.pumpAndSettle();
        if (lost) {
          expect(vault.values.values.single, isNot(contains('KC:M:')));
          await tester.tap(find.text('Retry lookup'));
          await tester.pumpAndSettle();
        }
        expect(find.textContaining('Collected and served:'), findsOneWidget);
        expect(auth.calls.where((c) => c['action'] == 'collect'), hasLength(1));
        expect(vault.values, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await scans.close();
        auth.dispose();
      },
    );
}
