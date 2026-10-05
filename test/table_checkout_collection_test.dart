import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_command.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as staff;
import 'table_checkout_command_test.dart' as fixture;
import 'table_checkout_admission_test.dart' as admission;
import 'table_checkout_result_test.dart' as settlement;

// Isolated test-only channel strings; no real provider or account is contacted.
class CollectionApi implements SessionChannel {
  CollectionApi(this.command);
  final TableCheckoutCommand command;
  final calls = <(String, Map<String, dynamic>)>[];
  String status = 'prepared', resultState = 'settled';
  bool uncertain = false;
  void Function()? afterLookup;
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    calls.add((id, Map.of(params)));
    if (id == 'K260930001939') {
      final raw = admission.admissionFixture(command);
      (raw['result'] as Map)['paymentStatus'] = status;
      afterLookup?.call();
      return raw;
    }
    if (uncertain) {
      throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    }
    if(resultState == 'closed_unpaid') return settlement.closureFixture(command);
    return resultState == 'settled'
        ? settlement.settlementFixture(command)
        : {
            'result': {
              'state': resultState,
              'checkoutRef': settlement.checkout,
            },
          };
  }

  @override
  void close() {}
}

String? code(String channel) => switch (channel) {
  'wechat' => '10${'0' * 16}',
  'alipay' => '25${'0' * 14}',
  'member_balance' => 'KCPAY1:${'a' * 43}',
  _ => null,
};

