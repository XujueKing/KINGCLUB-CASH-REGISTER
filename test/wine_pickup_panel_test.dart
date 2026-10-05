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
    if (p['action'] == 'requestPickup')
      return {
        'state': 'requested',
        'locations': ['A1-1'],
        'receipt': {
          'itemRef': 'test-item',
          'name': 'Test wine',
          'quantity': 1,
          'remainingPercent': 50,
          'locationCode': 'A1-1',
          'paid': true,
          'served': false,
        },
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
  testWidgets('registration has no reprint button and cannot directly collect', (tester) async {
    final auth=PickupAuth(), scans=StreamController<String>.broadcast();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WinePickupPanel(auth:auth, language:UiLanguage.en,tableRef:'test-table',sessionRef:'H00000000001',scannerEvents:scans.stream,storage:MemoryStorage()))));
    await tester.pumpAndSettle();scans.add('X'*43);await tester.pumpAndSettle();
    expect(find.text('Print label'),findsNothing);
    scans.add('KC:W:'+'B'*32);await tester.pumpAndSettle();
    expect(auth.calls.where((c)=>c['action']=='collect'),isEmpty);
    await tester.pumpWidget(const SizedBox());await scans.close();auth.dispose();
  });
  for(final lost in [false,true]) testWidgets('serve requires button and bottle, lost reply $lost', (tester) async {
    final auth=PickupAuth()..loseReply=lost, scans=StreamController<String>.broadcast(),vault=MemoryStorage();
    await tester.pumpWidget(MaterialApp(home: Builder(builder:(context)=>Scaffold(body:TextButton(onPressed:()=>showDialog(context:context,builder:(_)=>AlertDialog(content:WinePickupPanel(auth:auth,language:UiLanguage.en,tableRef:'test-table',sessionRef:'H00000000001',scannerEvents:scans.stream,storage:vault,bottleItem:{'itemRef':'test-item','name':'Test wine','locationCode':'A1-1'}))),child:const Text('Open'))))));
    await tester.tap(find.text('Open'));await tester.pumpAndSettle();
    expect(find.text('A1-1'),findsOneWidget);
    scans.add('KC:W:'+'B'*32);await tester.pumpAndSettle();expect(auth.calls,isEmpty);
    await tester.tap(find.text('Serve'));await tester.pumpAndSettle();
    scans.add('KC:W:'+'B'*32);await tester.pumpAndSettle();
    if(lost){await tester.tap(find.text('Retry lookup'));await tester.pumpAndSettle();}
    expect(find.byType(AlertDialog),findsNothing);
    expect(auth.calls.where((c)=>c['action']=='collect'),hasLength(1));
    expect(auth.calls.firstWhere((c)=>c['action']=='collect')['itemRef'],'test-item');
    expect(vault.values,isEmpty);expect(tester.takeException(),isNull);
    await tester.pumpWidget(const SizedBox());await scans.close();auth.dispose();
  });
}
