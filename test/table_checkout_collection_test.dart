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
          cashReceivedCents: channel == 'cash' ? 400 : null,
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