void main() {
  Future<StaffAuthController> setup(
    staff.TestStorage storage,
    CollectionApi api,
  ) async {
    await TableCheckoutJournal(storage: storage)
        .save(staff.session(), api.command);
    final controller = StaffAuthController(
      vault: SessionVault(storage: staff.TestStorage()..data[SessionVault.deviceKey] = staff.device),
      authFactory: (_) => staff.TestAuth()
        ..result = {
          ...staff.response(),
          'permissions': [
            'workbench.read',
            'payment.wechat',
            'payment.alipay',
            'payment.cash',
            'payment.balance',
          ],
        },
      sessionFactory: (_) => api,
      now: () => staff.now,
      tableCheckoutJournal: TableCheckoutJournal(storage: storage),
    );
    addTearDown(controller.dispose);
    await staff.login(controller);
    return controller;
  }

  test('explicit Alipay table close uses original lookup and preserves uncertainty', () async {
    final command=TableCheckoutCommand.decode({...fixture.command().encoded,'channel':'alipay','accountType':null});
    final storage=staff.TestStorage(),api=CollectionApi(command)..status='pending'..resultState='unknown';
    final controller=await setup(storage,api);
    final result=await controller.closeTableProvider(command,stillCurrent:()=>true);
    expect(result.resolved,false);
    expect(api.calls.map((e)=>e.$1),['K260930001939','K261002001963']);
    expect(api.calls.last.$2.keys.toSet(),{'storeRef','checkoutRef','channel','expectedTotalCents'});
    expect(await controller.pendingTableCheckouts('alipay'),hasLength(1));
  });
  test('verified unpaid closure removes only original recovery entry, without another payment', () async {
    final command=TableCheckoutCommand.decode({...fixture.command().encoded,'channel':'wechat','accountType':null});
    final storage=staff.TestStorage(),api=CollectionApi(command)..status='closed'..resultState='closed_unpaid';
    final controller=await setup(storage,api);
    final result=await controller.recoverTableCheckout(command,stillCurrent:()=>true);
    expect(result.closedUnpaid,true);expect(result.settled,false);
    expect(api.calls.map((e)=>e.$1),['K260930001939','K260930001941']);
    expect(await controller.pendingTableCheckouts('wechat'),isEmpty);
  });
  test('bank QR uses the original checkout, records employee and configured account, then clears journal', () async {
    final command=TableCheckoutCommand.decode({...fixture.command().encoded,'channel':'bank_code','accountType':null});
    final storage=staff.TestStorage(),api=CollectionApi(command),controller=await setup(storage,api);
    final result=await controller.collectTableCheckout(command,confirmed:true,stillCurrent:()=>true,
      cashReceivedCents:300,employeeIdentityCode:'KC:M:${'A' * 32}',receivingAccount:'TEST_BANK_QR');
    expect(result.settled,true);
    expect(api.calls.map((e)=>e.$1),['K260930001939','K260930001942']);
    expect(api.calls.last.$2['receivingAccount'],'TEST_BANK_QR');
    expect(api.calls.last.$2['identityCode'],'KC:M:${'A' * 32}');
    expect(await controller.pendingTableCheckouts('bank_code'),isEmpty);
    expect(storage.data.values.join(),isNot(contains('KC:M:')));
  });
  for (final channel in ['wechat', 'alipay', 'cash', 'member_balance']) {
    test(
      '$channel uses shared original lookup then one confirmation and removes settled record',
      () async {
        final command = TableCheckoutCommand.decode({
          ...fixture.command().encoded,
          'channel': channel,
          'accountType': channel == 'member_balance' ? 'store_balance' : null,
        });
        final storage = staff.TestStorage(),
            api = CollectionApi(command),
            controller = await setup(storage, api);
        final result = await controller.collectTableCheckout(
          command,
          confirmed: true,
          stillCurrent: () => true,
          payerCode: code(channel),
          employeeIdentityCode: 'KC:M:${'A' * 32}', cashReceivedCents: channel == 'cash' ? 400 : null,
        );
        expect(result.settled, true);
        final collectId = channel == 'cash'
            ? 'K260930001942'
            : channel == 'member_balance'
            ? 'K260930001944'
            : 'K260930001940';
        expect(api.calls.map((e) => e.$1), ['K260930001939', collectId]);
        final sent = api.calls.last.$2;
        expect(sent['checkoutRef'], settlement.checkout);
        expect(sent['expectedTotalCents'], 300);
        if (channel == 'cash') {
          expect(sent['receivedCents'], 400);
          expect(sent['cashReceivedConfirmed'], true);
        } else {
          expect(
            sent[channel == 'member_balance' ? 'paymentCode' : 'authCode'],
            code(channel),
          );
        }
        expect(await controller.pendingTableCheckouts(channel), isEmpty);
      },
    );
  }
  test(
    'already sent parent routes to recovery without resending a scanned code',
    () async {
      final command = fixture.command(),
          storage = staff.TestStorage(),
          api = CollectionApi(command)..status = 'paid';
      final controller = await setup(storage, api);
      await controller.collectTableCheckout(
        command,
        confirmed: true,
        stillCurrent: () => true,
        payerCode: code('member_balance'),
      );
      expect(api.calls.map((e) => e.$1), ['K260930001939', 'K260930001945']);
      expect(api.calls.last.$2.containsKey('paymentCode'), false);
    },
  );
  test('recovery of prepared cash never declares new cash received', () async {
    final command = TableCheckoutCommand.decode({
      ...fixture.command().encoded,
      'channel': 'cash',
      'accountType': null,
    });
    final storage = staff.TestStorage(),
        api = CollectionApi(command)..resultState = 'not_sent';
    final controller = await setup(storage, api);
    expect(
      (await controller.recoverTableCheckout(
        command,
        stillCurrent: () => true,
      )).settled,
      false,
    );
    expect(api.calls.map((e) => e.$1), ['K260930001939', 'K260930001943']);
    expect(api.calls.last.$2.containsKey('receivedCents'), false);
    expect(await controller.pendingTableCheckouts('cash'), hasLength(1));
  });
  test('unknown transport and settlement-pending retain original, never auto retry', () async {
    final command = fixture.command(),
        storage = staff.TestStorage(),
        api = CollectionApi(command)..uncertain = true;
    final controller = await setup(storage, api);
    await expectLater(
      controller.collectTableCheckout(
        command,
        confirmed: true,
        stillCurrent: () => true,
        payerCode: code('member_balance'),
      ),
      throwsA(isA<CcsopFailure>()),
    );
    expect(api.calls, hasLength(2));
    expect(
      await controller.pendingTableCheckouts('member_balance'),
      hasLength(1),
    );
    api.uncertain = false;
    api.resultState = 'settlement_pending';
    expect(
      (await controller.recoverTableCheckout(
        command,
        stillCurrent: () => true,
      )).settled,
      false,
    );
    expect(
      await controller.pendingTableCheckouts('member_balance'),
      hasLength(1),
    );
  });
  test(
    'page invalidation after original lookup prevents sending payment code',
    () async {
      final command = fixture.command(),
          storage = staff.TestStorage(),
          api = CollectionApi(command);
      var current = true;
      api.afterLookup = () => current = false;
      final controller = await setup(storage, api);
      await expectLater(
        controller.collectTableCheckout(
          command,
          confirmed: true,
          stillCurrent: () => current,
          payerCode: code('member_balance'),
        ),
        throwsA(isA<CcsopFailure>()),
      );
      expect(api.calls.map((e) => e.$1), ['K260930001939']);
      expect(
        await controller.pendingTableCheckouts('member_balance'),
        hasLength(1),
      );
    },
  );
}
