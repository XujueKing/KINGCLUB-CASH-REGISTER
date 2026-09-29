import 'package:flutter/foundation.dart';

import '../live/catalog_snapshot.dart';
import '../live/order_context_snapshot.dart';
import '../live/order_command.dart';
import '../live/order_journal.dart';
import '../live/cash_command.dart';
import '../live/cash_journal.dart';
import '../live/serving_command.dart';
import '../live/serving_journal.dart';
import '../live/table_clear_command.dart';
import '../live/table_clear_journal.dart';
import '../live/payment_admission.dart';
import '../live/cart_draft.dart';
import '../live/cart_draft_store.dart';

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
    CashJournal? cashJournal,
    ServingJournal? servingJournal,
    TableClearJournal? tableClearJournal,
    CartDraftStore? cartDraftStore,
  }) : _vault = vault ?? SessionVault(),
       _authFactory = authFactory ?? ((base) => CcsopHandshakeClient(base)),
       _sessionFactory =
           sessionFactory ??
           ((session) =>
               CcsopClient(session.base.toString(), session.credentials)),
       _now = now ?? DateTime.now,
       _openingJournal = openingJournal ?? OpeningJournal(),
       _orderJournal = orderJournal ?? OrderJournal(),
       _cashJournal = cashJournal ?? CashJournal(),
       _servingJournal = servingJournal ?? ServingJournal(),
       _tableClearJournal = tableClearJournal ?? TableClearJournal(),
       _cartDraftStore = cartDraftStore ?? CartDraftStore();
  final CartDraftStore _cartDraftStore;
  final TableClearJournal _tableClearJournal;
  bool _tableClearBusy = false;
  final ServingJournal _servingJournal;
  bool _servingBusy = false;
  final CashJournal _cashJournal;
  bool _cashBusy = false;
  final OrderJournal _orderJournal;
  // Also coordinates draft handoff across controller instances in this isolate.
  static bool _orderBusy = false;
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
    void checkInstallable() {
      _check(epoch);
      if (!session.expiresAt.isAfter(_now())) {
        throw const CcsopFailure('SESSION_EXPIRED');
      }
    }

    checkInstallable();
    if (!await _vault.saveIfCurrent(
      session,
      () => _current(epoch) && session.expiresAt.isAfter(_now()),
    )) {
      // The vault removes a write invalidated while storage was pending.
      checkInstallable();
      throw const CcsopFailure('SESSION_CHANGED');
    }
    checkInstallable();
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
    if (!session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
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

  StaffSession _servingIdentity() {
    final identity = _session;
    if (_disposed ||
        identity == null ||
        _api == null ||
        _busy ||
        !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!identity.permissions.contains('orders.serve')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    return identity;
  }

  Future<T> _servingOperation<T>(Future<T> Function() work) async {
    if (_servingBusy) throw const CcsopFailure('SERVING_IN_PROGRESS');
    _servingBusy = true;
    try {
      return await work();
    } finally {
      _servingBusy = false;
    }
  }

  Future<List<PendingServing>> pendingServing() async {
    final identity = _servingIdentity(), epoch = _epoch;
    final entries = await _servingJournal.load(identity);
    _check(epoch);
    _servingIdentity();
    return entries;
  }

  Future<ServingResult> _servingCall(
    PendingServing command,
    StaffSession identity,
    int epoch, {
    required bool lookup,
  }) async {
    _check(epoch);
    _servingIdentity();
    if (!command.belongsTo(identity)) {
      throw const CcsopFailure('SERVING_SCOPE_CHANGED');
    }
    final raw = await _api!.call(
      lookup ? 'K260929001920' : 'K260929001919',
      lookup ? command.lookup : command.params,
    );
    _check(epoch);
    _servingIdentity();
    final result = ServingResult.parse(raw, command);
    if (!lookup && !result.confirmed) {
      throw const CcsopFailure('SERVING_RESPONSE_INVALID');
    }
    if (result.confirmed) await _servingJournal.acknowledge(identity, result);
    _check(epoch);
    _servingIdentity();
    return result;
  }

  Future<ServingResult> confirmServing({
    required String tableRef,
    required String sessionRef,
    required String orderRef,
    required String productRef,
    required int quantity,
    required int expectedServedQuantity,
    required int targetServedQuantity,
    required bool confirmed,
  }) => _servingOperation(() async {
    final identity = _servingIdentity(), epoch = _epoch;
    final command = PendingServing.prepare(
      identity: identity,
      tableRef: tableRef,
      sessionRef: sessionRef,
      orderRef: orderRef,
      productRef: productRef,
      quantity: quantity,
      expectedServedQuantity: expectedServedQuantity,
      targetServedQuantity: targetServedQuantity,
      now: _now(),
      confirmed: confirmed,
    );
    await _servingJournal.save(command, identity);
    _check(epoch);
    _servingIdentity();
    return _servingCall(command, identity, epoch, lookup: false);
  });

  /// Unknown is retained. Only an explicit caller decision may resend the SAME original command.
  Future<ServingResult> recoverServing(
    String requestId, {
    bool retryOriginal = false,
  }) => _servingOperation(() async {
    final identity = _servingIdentity(), epoch = _epoch;
    final entries = await _servingJournal.load(identity);
    _check(epoch);
    _servingIdentity();
    final matches = entries.where((e) => e.requestId == requestId).toList();
    if (matches.length != 1) {
      throw const CcsopFailure('SERVING_PENDING_NOT_FOUND');
    }
    final command = matches.single;
    final result = await _servingCall(command, identity, epoch, lookup: true);
    if (!result.confirmed && retryOriginal) {
      return _servingCall(command, identity, epoch, lookup: false);
    }
    return result;
  });

  StaffSession _tableClearIdentity() {
    final identity = _session;
    if (_disposed ||
        identity == null ||
        _api == null ||
        _busy ||
        !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!identity.permissions.contains('table.clear')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    return identity;
  }

  /// Read only: no journal acknowledgement, channel retries or payment confirmation.
  Future<PaymentAdmissionResult> lookupPaymentAdmission(
    PaymentAdmissionQuery query,
  ) async {
    final epoch = _epoch;
    void validate() {
      _check(epoch);
      final identity = _session;
      if (identity == null ||
          _api == null ||
          _busy ||
          !identity.expiresAt.isAfter(_now())) {
        throw const CcsopFailure('SESSION_REQUIRED');
      }
      if (!query.belongsTo(identity)) {
        throw const CcsopFailure('PAYMENT_ADMISSION_SCOPE_CHANGED');
      }
      if (!identity.permissions.contains(query.permission)) {
        throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
      }
    }

    validate();
    final raw = await _api!.call('K260929001923', query.params);
    validate();
    return PaymentAdmissionResult.parse(raw, query);
  }

  Future<T> _tableClearOperation<T>(Future<T> Function() work) async {
    if (_tableClearBusy) throw const CcsopFailure('TABLE_CLEAR_IN_PROGRESS');
    _tableClearBusy = true;
    try {
      return await work();
    } finally {
      _tableClearBusy = false;
    }
  }

  Future<List<PendingTableClear>> pendingTableClear() async {
    final identity = _tableClearIdentity(), epoch = _epoch;
    final entries = await _tableClearJournal.load(identity);
    _check(epoch);
    _tableClearIdentity();
    return entries;
  }

  Future<TableClearResult> _tableClearCall(
    PendingTableClear command,
    StaffSession identity,
    int epoch, {
    required bool lookup,
  }) async {
    _check(epoch);
    _tableClearIdentity();
    if (!command.belongsTo(identity)) {
      throw const CcsopFailure('TABLE_CLEAR_SCOPE_CHANGED');
    }
    final raw = await _api!.call(
      lookup ? 'K260929001922' : 'K260929001921',
      lookup ? command.lookup : command.params,
    );
    _check(epoch);
    _tableClearIdentity();
    final result = TableClearResult.parse(raw, command);
    if (!lookup && !result.confirmed) {
      throw const CcsopFailure('TABLE_CLEAR_RESPONSE_INVALID');
    }
    if (result.confirmed) {
      await _tableClearJournal.acknowledge(identity, result);
    }
    _check(epoch);
    _tableClearIdentity();
    return result;
  }

  Future<TableClearResult> confirmTableClear({
    required String tableRef,
    required String sessionRef,
    required bool confirmed,
  }) => _tableClearOperation(() async {
    final identity = _tableClearIdentity(), epoch = _epoch;
    final command = PendingTableClear.prepare(
      identity: identity,
      tableRef: tableRef,
      sessionRef: sessionRef,
      now: _now(),
      confirmed: confirmed,
    );
    await _tableClearJournal.save(command, identity);
    _check(epoch);
    _tableClearIdentity();
    return _tableClearCall(command, identity, epoch, lookup: false);
  });

  /// Unknown is retained. Only an explicit caller decision may resend the SAME original command.
  Future<TableClearResult> recoverTableClear(
    String requestId, {
    bool retryOriginal = false,
  }) => _tableClearOperation(() async {
    final identity = _tableClearIdentity(), epoch = _epoch;
    final entries = await _tableClearJournal.load(identity);
    _check(epoch);
    _tableClearIdentity();
    final matches = entries.where((e) => e.requestId == requestId).toList();
    if (matches.length != 1) {
      throw const CcsopFailure('TABLE_CLEAR_PENDING_NOT_FOUND');
    }
    final command = matches.single;
    final result = await _tableClearCall(
      command,
      identity,
      epoch,
      lookup: true,
    );
    if (!result.confirmed && retryOriginal) {
      return _tableClearCall(command, identity, epoch, lookup: false);
    }
    return result;
  });

  StaffSession _cashIdentity() {
    final identity = _session;
    if (_disposed ||
        identity == null ||
        _api == null ||
        _busy ||
        !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!identity.permissions.contains('payment.cash')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    return identity;
  }

  Future<T> _cashOperation<T>(Future<T> Function() operation) async {
    if (_cashBusy) {
      throw const CcsopFailure('CASH_IN_PROGRESS');
    }
    _cashBusy = true;
    try {
      return await operation();
    } finally {
      _cashBusy = false;
    }
  }

  Future<List<PendingCash>> pendingCash() async {
    final identity = _cashIdentity(), epoch = _epoch;
    final entries = await _cashJournal.load(identity);
    _check(epoch);
    _cashIdentity();
    return entries;
  }

  Future<PendingCash> _pendingCash(
    String requestId,
    StaffSession identity,
    int epoch,
  ) async {
    final entries = await _cashJournal.load(identity);
    _check(epoch);
    _cashIdentity();
    final matches = entries.where((e) => e.requestId == requestId).toList();
    if (matches.length != 1) {
      throw const CcsopFailure('CASH_PENDING_NOT_FOUND');
    }
    return matches.single;
  }

  Future<CashResult> _cashCall(
    CashResponse response,
    PendingCash command,
    StaffSession identity,
    int epoch,
  ) async {
    _check(epoch);
    _cashIdentity();
    if (!command.belongsTo(identity)) {
      throw const CcsopFailure('CASH_SCOPE_CHANGED');
    }
    final (id, params) = switch (response) {
      CashResponse.prepare => ('K260929001915', command.params),
      CashResponse.confirm => ('K260929001916', command.confirm),
      CashResponse.lookup => ('K260929001917', command.lookup),
      CashResponse.close => ('K260929001918', command.close),
    };
    final raw = await _api!.call(id, params);
    _check(epoch);
    _cashIdentity();
    final result = CashResult.parse(raw, command, response: response);
    if (result.terminal) {
      await _cashJournal.acknowledge(identity, result);
    } else if (result.intentRef != null) {
      final updated = command.observe(result);
      await _cashJournal.save(updated, identity, previous: command);
    }
    _check(epoch);
    _cashIdentity();
    return result;
  }

  Future<CashResult> prepareCash({
    required String orderRef,
    required int totalCents,
    required bool confirmed,
  }) => _cashOperation(() async {
    if (!confirmed) {
      throw const CcsopFailure('CASH_CONFIRMATION_REQUIRED');
    }
    final identity = _cashIdentity(), epoch = _epoch;
    final command = PendingCash.prepare(
      identity: identity,
      orderRef: orderRef,
      totalCents: totalCents,
      now: _now(),
    );
    await _cashJournal.save(command, identity);
    _check(epoch);
    _cashIdentity();
    return _cashCall(CashResponse.prepare, command, identity, epoch);
  });

  /// Recovery is read-only unless explicitly asked to retry the original preparation.
  Future<CashResult> recoverCash(
    String requestId, {
    bool retryOriginalPreparation = false,
  }) => _cashOperation(() async {
    final identity = _cashIdentity(), epoch = _epoch;
    final command = await _pendingCash(requestId, identity, epoch);
    final result = await _cashCall(
      CashResponse.lookup,
      command,
      identity,
      epoch,
    );
    if (result.state == CashState.notObserved &&
        retryOriginalPreparation &&
        command.initial) {
      return _cashCall(CashResponse.prepare, command, identity, epoch);
    }
    return result;
  });

  /// Persist the employee's physical-cash decision BEFORE any further network call.
  Future<CashResult> confirmCash(
    String requestId, {
    required int receivedCents,
    required bool cashReceivedConfirmed,
  }) => _cashOperation(() async {
    if (!cashReceivedConfirmed) {
      throw const CcsopFailure('CASH_CONFIRMATION_REQUIRED');
    }
    final identity = _cashIdentity(), epoch = _epoch;
    final previous = await _pendingCash(requestId, identity, epoch);
    final command = previous.recordConfirmation(
      receivedCents,
      cashReceivedConfirmed: true,
    );
    await _cashJournal.save(command, identity, previous: previous);
    _check(epoch);
    _cashIdentity();
    final result = await _cashCall(
      CashResponse.lookup,
      command,
      identity,
      epoch,
    );
    if (result.terminal) return result;
    if (result.state != CashState.prepared || !result.canConfirmCash) {
      throw const CcsopFailure('CASH_REVIEW_REQUIRED');
    }
    return _cashCall(CashResponse.confirm, command, identity, epoch);
  });
  Future<CashResult> closeCash(
    String requestId, {
    required bool noCashCollectedConfirmed,
  }) => _cashOperation(() async {
    if (!noCashCollectedConfirmed) {
      throw const CcsopFailure('CASH_CONFIRMATION_REQUIRED');
    }
    final identity = _cashIdentity(), epoch = _epoch;
    final previous = await _pendingCash(requestId, identity, epoch);
    final command = previous.recordClosure(noCashCollectedConfirmed: true);
    await _cashJournal.save(command, identity, previous: previous);
    _check(epoch);
    _cashIdentity();
    final result = await _cashCall(
      CashResponse.lookup,
      command,
      identity,
      epoch,
    );
    if (result.terminal) return result;
    if (result.state != CashState.prepared) {
      throw const CcsopFailure('CASH_REVIEW_REQUIRED');
    }
    return _cashCall(CashResponse.close, command, identity, epoch);
  });

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

  Future<List<CartDraft>> cartDrafts() async {
    final identity = _orderIdentity(), epoch = _epoch;
    final drafts = await _cartDraftStore.load(identity);
    _check(epoch);
    _orderIdentity();
    return drafts;
  }

  Future<void> _requireNoPendingCart(String tableRef) async {
    if ((await pendingOrders()).any((p) => p.tableRef == tableRef)) {
      throw const CcsopFailure('ORDER_ALREADY_PENDING');
    }
  }

  Future<CartDraft> saveCartDraft({
    required OrderContextSnapshot context,
    required String memberRef,
    required List<OrderSelection> items,
    required CartDraft? previous,
  }) => _orderOperation(() async {
    final identity = _orderIdentity(), epoch = _epoch;
    final draft = CartDraft.capture(
      identity: identity,
      context: context,
      memberRef: memberRef,
      items: items,
      now: _now(),
    );
    await _requireNoPendingCart(context.tableRef);
    _check(epoch);
    _orderIdentity();
    await _cartDraftStore.save(draft, identity, previous: previous);
    _check(epoch);
    _orderIdentity();
    return draft;
  });

  Future<void> discardCartDraft(CartDraft draft, {required bool confirmed}) =>
      _orderOperation(() async {
        if (!confirmed) throw const CcsopFailure('ORDER_CONFIRMATION_REQUIRED');
        final identity = _orderIdentity(), epoch = _epoch;
        if (!draft.belongsTo(identity)) {
          throw const CcsopFailure('CART_DRAFT_CONTEXT_CHANGED');
        }
        await _requireNoPendingCart(draft.tableRef);
        _check(epoch);
        _orderIdentity();
        await _cartDraftStore.remove(draft, identity);
        _check(epoch);
        _orderIdentity();
      });

  /// Refreshes actual membership and catalogue; never reuses persisted prices as truth.
  Future<RestoredCart> restoreCartDraft(
    CartDraft draft,
  ) => _orderOperation(() async {
    final identity = _orderIdentity(), epoch = _epoch;
    if (!draft.belongsTo(identity)) {
      throw const CcsopFailure('CART_DRAFT_CONTEXT_CHANGED');
    }
    final saved = await cartDrafts();
    if (!saved.any((d) => d.signature == draft.signature)) {
      throw const CcsopFailure('CART_DRAFT_EDIT_CONFLICT');
    }
    await _requireNoPendingCart(draft.tableRef);
    OrderContextSnapshot? context;
    String? cursor;
    for (var page = 0; page < 200; page++) {
      final next = await readOrderContext(
        tableRef: draft.tableRef,
        sessionRef: draft.sessionRef,
        afterMember: cursor,
      );
      if (next.members.any((m) => m.reference == draft.memberRef)) {
        context = next;
        break;
      }
      if (next.nextAfterMember == null) break;
      if (cursor != null && next.nextAfterMember!.compareTo(cursor) <= 0) {
        throw const CcsopFailure('CART_DRAFT_CONTEXT_CHANGED');
      }
      cursor = next.nextAfterMember;
    }
    if (context == null) throw const CcsopFailure('CART_DRAFT_CONTEXT_CHANGED');
    final needed = draft.lines.map((l) => l['productRef'] as String).toSet();
    final products = <CatalogProduct>[];
    cursor = null;
    for (var page = 0; page < 200; page++) {
      final next = await readCatalog(afterProduct: cursor);
      if (next.currency != context.currency) {
        throw const CcsopFailure('CART_DRAFT_CATALOG_CHANGED');
      }
      products.addAll(next.products.where((p) => needed.contains(p.reference)));
      if (products.length == needed.length || next.nextAfterProduct == null) {
        break;
      }
      if (cursor != null && next.nextAfterProduct!.compareTo(cursor) <= 0) {
        throw const CcsopFailure('CART_DRAFT_CATALOG_CHANGED');
      }
      cursor = next.nextAfterProduct;
    }
    _check(epoch);
    _orderIdentity();
    final items = draft.restore(
      identity: identity,
      context: context,
      products: products,
      now: _now(),
    );
    return RestoredCart(draft, context, items);
  });

  Future<OrderRequestResult> submitOrder({
    required OrderContextSnapshot context,
    required String memberRef,
    required List<OrderSelection> items,
    required bool confirmed,
    CartDraft? cartDraft,
  }) => _orderOperation(() async {
    if (!confirmed) throw const CcsopFailure('ORDER_CONFIRMATION_REQUIRED');
    final identity = _orderIdentity(), epoch = _epoch;
    final command = PendingOrder.prepare(
      identity: identity,
      context: context,
      memberRef: memberRef,
      items: items,
      now: _now(),
      cartDraft: cartDraft,
    );
    final drafts = await _cartDraftStore.load(identity);
    _check(epoch);
    _orderIdentity();
    final matching = drafts
        .where(
          (d) =>
              d.tableRef == context.tableRef &&
              d.sessionRef == context.sessionRef &&
              d.memberRef == memberRef,
        )
        .toList();
    if (cartDraft == null
        ? matching.isNotEmpty
        : matching.length != 1 ||
              matching.single.signature != cartDraft.signature) {
      throw const CcsopFailure('CART_DRAFT_EDIT_CONFLICT');
    }
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
    // The durable command is the recovery owner. Consume only its exact linked
    // draft BEFORE delivery or receipt acknowledgement, including crash recovery.
    if (command.cartDraft != null) {
      await _cartDraftStore.remove(command.cartDraft!, identity);
      _check(epoch);
      _orderIdentity();
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
