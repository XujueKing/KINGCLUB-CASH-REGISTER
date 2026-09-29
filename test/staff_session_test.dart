import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_session.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/network/ccsop_handshake.dart';

final now = DateTime.utc(2026, 9, 29);
const device = '00000000-0000-4000-8000-000000000001';
Map<String, dynamic> response() => {
  'employee': {'employeeRef': 'E00000000001', 'displayName': '测试员工'},
  'storeRef': 'test-store',
  'sessionId': '00000000-0000-4000-8000-000000000002',
  'apiKeyId': '00000000-0000-4000-8000-000000000003',
  'apiKey': 'a' * 43,
  'refreshToken': 'b' * 43,
  'permissions': ['workbench.read'],
  'expiresAtMs': now.add(const Duration(minutes: 15)).millisecondsSinceEpoch,
  'refreshExpiresAtMs': now
      .add(const Duration(hours: 12))
      .millisecondsSinceEpoch,
};
StaffSession session([Map<String, dynamic>? data]) => StaffSession.fromServer(
  data ?? response(),
  base: 'https://service.invalid/prefix',
  deviceId: device,
  expectedStore: 'test-store',
  now: now,
);

// Test-only in-memory storage. Production must use platform encrypted storage, with no memory fallback.
class TestStorage implements SecretStorage {
  final data = <String, String>{};
  Completer<void>? gate;
  final writing = Completer<void>();
  bool fail = false;
  @override
  Future<String?> read(String key) async {
    if (fail) throw StateError('private storage error');
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (fail) throw StateError('private storage error');
    if (key == SessionVault.sessionKey && gate != null) {
      if (!writing.isCompleted) writing.complete();
      await gate!.future;
    }
    data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (fail) throw StateError('private storage error');
    data.remove(key);
  }
}

class TestAuth implements AuthChannel {
  Map<String, dynamic> result = response();
  Completer<void>? gate;
  final called = Completer<void>();
  String? id;
  Map<String, dynamic>? params;
  bool closed = false, fail = false;
  @override
  Future<Map<String, dynamic>> call(
    String interfaceId,
    Map<String, dynamic> params,
  ) async {
    id = interfaceId;
    this.params = params;
    if (!called.isCompleted) called.complete();
    if (gate != null) await gate!.future;
    if (fail) {
      throw const CcsopFailure('TRANSPORT_FAILED', deliveryUncertain: true);
    }
    return result;
  }

  @override
  void close() {
    closed = true;
  }
}

class TestApi implements SessionChannel {
  bool closed = false, confirmLogout = true;
  Completer<Object?>? pendingRead;
  Map<String, dynamic>? params;
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) async {
    this.params = params;
    if (id == 'K260929001904') {
      return {
        'result': {'loggedOut': confirmLogout},
      };
    }
    return pendingRead == null
        ? {
            'result': {'tables': []},
          }
        : pendingRead!.future;
  }

  @override
  void close() {
    closed = true;
  }
}

StaffAuthController controller(
  TestStorage storage,
  TestAuth auth,
  TestApi api,
) => StaffAuthController(
  vault: SessionVault(storage: storage),
  authFactory: (_) => auth,
  sessionFactory: (_) => api,
  now: () => now,
);
Future<void> login(StaffAuthController controller) => controller.login(
  base: 'https://service.invalid/prefix',
  storeRef: 'test-store',
  loginName: 'test-employee',
  password: 'TEST-ONLY-PASSWORD',
);

