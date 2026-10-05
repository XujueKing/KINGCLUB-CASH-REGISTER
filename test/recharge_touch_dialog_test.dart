import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:kingclub_cash_register/src/live/receipt_accounts_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/recharge_touch_dialog.dart';
import 'package:kingclub_cash_register/src/live/recharge_journal.dart';
import 'package:kingclub_cash_register/src/live/recharge_result.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;
import 'staff_session_test.dart' show TestStorage;

const request = '00000000-0000-4000-8000-000000000009';

class RechargeAuth extends TableAuth {
  RechargeAuth()
    : super(
        permissions: [
          'workbench.read',
          'payment.cash',
          'payment.wechat',
          'payment.alipay',
        ],
      );
  final calls = <Map<String, dynamic>>[];
  bool lost = false, credited = false;
  List<String> accounts = ['Test bank sticker', 'Second QR'];
  String? collectedChannel;
  @override
  Future<Map<String, dynamic>> storeMembers(Map<String, dynamic> p) async {
    calls.add({...p});
    if (p['action'] == 'receiptAccounts')
      return {
        'receiptSettings': {'revision': 0, 'accounts': accounts},
      };
    if (p['action'] == 'receiptAccountsSave') {
      accounts = List<String>.from(p['receiptSettings']['accounts']);
      return {};
    }
    if (p['action'] == 'prepare')
      return {
        'rechargeRef': request,
        'channel': p['channel'],
        'principalCents': '100000',
        'giftCents': '10000',
      };
    if (p['action'] == 'cashConfirm') {
      credited = true;
      if (lost) {
        lost = false;
        throw StateError('response lost');
      }
    }
    return {'state': credited ? 'credited' : 'not_found'};
  }

  @override
  Future<List<RechargeCommand>> pendingRecharges(String channel) async => [];
  @override
  Future<RechargeResult> collectRecharge({
    required String rechargeRef,
    required String channel,
    required int principalCents,
    required String authCode,
    required bool Function() stillCurrent,
  }) async {
    collectedChannel = channel;
    return RechargeResult.parse(
      {
        'result': {
          'state': 'credited',
          'rechargeRef': request,
          'receipt': {
            'version': 1,
            'rechargeRef': request,
            'storeRef': 'test-store',
            'userAccount': 'TEST_MEMBER',
            'currency': 'CNY',
            'accountType': 'store_balance',
            'lotRef': request,
            'principalCents': '100000',
            'giftCents': '10000',
            'creditedAt': '2026-10-05T00:00:00.000Z',
          },
        },
      },
      storeRef: 'test-store',
      rechargeRef: request,
    );
  }
}

