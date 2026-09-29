import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/table_clear_command.dart';
import 'package:kingclub_cash_register/src/live/table_clear_journal.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'table_clear_command_test.dart' as s;
import 'staff_session_test.dart' as a;
import 'cash_command_test.dart' show Storage;

class Api extends a.TestApi {
  Api(this.storage);
  final Storage storage;
  final calls = <(String, Map<String, dynamic>)>[];
  Object? saved;
  bool loseResponse = false, rejectBeforeCommit = false, badReceipt = false;
  Completer<void>? gate;
  final sending = Completer<void>();
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    if (id == 'K260929001904') return super.call(id, params);
    calls.add((id, Map.of(params)));
    final raw = storage.data[TableClearJournal.storageKey];
    expect(raw, isNotNull);
    final command = PendingTableClear.decode(
      (jsonDecode(raw!)['entries'] as List).single,
    );
    if (id == 'K260929001922') {
      expect(params, command.lookup);
      return saved ??
          {
            'result': {'state': 'not_observed', 'requestId': command.requestId},
          };
    }
    expect(id, 'K260929001921');
    expect(params, command.params);
    if (!sending.isCompleted) sending.complete();
    if (gate != null) await gate!.future;
    if (rejectBeforeCommit) {
      throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    }
    saved = s.result(command);
    if (loseResponse) {
      throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    }
    if (badReceipt) {
      return {
        'result': {
          'state': 'confirmed',
          'requestId': command.requestId,
          'receipt': {...s.receipt(command), 'clearedBy': 'E00000000002'},
        },
      };
    }
    return saved;
  }
}

Future<StaffAuthController> controller(
  Storage storage,
  Api api, {
  DateTime Function()? now,
  bool allowed = true,
}) async {
  storage.data[SessionVault.deviceKey] = a.device;
  final auth = a.TestAuth()
    ..result = {
      ...a.response(),
      'permissions': ['workbench.read', if (allowed) 'table.clear'],
    };
  final value = StaffAuthController(
    vault: SessionVault(storage: storage),
    tableClearJournal: TableClearJournal(storage: storage),
    authFactory: (_) => auth,
    sessionFactory: (_) => api,
    now: now ?? () => a.now,
  );
  await value.login(
    base: 'https://service.invalid/prefix',
    storeRef: 'test-store',
    loginName: 'TEST_ONLY',
    password: 'TEST_ONLY',
  );
  return value;
}

Future<TableClearResult> submit(
  StaffAuthController auth, {
  bool confirmed = true,
}) => auth.confirmTableClear(
  tableRef: 'TEST_TABLE',
  sessionRef: 'H00000000001',
  confirmed: confirmed,
);

void main() {
  test(
    'durable original exists before network; verified receipt alone clears it',
    () async {
      final storage = Storage(),
          api = Api(storage),
          auth = await controller(storage, api);
      addTearDown(auth.dispose);
      expect((await submit(auth)).confirmed, true);
      expect(await auth.pendingTableClear(), isEmpty);
      expect(api.calls.map((e) => e.$1), ['K260929001921']);
    },
  );
  test('restart after lost response only looks up original and never repeats table closure', () async {
    final storage = Storage(),
        api = Api(storage)..loseResponse = true,
        auth = await controller(storage, api);
    await expectLater(submit(auth), s.fails('TRANSPORT_FAILED'));
    final id = (await auth.pendingTableClear()).single.requestId;
    auth.dispose();
    final nextApi = Api(storage)..saved = api.saved,
        next = await controller(storage, nextApi);
    addTearDown(next.dispose);
    expect((await next.recoverTableClear(id)).confirmed, true);
    expect(nextApi.calls.map((e) => e.$1), ['K260929001922']);
    expect(await next.pendingTableClear(), isEmpty);
  });
  test('not observed stays unresolved until explicitly retrying identical original parameters', () async {
    final storage = Storage(),
        api = Api(storage)..rejectBeforeCommit = true,
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    await expectLater(submit(auth), s.fails('TRANSPORT_FAILED'));
    final original = (await auth.pendingTableClear()).single;
    expect((await auth.recoverTableClear(original.requestId)).confirmed, false);
    expect(api.calls.map((e) => e.$1), ['K260929001921', 'K260929001922']);
    await expectLater(submit(auth), s.fails('TABLE_CLEAR_ALREADY_PENDING'));
    api.rejectBeforeCommit = false;
    expect(
      (await auth.recoverTableClear(
        original.requestId,
        retryOriginal: true,
      )).confirmed,
      true,
    );
    expect(api.calls.last.$2, original.params);
    expect(api.calls.map((e) => e.$1), [
      'K260929001921',
      'K260929001922',
      'K260929001922',
      'K260929001921',
    ]);
  });
  test('storage failure blocks network; missing confirmation and permission never save', () async {
    final storage = Storage(),
        api = Api(storage),
        auth = await controller(storage, api);
    addTearDown(auth.dispose);
    await expectLater(
      submit(auth, confirmed: false),
      s.fails('TABLE_CLEAR_CONFIRMATION_REQUIRED'),
    );
    storage.drop = true;
    await expectLater(submit(auth), s.fails('TABLE_CLEAR_JOURNAL_UNAVAILABLE'));
    expect(api.calls, isEmpty);
    storage.drop = false;
    final denied = await controller(storage, api, allowed: false);
    addTearDown(denied.dispose);
    await expectLater(submit(denied), s.fails('CASHIER_PERMISSION_DENIED'));
    expect(api.calls, isEmpty);
  });
  test(
    'bad success receipt stays recoverable and never becomes local success',
    () async {
      final storage = Storage(),
          api = Api(storage)..badReceipt = true,
          auth = await controller(storage, api);
      addTearDown(auth.dispose);
      await expectLater(submit(auth), s.fails('TABLE_CLEAR_RESPONSE_INVALID'));
      expect((await auth.pendingTableClear()).length, 1);
    },
  );
  test('concurrent operation rejected; dispose fences late reply and preserves original', () async {
    final storage = Storage(),
        api = Api(storage)..gate = Completer<void>(),
        auth = await controller(storage, api);
    final sending = submit(auth);
    final rejected = expectLater(sending, s.fails('SESSION_CHANGED'));
    await api.sending.future;
    await expectLater(submit(auth), s.fails('TABLE_CLEAR_IN_PROGRESS'));
    auth.dispose();
    api.gate!.complete();
    await rejected;
    expect(
      (await TableClearJournal(storage: storage).load(s.identity)).length,
      1,
    );
  });
  test('expiry before a call does not send or erase the original', () async {
    var now = a.now;
    final storage = Storage(),
        api = Api(storage)..rejectBeforeCommit = true,
        auth = await controller(storage, api, now: () => now);
    addTearDown(auth.dispose);
    await expectLater(submit(auth), s.fails('TRANSPORT_FAILED'));
    final id = (await auth.pendingTableClear()).single.requestId;
    now = a.now.add(const Duration(hours: 1));
    await expectLater(
      auth.recoverTableClear(id, retryOriginal: true),
      s.fails('SESSION_REQUIRED'),
    );
    expect(api.calls.length, 1);
    expect(
      (await TableClearJournal(storage: storage).load(s.identity)).length,
      1,
    );
  });
}
