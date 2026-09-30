import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'staff_session_test.dart' as staff;
import 'table_checkout_command_test.dart' as fixture;
import 'table_checkout_admission_test.dart' as admission;

class CheckoutApi extends staff.TestApi {
  CheckoutApi(this.storage);
  final staff.TestStorage storage;
  final calls = <String>[];
  Completer<Object?>? gate;
  final preparationCalled = Completer<void>();
  bool uncertain = false;
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    calls.add(id);
    if (id == 'K260930001938' && !preparationCalled.isCompleted) {
      preparationCalled.complete();
    }
    if (id == 'K260929001904') return super.call(id, params);
    if (id == 'K260930001937') return fixture.tableQuoteFixture();
    expect(storage.data.containsKey(TableCheckoutJournal.key), true);
    expect(params, fixture.command().params);
    if (uncertain) {
      throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    }
    return gate == null
        ? admission.admissionFixture(fixture.command())
        : gate!.future;
  }
}

StaffAuthController controller(staff.TestStorage storage, CheckoutApi api) =>
    StaffAuthController(
      vault: SessionVault(storage: staff.TestStorage()..data[SessionVault.deviceKey] = staff.device),
      authFactory: (_) => staff.TestAuth()
        ..result = {
          ...staff.response(),
          'permissions': ['workbench.read', 'payment.balance'],
        },
      sessionFactory: (_) => api,
      now: () => staff.now,
      tableCheckoutJournal: TableCheckoutJournal(storage: storage),
    );

void main() {
  test(
    'persists original before prepare, queries it without resending prepare',
    () async {
      final storage = staff.TestStorage(),
          api = CheckoutApi(storage),
          c = controller(storage, api);
      addTearDown(c.dispose);
      await staff.login(c);
      final q = await c.quoteTableCheckout(
        tableRef: 'TEST_TABLE',
        sessionRef: 'TEST_SESSION',
        channel: 'member_balance',
        accountType: 'store_balance',
      );
      expect(q.totalCents, 300);
      expect(
        (await c.prepareTableCheckout(
          fixture.command(),
          confirmed: true,
        )).observed,
        true,
      );
      await c.lookupTableCheckout(fixture.command());
      expect(api.calls, ['K260930001937', 'K260930001938', 'K260930001939']);
      expect(await c.pendingTableCheckouts('member_balance'), hasLength(1));
    },
  );
  test(
    'missing confirmation, original or storage prevents network preparation',
    () async {
      final storage = staff.TestStorage(),
          api = CheckoutApi(storage),
          c = controller(storage, api);
      addTearDown(c.dispose);
      await staff.login(c);
      await expectLater(
        c.prepareTableCheckout(fixture.command(), confirmed: false),
        throwsA(isA<CcsopFailure>()),
      );
      await expectLater(
        c.lookupTableCheckout(fixture.command()),
        throwsA(isA<CcsopFailure>()),
      );
      storage.fail = true;
      await expectLater(
        c.prepareTableCheckout(fixture.command(), confirmed: true),
        throwsA(isA<CcsopFailure>()),
      );
      expect(api.calls, isEmpty);
    },
  );
  test(
    'uncertain prepare retains original and does not retry automatically',
    () async {
      final storage = staff.TestStorage(),
          api = CheckoutApi(storage)..uncertain = true,
          c = controller(storage, api);
      addTearDown(c.dispose);
      await staff.login(c);
      await expectLater(
        c.prepareTableCheckout(fixture.command(), confirmed: true),
        throwsA(isA<CcsopFailure>()),
      );
      expect(api.calls, ['K260930001938']);
      expect(await c.pendingTableCheckouts('member_balance'), hasLength(1));
      api.uncertain = false;
      await c.lookupTableCheckout(fixture.command());
      expect(api.calls, ['K260930001938', 'K260930001939']);
    },
  );
  test(
    'logout rejects delayed admission but retains recovery record',
    () async {
      final storage = staff.TestStorage(),
          api = CheckoutApi(storage)..gate = Completer<Object?>(),
          c = controller(storage, api);
      addTearDown(c.dispose);
      await staff.login(c);
      final preparation = c.prepareTableCheckout(
        fixture.command(),
        confirmed: true,
      );
      final rejection = expectLater(preparation, throwsA(isA<CcsopFailure>()));
      // Wait for the existing request, without issuing another one.
      await api.preparationCalled.future.timeout(const Duration(seconds: 2));
      await c.logout();
      api.gate!.complete(admission.admissionFixture(fixture.command()));
      await rejection;
      expect(storage.data.containsKey(TableCheckoutJournal.key), true);
    },
  );
}