Future<void> open(
  WidgetTester t,
  RechargeAuth auth,
  TestStorage storage,
) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('kingclub/scanner'),
    (_) async => null,
  );
  t.view.physicalSize = const Size(1366, 768);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog(
              context: context,
              builder: (_) => RechargeTouchDialog(
                auth: auth,
                language: UiLanguage.en,
                member: const {
                  'userAccount': 'TEST_MEMBER',
                  'memberId': 'KM_TEST',
                  'nickname': 'Test',
                },
                campaigns: const [
                  {
                    'campaignRef': 'TEST_CAMPAIGN',
                    'revision': 1,
                    'principalCents': '100000',
                    'giftCents': '10000',
                  },
                ],
                newRequestId: () => request,
                storage: storage,
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await t.tap(find.text('Open'));
  await t.pumpAndSettle();
}

Future<void> employeeScan(WidgetTester t) async {
  await t.binding.defaultBinaryMessenger.handlePlatformMessage(
    'kingclub/scanner',
    const StandardMethodCodec().encodeSuccessEnvelope('KC:M:${'A' * 32}'),
    (_) {},
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets(
    'offer fills principal and gift; keyboard edits principal without inventing gift',
    (t) async {
      final a = RechargeAuth();
      await open(t, a, TestStorage());
      await t.tap(find.byKey(const ValueKey('recharge-offer-0')));
      await t.pump();
      expect(
        (t.widget<Text>(find.byKey(const ValueKey('recharge-amount')))).data,
        contains('1000.00'),
      );
      expect(find.text('Gift ¥ 100.00'), findsOneWidget);
      await t.tap(find.text('Clear amount'));
      await t.tap(find.byKey(const ValueKey('recharge-key-2')));
      await t.tap(find.byKey(const ValueKey('recharge-key-0')));
      await t.pump();
      expect(
        (t.widget<Text>(find.byKey(const ValueKey('recharge-amount')))).data,
        contains('20'),
      );
      expect(find.text('Gift ¥ 0.00'), findsOneWidget);
      expect(a.calls, isEmpty);
      await t.tap(find.byKey(const ValueKey('recharge-cash-pay')));
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(a.calls, isEmpty);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      a.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets(
    'cash response loss keeps original request and resolves once after reopening',
    (t) async {
      final a = RechargeAuth()..lost = true;
      final s = TestStorage();
      await open(t, a, s);
      await t.tap(find.byKey(const ValueKey('recharge-offer-0')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('recharge-cash-pay')));
      await t.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await employeeScan(t);
      await t.pumpAndSettle();
      expect(s.data.length, 1);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(find.text('Check receipt'), findsOneWidget);
      await t.tap(find.byIcon(Icons.close));
      await t.pumpAndSettle();
      await t.tap(find.text('Open'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const ValueKey('recharge-cash-pay')));
      await t.pumpAndSettle();
      expect(a.calls.where((p) => p['action'] == 'cashConfirm').length, 1);
      expect(
        a.calls.every(
          (p) =>
              p['requestId'] == request && p['targetAccount'] == 'TEST_MEMBER',
        ),
        isTrue,
      );
      expect(s.data, isEmpty);
      expect(find.byType(RechargeTouchDialog), findsNothing);
      await t.pumpWidget(const SizedBox());
      a.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets(
    'bank sticker requires employee scan and records receipt label separately',
    (t) async {
      final a = RechargeAuth();
      final s = TestStorage();
      await open(t, a, s);
      await t.tap(find.byKey(const ValueKey('recharge-offer-0')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('recharge-bank-pay')));
      await t.pumpAndSettle();
      expect(a.calls.map((p) => p['action']), ['receiptAccounts']);
      expect(find.byType(TextField), findsNothing);
      await employeeScan(t);
      expect(a.calls.where((p) => p['action'] == 'cashConfirm'), isEmpty);
      await t.tap(find.text('Test bank sticker'));
      await t.pumpAndSettle();
      await employeeScan(t);
      final confirmed = a.calls.singleWhere(
        (p) => p['action'] == 'cashConfirm',
      );
      expect(confirmed['channel'], 'bank_code');
      expect(confirmed['receivingAccount'], 'Test bank sticker');
      expect(confirmed['identityCode'], startsWith('KC:M:'));
      expect(s.data.values.join(), isNot(contains('KC:M:')));
      expect(find.byType(RechargeTouchDialog), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      a.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets('no configured receipt choices cannot confirm through scanner', (
    t,
  ) async {
    final a = RechargeAuth()..accounts = [];
    await open(t, a, TestStorage());
    await t.tap(find.byKey(const ValueKey('recharge-offer-0')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('recharge-bank-pay')));
    await t.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(
      find.text('Configure payment QR options in Settings first.'),
      findsOneWidget,
    );
    await employeeScan(t);
    expect(a.calls.where((p) => p['action'] == 'cashConfirm'), isEmpty);
    await t.pumpWidget(const SizedBox());
    a.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('settings maintains server-backed choices', (t) async {
    final a = RechargeAuth();
    t.view.physicalSize = const Size(1366, 768);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: ReceiptAccountsSettings(auth: a, language: UiLanguage.en),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Test bank sticker'), findsOneWidget);
    await t.enterText(find.byType(TextField), 'Third QR');
    await t.pump();
    await t.tap(find.text('Add'));
    await t.pump();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    final saved = a.calls.singleWhere(
      (p) => p['action'] == 'receiptAccountsSave',
    );
    expect(saved['receiptSettings'], {
      'revision': 0,
      'accounts': ['Test bank sticker', 'Second QR', 'Third QR'],
    });
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    a.dispose();
    debugDefaultTargetPlatformOverride = null;
  });
  for (final channel in ['wechat', 'alipay'])
    testWidgets(
      'one payment entry routes $channel and closes after confirmed credit',
      (t) async {
        final a = RechargeAuth();
        final s = TestStorage();
        await open(t, a, s);
        await t.tap(find.byKey(const ValueKey('recharge-offer-0')));
        await t.pump();
        await t.tap(find.byKey(const ValueKey('recharge-scan-pay')));
        await t.pumpAndSettle();
        await t.enterText(
          find.byType(TextField),
          channel == 'wechat' ? '130000000000000001' : '280000000000000001',
        );
        await t.testTextInput.receiveAction(TextInputAction.done);
        await t.pumpAndSettle();
        expect(a.collectedChannel, channel);
        expect(a.calls.single['campaignRef'], 'TEST_CAMPAIGN');
        expect(s.data, isEmpty);
        expect(find.byType(RechargeTouchDialog), findsNothing);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        a.dispose();
        debugDefaultTargetPlatformOverride = null;
      },
    );
}
