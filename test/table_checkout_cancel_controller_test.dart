import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_command.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as staff;
import 'table_checkout_command_test.dart' as fixture;
import 'table_checkout_admission_test.dart' as admission;
import 'table_checkout_cancellation_test.dart' show cancellationFixture;

class CancelApi implements SessionChannel {
  CancelApi(this.command);
  final TableCheckoutCommand command;
  final calls = <String>[];
  String status = 'prepared';
  bool uncertain = false;
  void Function()? afterLookup;
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    calls.add(id);
    if (id == 'K260930001939') {
      final raw = admission.admissionFixture(command);
      raw['result']['paymentStatus'] = status;
      afterLookup?.call();
      return raw;
    }
    expect(params.containsKey('currency'), false);
    expect(params.containsKey('paymentCode'), false);
    expect(params.containsKey('employeeRef'), false);
    expect(params.containsKey('cancellationConfirmed'), id == 'K260930001946');
    if (uncertain) {
      throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    }
    return cancellationFixture(command);
  }

  @override
  void close() {}
}

void main() {
  Future<StaffAuthController> setup(
    staff.TestStorage storage,
    CancelApi api,
  ) async {
    final journal = TableCheckoutJournal(storage: storage);
    await journal.save(staff.session(), api.command);
    final controller = StaffAuthController(
      vault: SessionVault(storage: staff.TestStorage()..data[SessionVault.deviceKey] = staff.device),
      authFactory: (_) => staff.TestAuth()
        ..result = {
          ...staff.response(),
          'permissions': ['workbench.read', 'payment.balance'],
        },
      sessionFactory: (_) => api,
      now: () => staff.now,
      tableCheckoutJournal: journal,
    );
    addTearDown(controller.dispose);
    await staff.login(controller);
    return controller;
  }

  for (final queryOnly in [false, true]) {
    test(
      'original cancel/query performs one operation and acknowledges validated receipt: queryOnly=$queryOnly',
      () async {
        final command = fixture.command(),
            api = CancelApi(command),
            storage = staff.TestStorage();
        final controller = await setup(storage, api);
        final result = queryOnly
            ? await controller.lookupTableCancellation(
                command,
                stillCurrent: () => true,
              )
            : await controller.cancelTableCheckout(
                command,
                confirmed: true,
                stillCurrent: () => true,
              );
        expect(result.cancelled, true);
        expect(api.calls, [
          'K260930001939',
          queryOnly ? 'K260930001947' : 'K260930001946',
        ]);
        expect(
          await controller.pendingTableCheckouts(command.channel),
          isEmpty,
        );
      },
    );
  }
  for (final status in ['pending', 'unknown', 'paid', 'settled', 'closed']) {
    test('nonprepared original only queries cancellation: $status', () async {
      final command = fixture.command(),
          api = CancelApi(fixture.command())..status = status;
      final controller = await setup(staff.TestStorage(), api);
      await controller.cancelTableCheckout(
        command,
        confirmed: true,
        stillCurrent: () => true,
      );
      expect(api.calls, ['K260930001939', 'K260930001947']);
    });
  }
  test(
    'uncertain cancellation keeps original and never automatically retries',
    () async {
      final command = fixture.command(),
          api = CancelApi(command)..uncertain = true,
          storage = staff.TestStorage();
      final controller = await setup(storage, api);
      await expectLater(
        controller.cancelTableCheckout(
          command,
          confirmed: true,
          stillCurrent: () => true,
        ),
        throwsA(isA<CcsopFailure>()),
      );
      expect(api.calls, ['K260930001939', 'K260930001946']);
      expect(
        await controller.pendingTableCheckouts(command.channel),
        hasLength(1),
      );
    },
  );
  test(
    'page invalidation during original lookup prevents cancellation send',
    () async {
      var current = true;
      final command = fixture.command(),
          api = CancelApi(command)..afterLookup = () => current = false,
          storage = staff.TestStorage();
      final controller = await setup(storage, api);
      await expectLater(
        controller.cancelTableCheckout(
          command,
          confirmed: true,
          stillCurrent: () => current,
        ),
        throwsA(isA<CcsopFailure>()),
      );
      expect(api.calls, ['K260930001939']);
      expect(
        await controller.pendingTableCheckouts(command.channel),
        hasLength(1),
      );
    },
  );
}
