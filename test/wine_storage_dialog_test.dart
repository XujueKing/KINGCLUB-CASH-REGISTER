import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/live/wine_storage_dialog.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;

class MemoryStorage implements SecretStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String k) async => values[k];
  @override
  Future<void> write(String k, String v) async {
    values[k] = v;
  }

  @override
  Future<void> delete(String k) async {
    values.remove(k);
  }
}

class StorageAuth extends TableAuth {
  final requests = <Map<String, dynamic>>[];
  bool loseReply = false;
  Map<String, dynamic>? receipt;
  @override
  Future<Map<String, dynamic>> wineStorage(Map<String, dynamic> params) async {
    requests.add(params);
    if (params['action'] == 'context')
      return {
        'state': 'context',
        'availableQuantity': 2,
        'storedQuantity': 0,
        'storageDays': 30,
        'locations': ['A1-1', 'A6-4'],
      };
    if (params['action'] == 'lookup')
      return receipt == null
          ? {'state': 'not_observed'}
          : {'state': 'confirmed', 'receipt': receipt};
    receipt = {
      'locationCode': params['locationCode'],
      'quantity': params['quantity'],
      'remainingPercent': params['remainingPercent'],
    };
    if (loseReply) throw StateError('network reply lost');
    return {'state': 'confirmed', 'receipt': receipt};
  }
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('kingclub/scanner'),
          (_) async => null,
        );
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  for (final lost in [false, true]) {
    testWidgets(
      'scan deposits without another confirmation; lost reply $lost recovers',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        final auth = StorageAuth()..loseReply = lost, vault = MemoryStorage();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => WineStorageDialog(
                      auth: auth,
                      language: UiLanguage.zh,
                      tableRef: 'test-table',
                      sessionRef: 'H00000000001',
                      orderRef: 'D00000000001',
                      productRef: 'test-wine',
                      name: 'Test wine',
                      isCurrent: () => true,
                      storage: vault,
                    ),
                  ),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('OPEN'));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsNothing);
        await tester.tap(find.text('A1-1'));
        await tester.pumpAndSettle();
        expect(find.textContaining('30天'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, '存酒'));
        await tester.pumpAndSettle();
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'kingclub/scanner',
          const StandardMethodCodec().encodeSuccessEnvelope('KC:M:' + 'A' * 32),
          (_) {},
        );
        await tester.pumpAndSettle();
        if (lost) {
          expect(vault.values, isNotEmpty);
          expect(vault.values.values.single, isNot(contains('KC:M:')));
          await tester.tap(find.widgetWithText(FilledButton, '刷新'));
          await tester.pumpAndSettle();
        }
        expect(find.byType(WineStorageDialog), findsNothing);
        expect(
          auth.requests.where((r) => r['action'] == 'deposit'),
          hasLength(1),
        );
        expect(vault.values, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        auth.dispose();
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