void main() {
  test(
    'order reads use the bound store and discard replies after logout',
    () async {
      final auth = TestAuth()
        ..result = {
          ...response(),
          'permissions': ['workbench.read', 'orders.read'],
        };
      final api = TestApi()..pendingRead = Completer<Object?>();
      final c = controller(TestStorage(), auth, api);
      await login(c);
      final pending = c.readOrders(
        tableRef: 'test-table',
        sessionRef: 'test-opening',
      );
      expect(api.params, {
        'storeRef': 'test-store',
        'tableRef': 'test-table',
        'sessionRef': 'test-opening',
      });
      final rejected = expectLater(pending, throwsA(isA<CcsopFailure>()));
      await c.logout();
      api.pendingRead!.complete({'result': {}});
      await rejected;
      c.dispose();
    },
  );
  test('workbench-only permission cannot issue an order request', () async {
    final api = TestApi();
    final c = controller(TestStorage(), TestAuth(), api);
    await login(c);
    await expectLater(
      c.readOrders(tableRef: 'test-table', sessionRef: 'test-opening'),
      throwsA(
        isA<CcsopFailure>().having(
          (e) => e.code,
          'code',
          'CASHIER_PERMISSION_DENIED',
        ),
      ),
    );
    expect(api.params, isNull);
    c.dispose();
  });
  test('refresh cannot switch employee or extend absolute expiry', () async {
    for (final changed in [
      {
        ...response(),
        'employee': {'employeeRef': 'E00000000002', 'displayName': '测试'},
      },
      {
        ...response(),
        'refreshExpiresAtMs': now
            .add(const Duration(days: 2))
            .millisecondsSinceEpoch,
      },
    ]) {
      final storage = TestStorage()..data[SessionVault.deviceKey] = device;
      storage.data[SessionVault.sessionKey] = session()
          .encodeForSecureStorage();
      final c = controller(storage, TestAuth()..result = changed, TestApi());
      await expectLater(
        c.restore(),
        throwsA(
          isA<CcsopFailure>().having(
            (e) => e.code,
            'identity',
            'SESSION_IDENTITY_CHANGED',
          ),
        ),
      );
      expect(c.session, isNull);
      expect(storage.data.containsKey(SessionVault.sessionKey), isFalse);
      c.dispose();
    }
  });
  test(
    'secure write failure never exposes an authenticated in-memory session',
    () async {
      final storage = TestStorage(),
          auth = TestAuth()..gate = Completer<void>();
      final c = controller(storage, auth, TestApi());
      final pending = login(c);
      await auth.called.future;
      storage.fail = true;
      final rejected = expectLater(pending, throwsA(isA<CcsopFailure>()));
      auth.gate!.complete();
      await rejected;
      expect(c.session, isNull);
      expect(c.errorCode, 'SECURE_STORAGE_FAILED');
      c.dispose();
    },
  );
  test(
    'logout reports storage deletion failure even if remote revoke succeeds',
    () async {
      final storage = TestStorage(), api = TestApi();
      final c = controller(storage, TestAuth(), api);
      await login(c);
      storage.fail = true;
      await expectLater(
        c.logout(),
        throwsA(
          isA<CcsopFailure>().having(
            (e) => e.code,
            'storage',
            'SECURE_STORAGE_FAILED',
          ),
        ),
      );
      expect(c.session, isNull);
      expect(api.closed, isTrue);
      c.dispose();
    },
  );
  test(
    'validates scope, permission, secrets and expiry; no secrets in toString',
    () {
      final valid = session();
      expect(valid.storeRef, 'test-store');
      expect(valid.toString(), isNot(contains('a' * 43)));
      for (final data in [
        {...response(), 'storeRef': 'other'},
        {
          ...response(),
          'permissions': ['workbench.read', 'admin'],
        },
        {...response(), 'apiKey': 'short'},
        {...response(), 'expiresAtMs': 0},
        {
          ...response(),
          'employee': {'employeeRef': 'U00000000001', 'displayName': '测试'},
        },
      ]) {
        expect(() => session(data), throwsA(isA<CcsopFailure>()));
      }
      expect(
        StaffSession.fromSecureStorage(
          valid.encodeForSecureStorage(),
          now: now,
        ).storeRef,
        'test-store',
      );
    },
  );
  test('installation ID is stable UUID and storage errors never fall back to plaintext', () async {
    final storage = TestStorage(), vault = SessionVault(storage: TestStorage());
    final id = await vault.deviceId();
    expect(uuidPattern.hasMatch(id), isTrue);
    expect(await vault.deviceId(), id);
    storage.fail = true;
    await expectLater(
      SessionVault(storage: storage).deviceId(),
      throwsA(
        isA<CcsopFailure>().having(
          (e) => e.code,
          'safe error',
          'SECURE_STORAGE_FAILED',
        ),
      ),
    );
  });
  test('late save after logout cannot leave a persisted session', () async {
    final storage = TestStorage()..gate = Completer<void>();
    final vault = SessionVault(storage: storage);
    var current = true;
    final saving = vault.saveIfCurrent(session(), () => current);
    await storage.writing.future;
    current = false;
    final clearing = vault.clear();
    storage.gate!.complete();
    expect(await saving, isFalse);
    await clearing;
    expect(storage.data[SessionVault.sessionKey], isNull);
  });
  test('corrupt or absolutely expired cached session is removed', () async {
    final storage = TestStorage(), vault = SessionVault(storage: TestStorage());
    storage.data[SessionVault.sessionKey] = 'not-json';
    expect(await SessionVault(storage: storage).load(now: now), isNull);
    expect(storage.data.containsKey(SessionVault.sessionKey), isFalse);
    await vault.saveIfCurrent(session(), () => true);
    expect(await vault.load(now: now.add(const Duration(hours: 13))), isNull);
  });
  test('login installs only validated and safely persisted session, never password', () async {
    final storage = TestStorage(), auth = TestAuth(), api = TestApi();
    final c = controller(storage, auth, api);
    await login(c);
    expect(c.session?.employeeRef, 'E00000000001');
    expect(c.busy, isFalse);
    expect(jsonEncode(storage.data), isNot(contains('TEST-ONLY-PASSWORD')));
    await c.readWorkbench();
    expect(api.params, {'storeRef': 'test-store'});
    expect(await c.logout(), isTrue);
    expect(storage.data.containsKey(SessionVault.sessionKey), isFalse);
    expect(c.session, isNull);
    expect(api.closed, isTrue);
    c.dispose();
  });
  test(
    'startup renews server authorization before exposing cached identity',
    () async {
      final storage = TestStorage()..data[SessionVault.deviceKey] = device;
      storage.data[SessionVault.sessionKey] = session()
          .encodeForSecureStorage();
      final auth = TestAuth()..gate = Completer<void>();
      final c = controller(storage, auth, TestApi());
      final restoring = c.restore();
      await auth.called.future;
      expect(c.session, isNull);
      expect(storage.data.containsKey(SessionVault.sessionKey), isFalse);
      expect(auth.id, 'K260929001903');
      auth.gate!.complete();
      await restoring;
      expect(c.session?.storeRef, 'test-store');
      c.dispose();
    },
  );
  test(
    'failed refresh cannot replay cached old token on next startup',
    () async {
      final storage = TestStorage()..data[SessionVault.deviceKey] = device;
      storage.data[SessionVault.sessionKey] = session()
          .encodeForSecureStorage();
      final auth = TestAuth()..fail = true;
      final c = controller(storage, auth, TestApi());
      await expectLater(c.restore(), throwsA(isA<CcsopFailure>()));
      expect(storage.data.containsKey(SessionVault.sessionKey), isFalse);
      expect(c.session, isNull);
      c.dispose();
    },
  );
  test('logout during login discards late credentials without resurrecting storage', () async {
    final storage = TestStorage(), auth = TestAuth()..gate = Completer<void>();
    final c = controller(storage, auth, TestApi());
    final signingIn = login(c);
    await auth.called.future;
    await c.logout();
    final rejected = expectLater(signingIn, throwsA(isA<CcsopFailure>()));
    auth.gate!.complete();
    await rejected;
    expect(c.session, isNull);
    expect(storage.data.containsKey(SessionVault.sessionKey), isFalse);
    c.dispose();
  });
  test('old table response is discarded on logout and cannot populate the next session', () async {
    final storage = TestStorage(),
        api = TestApi()..pendingRead = Completer<Object?>();
    final c = controller(storage, TestAuth(), api);
    await login(c);
    final reading = c.readWorkbench();
    await c.logout();
    final rejected = expectLater(reading, throwsA(isA<CcsopFailure>()));
    api.pendingRead!.complete({
      'result': {'tables': []},
    });
    await rejected;
    c.dispose();
  });
  test(
    'does not claim remote logout when server does not confirm it',
    () async {
      final c = controller(
        TestStorage(),
        TestAuth(),
        TestApi()..confirmLogout = false,
      );
      await login(c);
      expect(await c.logout(), isFalse);
      expect(c.errorCode, 'REMOTE_LOGOUT_UNCONFIRMED');
      c.dispose();
    },
  );
}
