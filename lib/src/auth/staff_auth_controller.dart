import 'package:flutter/foundation.dart';

import '../live/catalog_snapshot.dart';
import '../live/order_context_snapshot.dart';
import '../live/order_command.dart';
import '../live/order_journal.dart';

import '../live/opening_snapshot.dart';
import '../live/opening_journal.dart';
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
    OpeningJournal? openingJournal,
    OrderJournal? orderJournal,
  }) : _vault = vault ?? SessionVault(),
       _authFactory = authFactory ?? ((base) => CcsopHandshakeClient(base)),
       _sessionFactory =
           sessionFactory ??
           ((session) =>
               CcsopClient(session.base.toString(), session.credentials)),
       _now = now ?? DateTime.now,
       _openingJournal = openingJournal ?? OpeningJournal(),
       _orderJournal = orderJournal ?? OrderJournal();
  final OrderJournal _orderJournal;
  bool _orderBusy = false;
  final OpeningJournal _openingJournal;
  bool _openingBusy = false;
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

  Future<CatalogSnapshot> readCatalog({
    String? categoryRef,
    String? afterProduct,
  }) async {
    final session = _session, api = _api, epoch = _epoch;
    if (session == null ||
        api == null ||
        _busy ||
        !session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!session.permissions.contains('orders.create')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    final raw = await api.call('K260929001910', {
      'storeRef': session.storeRef,
      'categoryRef': ?categoryRef,
      'afterProduct': ?afterProduct,
    });
    _check(epoch);
    if (!session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    return CatalogSnapshot.parse(
      raw,
      storeRef: session.storeRef,
      categoryRef: categoryRef,
      afterProduct: afterProduct,
    );
  }

  Future<OrderContextSnapshot> readOrderContext({
    required String tableRef,
    required String sessionRef,
    String? afterMember,
  }) async {
    final session = _session, api = _api, epoch = _epoch;
    if (session == null ||
        api == null ||
        _busy ||
        !session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!session.permissions.contains('orders.create')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    final raw = await api.call('K260929001911', {
      'storeRef': session.storeRef,
      'tableRef': tableRef,
      'sessionRef': sessionRef,
      'afterMember': ?afterMember,
    });
    _check(epoch);
    if (!session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    return OrderContextSnapshot.parse(
      raw,
      storeRef: session.storeRef,
      tableRef: tableRef,
      sessionRef: sessionRef,
      afterMember: afterMember,
    );
  }

  StaffSession _orderIdentity() {
    final identity = _session;
    if (_disposed ||
        identity == null ||
        _api == null ||
        _busy ||
        !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!identity.permissions.contains('orders.create')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    return identity;
  }

  Future<T> _orderOperation<T>(Future<T> Function() operation) async {
    if (_orderBusy) throw const CcsopFailure('ORDER_IN_PROGRESS');
    _orderBusy = true;
    try {
      return await operation();
    } finally {
      _orderBusy = false;
    }
  }

  Future<List<PendingOrder>> pendingOrders() async {
    final identity = _orderIdentity(), epoch = _epoch;
    final entries = await _orderJournal.load(identity);
    _check(epoch);
    _orderIdentity();
    return entries;
  }

  Future<OrderRequestResult> submitOrder({
    required OrderContextSnapshot context,
    required String memberRef,
    required List<OrderSelection> items,
    required bool confirmed,
  }) => _orderOperation(() async {
    if (!confirmed) throw const CcsopFailure('ORDER_CONFIRMATION_REQUIRED');
    final identity = _orderIdentity(), epoch = _epoch;
    final command = PendingOrder.prepare(
      identity: identity,
      context: context,
      memberRef: memberRef,
      items: items,
      now: _now(),
    );
    // No packet is sent until encrypted persistence and exact readback both succeed.
    await _orderJournal.save(command, identity);
    _check(epoch);
    _orderIdentity();
    return _orderCall('K260929001912', command, identity, epoch);
  });

  Future<OrderRequestResult> _orderCall(
    String interfaceId,
    PendingOrder command,
    StaffSession identity,
    int epoch,
  ) async {
    _check(epoch);
    _orderIdentity();
    if (!command.belongsTo(identity)) {
      throw const CcsopFailure('ORDER_SCOPE_CHANGED');
    }
    final raw = await _api!.call(
      interfaceId,
      interfaceId == 'K260929001912' ? command.params : command.lookup,
    );
    _check(epoch);
    _orderIdentity();
    final result = OrderRequestResult.parse(
      raw,
      command,
      submission: interfaceId == 'K260929001912',
    );
    if (result.state != OrderRequestState.notObserved) {
      await _orderJournal.acknowledge(identity, result);
      _check(epoch);
      _orderIdentity();
    }
    return result;
  }

  Future<PendingOrder> _pendingOrder(
    String requestId,
    StaffSession identity,
    int epoch,
  ) async {
    final entries = await _orderJournal.load(identity);
    _check(epoch);
    _orderIdentity();
    final matches = entries.where((e) => e.requestId == requestId).toList();
    if (matches.length != 1) {
      throw const CcsopFailure('ORDER_PENDING_NOT_FOUND');
    }
    return matches.single;
  }

  /// Read-only by default. An explicit retry reuses the stored command, never the current cart.
  Future<OrderRequestResult> recoverOrder(
    String requestId, {
    bool retryOriginal = false,
  }) => _orderOperation(() async {
    final identity = _orderIdentity(), epoch = _epoch;
    final command = await _pendingOrder(requestId, identity, epoch);
    final result = await _orderCall('K260929001913', command, identity, epoch);
    if (result.state == OrderRequestState.notObserved && retryOriginal) {
      return _orderCall('K260929001912', command, identity, epoch);
    }
    return result;
  });

  /// Cancels only an uncommitted command. A confirmed result must be presented as an existing order.
  Future<OrderRequestResult> cancelOrder(
    String requestId, {
    required bool confirmed,
  }) => _orderOperation(() async {
    if (!confirmed) throw const CcsopFailure('ORDER_CONFIRMATION_REQUIRED');
    final identity = _orderIdentity(), epoch = _epoch;
    final command = await _pendingOrder(requestId, identity, epoch);
    final result = await _orderCall('K260929001914', command, identity, epoch);
    if (result.state == OrderRequestState.notObserved) {
      throw const CcsopFailure('ORDER_RESULT_UNCONFIRMED');
    }
    return result;
  });

  Future<OpeningContext> readOpeningContext({required String tableId}) async {
    final session = _session, epoch = _epoch;
    final raw = await _callOpening('K260929001907', {'tableId': tableId});
    _check(epoch);
    return OpeningContext.parse(
      raw,
      storeRef: session!.storeRef,
      tableId: tableId,
    );
  }

  Future<OpeningLookup> readOpeningReceipt({
    required String tableId,
    required String requestId,
  }) async {
    final session = _session, epoch = _epoch;
    final raw = await _callOpening('K260929001908', {
      'tableId': tableId,
      'requestId': requestId,
    });
    _check(epoch);
    return OpeningLookup.parse(
      raw,
      storeRef: session!.storeRef,
      tableId: tableId,
      requestId: requestId,
    );
  }

  Future<Object?> _callOpening(
    String interfaceId,
    Map<String, dynamic> params,
  ) async {
    final session = _session, api = _api, epoch = _epoch;
    if (session == null ||
        api == null ||
        _busy ||
        !session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!session.permissions.contains('table.open')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    final value = await api.call(interfaceId, {
      ...params,
      'storeRef': session.storeRef,
    });
    _check(epoch);
    if (!session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    return value;
  }

  StaffSession _openingIdentity() {
    final identity = _session;
    if (identity == null || _busy || !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!identity.permissions.contains('table.open')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    return identity;
  }

  Future<List<PendingOpening>> pendingOpenings() async {
    final identity = _openingIdentity(), epoch = _epoch;
    final pending = await _openingJournal.load(identity);
    _check(epoch);
    _openingIdentity();
    return pending;
  }

  Future<T> _openingOperation<T>(Future<T> Function() operation) async {
    if (_openingBusy) throw const CcsopFailure('OPENING_IN_PROGRESS');
    _openingBusy = true;
    try {
      return await operation();
    } finally {
      _openingBusy = false;
    }
  }

  /// Explicit user command only. No transport error clears the journal or retries.
  Future<OpeningLookup> submitOpening({
    required OpeningContext context,
    required int? partySize,
    required List<String> memberRefs,
    required bool arrivalConfirmed,
    required bool reservationChecked,
  }) => _openingOperation(() async {
    final identity = _openingIdentity(), epoch = _epoch;
    final pending = PendingOpening.prepare(
      session: identity,
      context: context,
      partySize: partySize,
      memberRefs: memberRefs,
      arrivalConfirmed: arrivalConfirmed,
      reservationChecked: reservationChecked,
    );
    await _openingJournal.save(pending, identity);
    _check(epoch);
    _openingIdentity();
    return _sendOpening(pending, identity, epoch);
  });

  Future<OpeningLookup> _sendOpening(
    PendingOpening pending,
    StaffSession identity,
    int epoch,
  ) async {
    _check(epoch);
    _openingIdentity();
    if (!pending.belongsTo(identity)) {
      throw const CcsopFailure('OPENING_SCOPE_CHANGED');
    }
    final raw = await _callOpening('K260929001906', pending.params);
    _check(epoch);
    final result = OpeningLookup.fromSubmission(
      raw,
      storeRef: pending.storeRef,
      tableId: pending.tableId,
      requestId: pending.requestId,
    );
    await _openingJournal.acknowledge(identity, result);
    _check(epoch);
    _openingIdentity();
    return result;
  }

  /// Recovery is read-only by default. An explicit retry first queries the original receipt.
  Future<OpeningLookup> recoverOpening(
    String requestId, {
    bool retryOriginal = false,
  }) => _openingOperation(() async {
    final identity = _openingIdentity(), epoch = _epoch;
    final entries = await _openingJournal.load(identity);
    _check(epoch);
    _openingIdentity();
    final matches = entries.where((e) => e.requestId == requestId).toList();
    if (matches.length != 1) {
      throw const CcsopFailure('OPENING_PENDING_NOT_FOUND');
    }
    final pending = matches.single;
    final result = await readOpeningReceipt(
      tableId: pending.tableId,
      requestId: requestId,
    );
    _check(epoch);
    if (result.state != OpeningLookupState.notObserved) {
      await _openingJournal.acknowledge(identity, result);
      _check(epoch);
      _openingIdentity();
      return result;
    }
    if (retryOriginal) return _sendOpening(pending, identity, epoch);
    return result;
  });

  /// Permanently abandon only this original request, never its already-opened session.
  Future<OpeningLookup> cancelOpening(
    String requestId, {
    required bool confirmed,
  }) => _openingOperation(() async {
    if (!confirmed) throw const CcsopFailure('OPENING_CONFIRMATION_REQUIRED');
    final identity = _openingIdentity(), epoch = _epoch;
    final entries = await _openingJournal.load(identity);
    _check(epoch);
    _openingIdentity();
    final matches = entries.where((e) => e.requestId == requestId).toList();
    if (matches.length != 1) {
      throw const CcsopFailure('OPENING_PENDING_NOT_FOUND');
    }
    final pending = matches.single;
    final raw = await _callOpening('K260929001909', {
      'tableId': pending.tableId,
      'requestId': requestId,
    });
    _check(epoch);
    final result = OpeningLookup.parse(
      raw,
      storeRef: identity.storeRef,
      tableId: pending.tableId,
      requestId: requestId,
    );
    await _openingJournal.acknowledge(identity, result);
    _check(epoch);
    _openingIdentity();
    return result;
  });

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
