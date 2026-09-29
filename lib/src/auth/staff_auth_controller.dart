import 'package:flutter/foundation.dart';

import '../network/ccsop_client.dart';
import '../network/ccsop_crypto.dart';
import '../network/ccsop_handshake.dart';
import 'session_vault.dart';
import 'staff_session.dart';

/// Owns exactly one employee session. Saved projections are never accepted without a server refresh.
class StaffAuthController extends ChangeNotifier {
  StaffAuthController({
    SessionVault? vault,
    AuthChannel Function(String)? authFactory,
    SessionChannel Function(StaffSession)? sessionFactory,
    DateTime Function()? now,
  }) : _vault = vault ?? SessionVault(),
       _authFactory = authFactory ?? ((base) => CcsopHandshakeClient(base)),
       _sessionFactory =
           sessionFactory ??
           ((session) =>
               CcsopClient(session.base.toString(), session.credentials)),
       _now = now ?? DateTime.now;
  final SessionVault _vault;
  final AuthChannel Function(String) _authFactory;
  final SessionChannel Function(StaffSession) _sessionFactory;
  final DateTime Function() _now;
  StaffSession? _session;
  SessionChannel? _api;
  AuthChannel? _auth;
  int _epoch = 0;
  bool _busy = false, _disposed = false;
  String? _error;
  StaffSession? get session => _session;
  bool get busy => _busy;
  String? get errorCode => _error;
  bool _current(int epoch) => !_disposed && epoch == _epoch;
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _check(int epoch) {
    if (!_current(epoch)) throw const CcsopFailure('SESSION_CHANGED');
  }

  int _begin() {
    if (_disposed) throw const CcsopFailure('CLIENT_CLOSED');
    if (_busy) throw const CcsopFailure('AUTH_IN_PROGRESS');
    _busy = true;
    _error = null;
    final epoch = ++_epoch;
    _changed();
    return epoch;
  }

  Future<void> login({
    required String base,
    required String storeRef,
    required String loginName,
    required String password,
  }) async {
    if (_session != null) throw const CcsopFailure('LOGOUT_REQUIRED');
    final canonicalBase = serviceBase(base).toString();
    final epoch = _begin();
    try {
      await _vault.clear();
      _check(epoch);
      final device = await _vault.deviceId();
      _check(epoch);
      final auth = _authFactory(canonicalBase);
      _auth = auth;
      final result = await auth.call('K260929001901', {
        'loginName': loginName,
        'password': password,
        'storeRef': storeRef,
        'deviceId': device,
      });
      _check(epoch);
      final session = StaffSession.fromServer(
        result,
        base: canonicalBase,
        deviceId: device,
        expectedStore: storeRef,
        now: _now(),
      );
      await _install(session, epoch);
    } catch (error) {
      await _fail(error, epoch);
      rethrow;
    } finally {
      _finish(epoch);
    }
  }

  /// Call at cold start, or on foreground resume. No offline authenticated fallback.
  Future<void> restore() async {
    final epoch = _begin();
    final prior = _session;
    _session = null;
    _api?.close();
    _api = null;
    _changed();
    try {
      final saved = prior ?? await _vault.load(now: _now());
      _check(epoch);
      if (saved == null) return;
      final device = await _vault.deviceId();
      _check(epoch);
      if (device != saved.deviceId || !saved.canRefresh(_now())) {
        throw const CcsopFailure('SESSION_EXPIRED');
      }
      // Consume the local old token before submitting. A process crash cannot silently replay it later.
      await _vault.clear();
      _check(epoch);
      final auth = _authFactory(saved.base.toString());
      _auth = auth;
      final result = await auth.call('K260929001903', saved.refreshRequest());
      _check(epoch);
      final refreshed = StaffSession.fromServer(
        result,
        base: saved.base.toString(),
        deviceId: device,
        expectedStore: saved.storeRef,
        now: _now(),
      );
      if (refreshed.employeeRef != saved.employeeRef ||
          refreshed.sessionId != saved.sessionId ||
          refreshed.apiKeyId != saved.apiKeyId ||
          refreshed.refreshExpiresAt.isAfter(saved.refreshExpiresAt)) {
        throw const CcsopFailure('SESSION_IDENTITY_CHANGED');
      }
      await _install(refreshed, epoch);
    } catch (error) {
      await _fail(error, epoch);
      rethrow;
    } finally {
      _finish(epoch);
    }
  }

  Future<void> _install(StaffSession session, int epoch) async {
    _check(epoch);
    if (!await _vault.saveIfCurrent(session, () => _current(epoch))) {
      throw const CcsopFailure('SESSION_CHANGED');
    }
    _check(epoch);
    final api = _sessionFactory(session);
    _session = session;
    _api = api;
  }

  Future<void> _fail(Object error, int epoch) async {
    if (!_current(epoch)) return;
    _session = null;
    _api?.close();
    _api = null;
    _error = error is CcsopFailure ? error.code : 'AUTH_FAILED';
    try {
      await _vault.clear();
    } catch (_) {
      if (_current(epoch)) _error = 'SECURE_STORAGE_FAILED';
    }
  }

  void _finish(int epoch) {
    if (!_current(epoch)) return;
    _auth?.close();
    _auth = null;
    _busy = false;
    _changed();
  }

  Future<Object?> readWorkbench({String? afterTable}) async {
    final session = _session, api = _api, epoch = _epoch;
    if (session == null ||
        api == null ||
        _busy ||
        !session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    final value = await api.call('K260929001902', {
      'storeRef': session.storeRef,
      'afterTable': ?afterTable,
    });
    _check(epoch);
    return value;
  }

  /// Read-only, bound-store order query; late responses cannot survive a session change.
  Future<Object?> readOrders({
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) async {
    final session = _session, api = _api, epoch = _epoch;
    if (session == null ||
        api == null ||
        _busy ||
        !session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!session.permissions.contains('orders.read')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    final value = await api.call('K260929001905', {
      'storeRef': session.storeRef,
      'tableRef': tableRef,
      'sessionRef': sessionRef,
      'afterOrder': ?afterOrder,
    });
    _check(epoch);
    if (!session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    return value;
  }

  /// Always clears local identity immediately. false means remote revocation was not confirmed.
  Future<bool> logout() async {
    if (_disposed) throw const CcsopFailure('CLIENT_CLOSED');
    final epoch = ++_epoch, api = _api;
    _auth?.close();
    _auth = null;
    _session = null;
    _api = null;
    _busy = true;
    _error = null;
    _changed();
    var cleared = false, confirmed = false;
    try {
      try {
        await _vault.clear();
        cleared = true;
      } catch (_) {
        if (_current(epoch)) _error = 'SECURE_STORAGE_FAILED';
      }
      if (api != null) {
        try {
          final result = jsonObject(
            jsonObject(await api.call('K260929001904', {}))['result'],
          );
          confirmed = result['loggedOut'] == true;
          if (!confirmed && _current(epoch)) {
            _error ??= 'REMOTE_LOGOUT_UNCONFIRMED';
          }
        } catch (_) {
          if (_current(epoch)) _error ??= 'REMOTE_LOGOUT_UNCONFIRMED';
        }
      }
      if (!cleared) throw const CcsopFailure('SECURE_STORAGE_FAILED');
      return confirmed;
    } finally {
      api?.close();
      if (_current(epoch)) {
        _busy = false;
        _changed();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _auth?.close();
    _api?.close();
    _auth = null;
    _api = null;
    _session = null;
    super.dispose();
  }
}
