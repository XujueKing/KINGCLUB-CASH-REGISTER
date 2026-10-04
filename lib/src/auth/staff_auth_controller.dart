import 'dart:typed_data';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../live/catalog_snapshot.dart';
import '../live/member_identity.dart';
import '../live/seating_command.dart';
import '../live/seating_journal.dart';
import '../live/voucher_lookup.dart';
import '../live/order_context_snapshot.dart';
import '../live/order_command.dart';
import '../live/order_journal.dart';
import '../live/cash_command.dart';
import '../live/cash_journal.dart';
import '../live/serving_command.dart';
import '../live/serving_journal.dart';
import '../live/item_return_command.dart';
import '../live/item_return_journal.dart';
import '../live/table_clear_command.dart';
import '../live/table_clear_journal.dart';
import '../live/table_checkout_command.dart';
import '../live/table_checkout_journal.dart';
import '../live/table_checkout_result.dart';
import '../live/table_checkout_cancellation.dart';
import '../live/balance_refund_context.dart';
import '../live/balance_refund_command.dart';
import '../live/balance_refund_journal.dart';
import '../live/balance_refund_result.dart';
import '../live/payment_admission.dart';
import '../live/provider_payment.dart';
import '../live/receipt_document.dart';
import '../live/recharge_result.dart';
import '../live/recharge_journal.dart';
import '../live/recharge_context.dart';
import '../live/cart_draft.dart';
import '../live/cart_draft_store.dart';

import '../live/opening_snapshot.dart';
import '../live/opening_journal.dart';
import '../network/ccsop_client.dart';
import '../network/ccsop_crypto.dart';
import '../network/ccsop_handshake.dart';
import 'session_vault.dart';
import 'staff_session.dart';
import '../live/together_admission.dart';

/// Owns exactly one employee session. Saved projections are never accepted without a server refresh.
class StaffAuthController extends ChangeNotifier {
  final operatorAvatar = ValueNotifier<Uint8List?>(null);
  String? _operatorAvatarEncoded;
  void _updateOperatorAvatar(Object? encoded) {
    final next = encoded is String && encoded.length <= 65536 ? encoded : null;
    if (next == _operatorAvatarEncoded) return;
    _operatorAvatarEncoded = next;
    try { operatorAvatar.value = next == null ? null : base64Decode(next); }
    catch (_) { operatorAvatar.value = null; }
  }

  StaffAuthController({
    SessionVault? vault,
    AuthChannel Function(String)? authFactory,
    SessionChannel Function(StaffSession)? sessionFactory,
    DateTime Function()? now,
    OpeningJournal? openingJournal,
    OrderJournal? orderJournal,
    CashJournal? cashJournal,
    ProviderPaymentJournal? providerJournal,
    RechargeJournal? rechargeJournal,
    ServingJournal? servingJournal,
    ItemReturnJournal? itemReturnJournal,
    SeatingJournal? seatingJournal,
    TableClearJournal? tableClearJournal,
    TableCheckoutJournal? tableCheckoutJournal,
    BalanceRefundJournal? balanceRefundJournal,
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
       _providerJournal = providerJournal ?? ProviderPaymentJournal(),
       _rechargeJournal = rechargeJournal ?? RechargeJournal(),
       _servingJournal = servingJournal ?? ServingJournal(),
       _itemReturnJournal = itemReturnJournal ?? ItemReturnJournal(),
       _seatingJournal = seatingJournal ?? SeatingJournal(),
       _tableClearJournal = tableClearJournal ?? TableClearJournal(),
       _tableCheckoutJournal = tableCheckoutJournal ?? TableCheckoutJournal(),
       _balanceRefundJournal = balanceRefundJournal ?? BalanceRefundJournal(),
       _cartDraftStore = cartDraftStore ?? CartDraftStore();
  final CartDraftStore _cartDraftStore;
  final ItemReturnJournal _itemReturnJournal;
  final SeatingJournal _seatingJournal;
  bool _seatingBusy = false;
  final RechargeJournal _rechargeJournal;
  final TableCheckoutJournal _tableCheckoutJournal;
  bool _tablePreparationBusy = false;
  bool _tableCollectionBusy = false;

  StaffSession _tableCheckoutIdentity(String channel) {
    if (![
      'wechat',
      'alipay',
      'cash',
      'pos',
      'member_balance',
    ].contains(channel)) {
      throw const CcsopFailure('TABLE_CHECKOUT_CHANNEL_INVALID');
    }
    final identity = _session;
    if (_disposed ||
        _busy ||
        identity == null ||
        _api == null ||
        !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    final permission = channel == 'member_balance'
        ? 'payment.balance'
        : channel == 'pos'
        ? 'payment.cash'
        : 'payment.$channel';
    if (!identity.permissions.contains(permission))
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    return identity;
  }

  Future<TableCheckoutQuote> quoteTableCheckout({
    required String tableRef,
    required String sessionRef,
    required String channel,
    required String? accountType,
    List<Map<String, String>> seatSessions = const [],
  }) async {
    final identity = _tableCheckoutIdentity(channel), epoch = _epoch;
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(tableRef) ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(sessionRef) ||
        (channel == 'member_balance'
            ? !['platform_cash', 'store_balance'].contains(accountType)
            : accountType != null)) {
      throw const CcsopFailure('TABLE_CHECKOUT_SCOPE_INVALID');
    }
    final raw = await _api!.call('K260930001937', {
      'storeRef': identity.storeRef,
      'tableRef': tableRef,
      'sessionRef': sessionRef,
      'channel': channel,
      'accountType': accountType,
      'currency': 'CNY',
      if (seatSessions.isNotEmpty) 'seatSessions': seatSessions,
    });
    _check(epoch);
    _tableCheckoutIdentity(channel);
    return TableCheckoutQuote.parse(
      raw,
      storeRef: identity.storeRef,
      tableRef: tableRef,
      sessionRef: sessionRef,
      channel: channel,
      accountType: accountType,
      seatSessions: seatSessions,
    );
  }

  Future<List<TableCheckoutCommand>> pendingTableCheckouts(
    String channel,
  ) async {
    final identity = _tableCheckoutIdentity(channel), epoch = _epoch;
    final rows = await _tableCheckoutJournal.load(identity);
    _check(epoch);
    _tableCheckoutIdentity(channel);
    return List.unmodifiable(rows.where((row) => row.channel == channel));
  }

  /// Persist and verify the original request before admission; no collection.
  Future<TableCheckoutAdmission> prepareTableCheckout(
    TableCheckoutCommand command, {
    required bool confirmed,
    bool Function()? stillCurrent,
  }) async {
    if (!confirmed)
      throw const CcsopFailure('TABLE_CHECKOUT_CONFIRMATION_REQUIRED');
    if (_tablePreparationBusy || _tableCollectionBusy)
      throw const CcsopFailure('TABLE_CHECKOUT_BUSY');
    _tablePreparationBusy = true;
    try {
      final identity = _tableCheckoutIdentity(command.channel), epoch = _epoch;
      void validate() {
        _check(epoch);
        if (stillCurrent != null && !stillCurrent())
          throw const CcsopFailure('TABLE_CHECKOUT_SCOPE_CHANGED');
        if (!command.belongsTo(_tableCheckoutIdentity(command.channel))) {
          throw const CcsopFailure('TABLE_CHECKOUT_SCOPE_CHANGED');
        }
      }

      validate();
      await _tableCheckoutJournal.save(identity, command);
      validate();
      final raw = await _api!.call('K260930001938', command.params);
      validate();
      return TableCheckoutAdmission.parse(raw, command);
    } finally {
      _tablePreparationBusy = false;
    }
  }

  /// Query only: never recreate a missing original request or collect money.
  Future<TableCheckoutAdmission> lookupTableCheckout(
    TableCheckoutCommand command,
  ) async {
    final identity = _tableCheckoutIdentity(command.channel), epoch = _epoch;
    void validate() {
      _check(epoch);
      if (!command.belongsTo(_tableCheckoutIdentity(command.channel))) {
        throw const CcsopFailure('TABLE_CHECKOUT_SCOPE_CHANGED');
      }
    }

    validate();
    final saved = await _tableCheckoutJournal.load(identity);
    validate();
    if (!saved.any(
      (row) => jsonEncode(row.encoded) == jsonEncode(command.encoded),
    )) {
      throw const CcsopFailure('TABLE_CHECKOUT_ORIGINAL_REQUEST_REQUIRED');
    }
    final raw = await _api!.call('K260930001939', command.params);
    validate();
    return TableCheckoutAdmission.parse(raw, command);
  }

  Future<TableCheckoutResult> collectTableCheckout(
    TableCheckoutCommand command, {
    required bool confirmed,
    required bool Function() stillCurrent,
    String? payerCode,
    int? cashReceivedCents,
  }) {
    if (!confirmed)
      throw const CcsopFailure('TABLE_CHECKOUT_CONFIRMATION_REQUIRED');
    if (command.channel == 'cash') {
      if (payerCode != null ||
          cashReceivedCents == null ||
          cashReceivedCents < command.totalCents ||
          cashReceivedCents > 100000000) {
        throw const CcsopFailure('TABLE_CHECKOUT_CASH_INVALID');
      }
    } else if (cashReceivedCents != null ||
        payerCode == null ||
        !(command.channel == 'pos'
            ? RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(payerCode)
            : validProviderCode(command.channel, payerCode))) {
      throw const CcsopFailure('PAYMENT_CODE_INVALID');
    }
    return _resolveTableCollection(
      command,
      collect: true,
      stillCurrent: stillCurrent,
      payerCode: payerCode,
      cashReceivedCents: cashReceivedCents,
    );
  }

  /// May finish original settlement; never sends a payer code or accepts new cash.
  Future<TableCheckoutResult> recoverTableCheckout(
    TableCheckoutCommand command, {
    required bool Function() stillCurrent,
  }) => _resolveTableCollection(
    command,
    collect: false,
    stillCurrent: stillCurrent,
  );

  Future<TableCheckoutResult> closeTableProvider(
    TableCheckoutCommand command, {
    required bool Function() stillCurrent,
  }) => _resolveTableCollection(
    command,
    collect: false,
    closeUnpaid: true,
    stillCurrent: stillCurrent,
  );

  Future<TableCheckoutResult> _resolveTableCollection(
    TableCheckoutCommand command, {
    required bool collect,
    bool closeUnpaid = false,
    required bool Function() stillCurrent,
    String? payerCode,
    int? cashReceivedCents,
  }) async {
    if (_tablePreparationBusy || _tableCollectionBusy)
      throw const CcsopFailure('TABLE_CHECKOUT_BUSY');
    _tableCollectionBusy = true;
    try {
      final identity = _tableCheckoutIdentity(command.channel), epoch = _epoch;
      void validate() {
        _check(epoch);
        if (!command.belongsTo(_tableCheckoutIdentity(command.channel)) ||
            !stillCurrent()) {
          throw const CcsopFailure('TABLE_CHECKOUT_SCOPE_CHANGED');
        }
      }

      validate();
      if (closeUnpaid && (collect || command.channel != 'alipay'))
        throw const CcsopFailure('TABLE_CHECKOUT_SCOPE_CHANGED');
      // Lookup requires the identical durable request and validates the original
      // parent scope. Admission alone is never a settled result.
      final admission = await lookupTableCheckout(command);
      validate();
      final checkout = admission.checkoutRef;
      if (checkout == null)
        throw const CcsopFailure('TABLE_CHECKOUT_ORIGINAL_REQUEST_REQUIRED');
      final firstSend = collect && admission.paymentStatus == 'prepared';
      final params = <String, dynamic>{
        'storeRef': command.storeRef,
        'checkoutRef': checkout,
        'expectedTotalCents': command.totalCents,
      };
      String interfaceId;
      if (command.channel == 'cash') {
        interfaceId = firstSend ? 'K260930001942' : 'K260930001943';
        if (firstSend)
          params.addAll({
            'receivedCents': cashReceivedCents,
            'cashReceivedConfirmed': true,
          });
      } else if (command.channel == 'pos') {
        interfaceId = firstSend ? 'K261004002004' : 'K261004002005';
        if (firstSend)
          params.addAll({
            'externalReference': payerCode,
            'posReceivedConfirmed': true,
          });
      } else if (command.channel == 'member_balance') {
        interfaceId = firstSend ? 'K260930001944' : 'K260930001945';
        params['accountType'] = command.accountType;
        if (firstSend) params['paymentCode'] = payerCode;
      } else {
        interfaceId = closeUnpaid
            ? 'K261002001963'
            : firstSend
            ? 'K260930001940'
            : 'K260930001941';
        params['channel'] = command.channel;
        if (firstSend) params['authCode'] = payerCode;
      }
      Object? raw;
      try {
        validate();
        raw = await _api!.call(interfaceId, params);
      } finally {
        params.remove('authCode');
        params.remove('paymentCode');
        payerCode = null;
      }
      validate();
      final result = TableCheckoutResult.parse(
        raw,
        command,
        checkoutRef: checkout,
      );
      if (result.resolved) {
        await _tableCheckoutJournal.acknowledge(identity, command, result);
        validate();
      }
      return result;
    } finally {
      _tableCollectionBusy = false;
    }
  }

  Future<TableCheckoutCancellation> cancelTableCheckout(
    TableCheckoutCommand command, {
    required bool confirmed,
    required bool Function() stillCurrent,
  }) {
    if (!confirmed)
      throw const CcsopFailure('TABLE_CHECKOUT_CONFIRMATION_REQUIRED');
    return _resolveTableCancellation(
      command,
      cancel: true,
      stillCurrent: stillCurrent,
    );
  }

  Future<TableCheckoutCancellation> lookupTableCancellation(
    TableCheckoutCommand command, {
    required bool Function() stillCurrent,
  }) => _resolveTableCancellation(
    command,
    cancel: false,
    stillCurrent: stillCurrent,
  );

  Future<TableCheckoutCancellation> _resolveTableCancellation(
    TableCheckoutCommand command, {
    required bool cancel,
    required bool Function() stillCurrent,
  }) async {
    if (_tablePreparationBusy || _tableCollectionBusy)
      throw const CcsopFailure('TABLE_CHECKOUT_BUSY');
    _tableCollectionBusy = true;
    try {
      final identity = _tableCheckoutIdentity(command.channel), epoch = _epoch;
      void validate() {
        _check(epoch);
        if (!command.belongsTo(_tableCheckoutIdentity(command.channel)) ||
            !stillCurrent()) {
          throw const CcsopFailure('TABLE_CHECKOUT_SCOPE_CHANGED');
        }
      }

      validate();
      final admission = await lookupTableCheckout(command);
      validate();
      final checkout = admission.checkoutRef;
      if (checkout == null)
        throw const CcsopFailure('TABLE_CHECKOUT_ORIGINAL_REQUEST_REQUIRED');
      final write = cancel && admission.paymentStatus == 'prepared';
      final params = <String, dynamic>{
        ...command.params,
        'checkoutRef': checkout,
      }..remove('currency');
      if (write) params['cancellationConfirmed'] = true;
      final raw = await _api!.call(
        write ? 'K260930001946' : 'K260930001947',
        params,
      );
      validate();
      final result = TableCheckoutCancellation.parse(
        raw,
        command,
        checkoutRef: checkout,
      );
      if (result.cancelled) {
        await _tableCheckoutJournal.acknowledgeCancellation(
          identity,
          command,
          result,
        );
        validate();
      }
      return result;
    } finally {
      _tableCollectionBusy = false;
    }
  }

  Future<List<RechargeCommand>> pendingRecharges(String channel) async {
    final identity = _providerIdentity(channel), epoch = _epoch;
    final entries = await _rechargeJournal.load(identity);
    _check(epoch);
    _providerIdentity(channel);
    return entries.where((e) => e.channel == channel).toList();
  }

  Future<RechargeContext> readRechargeContext(String rechargeRef) async {
    final epoch = _epoch, store = _session?.storeRef;
    void validate() {
      _check(epoch);
      final identity = _session;
      if (_busy ||
          identity == null ||
          _api == null ||
          !identity.expiresAt.isAfter(_now()))
        throw const CcsopFailure('SESSION_REQUIRED');
      if (identity.storeRef != store ||
          ![
            'payment.wechat',
            'payment.alipay',
          ].any(identity.permissions.contains)) {
        throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
      }
    }

    validate();
    if (!validRechargeRef(rechargeRef))
      throw const CcsopFailure('RECHARGE_QUERY_INVALID');
    final raw = await _api!.call('K260930001935', {
      'storeRef': store,
      'rechargeRef': rechargeRef,
    });
    validate();
    final result = RechargeContext.parse(
      raw,
      storeRef: store!,
      rechargeRef: rechargeRef,
    );
    if (!_session!.permissions.contains('payment.${result.channel}'))
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    return result;
  }

  Future<RechargeResult> collectRecharge({
    required String rechargeRef,
    required String channel,
    required int principalCents,
    required String authCode,
    required bool Function() stillCurrent,
  }) async {
    if (_providerBusy) throw const CcsopFailure('PAYMENT_IN_PROGRESS');
    _providerBusy = true;
    try {
      final identity = _providerIdentity(channel), epoch = _epoch;
      if (!['wechat', 'alipay'].contains(channel) ||
          !validProviderCode(channel, authCode)) {
        throw const CcsopFailure('PAYMENT_CODE_INVALID');
      }
      final command = RechargeCommand.forSession(
        identity,
        rechargeRef: rechargeRef,
        channel: channel,
        principalCents: principalCents,
      );
      await _rechargeJournal.save(identity, command);
      _check(epoch);
      _providerIdentity(channel);
      if (!stillCurrent()) throw const CcsopFailure('PAYMENT_CONTEXT_CHANGED');
      final raw = await _api!.call('K260930001933', {
        ...command.params,
        'authCode': authCode,
      });
      _check(epoch);
      _providerIdentity(channel);
      final result = RechargeResult.parse(
        raw,
        storeRef: identity.storeRef,
        rechargeRef: rechargeRef,
        expectedPrincipalCents: principalCents,
      );
      if (result.credited)
        await _rechargeJournal.acknowledge(identity, command, result);
      _check(epoch);
      if (!stillCurrent()) throw const CcsopFailure('PAYMENT_CONTEXT_CHANGED');
      return result;
    } finally {
      _providerBusy = false;
    }
  }

  Future<RechargeResult> recoverRecharge(RechargeCommand command) async {
    if (_providerBusy) throw const CcsopFailure('PAYMENT_IN_PROGRESS');
    _providerBusy = true;
    try {
      final identity = _providerIdentity(command.channel), epoch = _epoch;
      if (!command.belongsTo(identity))
        throw const CcsopFailure('RECHARGE_SCOPE_CHANGED');
      final entries = await _rechargeJournal.load(identity);
      _check(epoch);
      _providerIdentity(command.channel);
      if (!entries.any(
        (e) => jsonEncode(e.encoded) == jsonEncode(command.encoded),
      )) {
        throw const CcsopFailure('RECHARGE_ORIGINAL_REQUEST_REQUIRED');
      }
      final result = await queryRecharge(
        command.rechargeRef,
        channel: command.channel,
        expectedPrincipalCents: command.principalCents,
      );
      _check(epoch);
      _providerIdentity(command.channel);
      if (result.credited)
        await _rechargeJournal.acknowledge(identity, command, result);
      _check(epoch);
      return result;
    } finally {
      _providerBusy = false;
    }
  }

  /// Explicit resumed send, never an automatic retry. A fresh original lookup
  /// must prove not_sent; the server's durable fence handles concurrent admission.
  Future<RechargeResult> sendUnsentRecharge(
    RechargeCommand command, {
    required String authCode,
    required bool Function() stillCurrent,
  }) async {
    if (_providerBusy) throw const CcsopFailure('PAYMENT_IN_PROGRESS');
    _providerBusy = true;
    try {
      final identity = _providerIdentity(command.channel), epoch = _epoch;
      if (!command.belongsTo(identity) ||
          !validProviderCode(command.channel, authCode)) {
        throw const CcsopFailure('RECHARGE_SCOPE_CHANGED');
      }
      final entries = await _rechargeJournal.load(identity);
      _check(epoch);
      _providerIdentity(command.channel);
      if (!entries.any(
        (e) => jsonEncode(e.encoded) == jsonEncode(command.encoded),
      )) {
        throw const CcsopFailure('RECHARGE_ORIGINAL_REQUEST_REQUIRED');
      }
      if (!stillCurrent()) throw const CcsopFailure('PAYMENT_CONTEXT_CHANGED');
      final observed = await queryRecharge(
        command.rechargeRef,
        channel: command.channel,
        expectedPrincipalCents: command.principalCents,
      );
      _check(epoch);
      _providerIdentity(command.channel);
      if (!stillCurrent()) throw const CcsopFailure('PAYMENT_CONTEXT_CHANGED');
      if (observed.state != 'not_sent') {
        if (observed.credited)
          await _rechargeJournal.acknowledge(identity, command, observed);
        _check(epoch);
        return observed;
      }
      final raw = await _api!.call('K260930001933', {
        ...command.params,
        'authCode': authCode,
      });
      _check(epoch);
      _providerIdentity(command.channel);
      final result = RechargeResult.parse(
        raw,
        storeRef: identity.storeRef,
        rechargeRef: command.rechargeRef,
        expectedPrincipalCents: command.principalCents,
      );
      if (result.credited)
        await _rechargeJournal.acknowledge(identity, command, result);
      _check(epoch);
      if (!stillCurrent()) throw const CcsopFailure('PAYMENT_CONTEXT_CHANGED');
      return result;
    } finally {
      _providerBusy = false;
    }
  }

  final BalanceRefundJournal _balanceRefundJournal;
  static bool _balanceRefundBusy = false;
  StaffSession _refundIdentity() {
    final identity = _session;
    if (_disposed ||
        _busy ||
        identity == null ||
        _api == null ||
        !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!identity.permissions.contains('payment.refund')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    return identity;
  }

  Future<T> _refundOperation<T>(Future<T> Function() work) async {
    if (_balanceRefundBusy) {
      throw const CcsopFailure('BALANCE_REFUND_IN_PROGRESS');
    }
    _balanceRefundBusy = true;
    try {
      return await work();
    } finally {
      _balanceRefundBusy = false;
    }
  }

  Future<BalanceRefundContext> balanceRefundContext(String orderRef) async {
    final identity = _refundIdentity(), epoch = _epoch;
    final raw = await _api!.call('K260930001931', {
      'storeRef': identity.storeRef,
      'orderRef': orderRef,
    });
    _check(epoch);
    _refundIdentity();
    if (raw is! Map<String, dynamic>) {
      throw const CcsopFailure('BALANCE_REFUND_RESPONSE_INVALID');
    }
    try {
      return BalanceRefundContext.parse(
        raw['result'],
        expectedStore: identity.storeRef,
        expectedOrder: orderRef,
      );
    } catch (_) {
      throw const CcsopFailure('BALANCE_REFUND_RESPONSE_INVALID');
    }
  }

  Future<List<PendingBalanceRefund>> pendingBalanceRefunds() async {
    final identity = _refundIdentity(), epoch = _epoch;
    final entries = await _balanceRefundJournal.load(identity);
    _check(epoch);
    _refundIdentity();
    return entries;
  }

  Future<BalanceRefundResult> _refundCall(
    PendingBalanceRefund command,
    StaffSession identity,
    int epoch, {
    required bool lookup,
  }) async {
    _check(epoch);
    _refundIdentity();
    if (!command.belongsTo(identity)) {
      throw const CcsopFailure('BALANCE_REFUND_SCOPE_CHANGED');
    }
    final raw = await _api!.call(
      lookup ? 'K260930001930' : 'K260930001929',
      command.params,
    );
    _check(epoch);
    _refundIdentity();
    final result = await BalanceRefundResult.parse(raw, command);
    _check(epoch);
    _refundIdentity();
    if (!lookup && !result.confirmed) {
      throw const CcsopFailure('BALANCE_REFUND_RESPONSE_INVALID');
    }
    if (result.confirmed) {
      await _balanceRefundJournal.acknowledge(identity, result);
    }
    _check(epoch);
    _refundIdentity();
    return result;
  }

  Future<BalanceRefundResult> confirmBalanceRefund({
    required BalanceRefundContext context,
    required String reason,
    required List<Map<String, dynamic>> dispositions,
    required bool confirmed,
    required bool Function() stillCurrent,
  }) => _refundOperation(() async {
    final identity = _refundIdentity(), epoch = _epoch;
    if (!stillCurrent()) {
      throw const CcsopFailure('BALANCE_REFUND_SCOPE_CHANGED');
    }
    final command = PendingBalanceRefund.prepare(
      identity: identity,
      context: context,
      now: _now(),
      confirmed: confirmed,
      reason: reason,
      dispositions: dispositions,
    );
    await _balanceRefundJournal.save(command, identity);
    _check(epoch);
    _refundIdentity();
    if (!stillCurrent()) {
      throw const CcsopFailure('BALANCE_REFUND_SCOPE_CHANGED');
    }
    return _refundCall(command, identity, epoch, lookup: false);
  });
  Future<BalanceRefundResult> recoverBalanceRefund(
    String refundRef, {
    bool retryOriginal = false,
    required bool Function() stillCurrent,
  }) => _refundOperation(() async {
    final identity = _refundIdentity(), epoch = _epoch;
    final entries = await _balanceRefundJournal.load(identity);
    _check(epoch);
    _refundIdentity();
    final matching = entries.where((e) => e.refundRef == refundRef).toList();
    if (matching.length != 1) {
      throw const CcsopFailure('BALANCE_REFUND_PENDING_NOT_FOUND');
    }
    final command = matching.single;
    final result = await _refundCall(command, identity, epoch, lookup: true);
    if (!result.confirmed && retryOriginal) {
      if (!stillCurrent()) {
        throw const CcsopFailure('BALANCE_REFUND_SCOPE_CHANGED');
      }
      return _refundCall(command, identity, epoch, lookup: false);
    }
    return result;
  });
  final TableClearJournal _tableClearJournal;
  bool _tableClearBusy = false;
  final ServingJournal _servingJournal;
  bool _servingBusy = false;
  final CashJournal _cashJournal;
  final ProviderPaymentJournal _providerJournal;
  static bool _providerBusy = false;

  StaffSession _providerIdentity(String channel) {
    final s = _session;
    if (_disposed ||
        _busy ||
        s == null ||
        _api == null ||
        !s.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!['wechat', 'alipay', 'member_balance'].contains(channel) ||
        !s.permissions.contains(paymentPermissions[channel])) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    return s;
  }

  Future<List<ProviderPayment>> pendingProviderPayments(String channel) async {
    final s = _providerIdentity(channel), epoch = _epoch;
    final entries = await _providerJournal.load(s);
    _check(epoch);
    _providerIdentity(channel);
    return entries.where((e) => e.query.channel == channel).toList();
  }

  Future<ProviderPaymentResult> collectProvider({
    required String orderRef,
    required String channel,
    required int totalCents,
    required String authCode,
    required bool Function() stillCurrent,
    String? accountType,
  }) async {
    if (_providerBusy) throw const CcsopFailure('PAYMENT_IN_PROGRESS');
    _providerBusy = true;
    try {
      final s = _providerIdentity(channel), epoch = _epoch;
      if (!validProviderCode(channel, authCode)) {
        throw const CcsopFailure('PAYMENT_CODE_INVALID');
      }
      final command = ProviderPayment.create(
        s,
        orderRef,
        channel,
        totalCents,
        accountType: accountType,
      );
      await _providerJournal.save(s, command);
      _check(epoch);
      _providerIdentity(channel);
      if (!stillCurrent()) throw const CcsopFailure('PAYMENT_CONTEXT_CHANGED');
      final raw = await _paymentCall(
        command,
        epoch,
        authCode: authCode,
        stillCurrent: stillCurrent,
      );
      _check(epoch);
      _providerIdentity(channel);
      final result = ProviderPaymentResult.parse(raw, command);
      if (result.resolved) await _providerJournal.acknowledge(s, command);
      _check(epoch);
      return result;
    } finally {
      _providerBusy = false;
    }
  }

  Future<ProviderPaymentResult> queryProvider(ProviderPayment command) =>
      _recoverProvider(command);

  Future<ProviderPaymentResult> closeProvider(
    ProviderPayment command, {
    required bool Function() stillCurrent,
  }) =>
      _recoverProvider(command, closeUnpaid: true, stillCurrent: stillCurrent);

  Future<ProviderPaymentResult> _recoverProvider(
    ProviderPayment command, {
    bool closeUnpaid = false,
    bool Function()? stillCurrent,
  }) async {
    if (_providerBusy) throw const CcsopFailure('PAYMENT_IN_PROGRESS');
    _providerBusy = true;
    try {
      final s = _providerIdentity(command.query.channel), epoch = _epoch;
      if (!command.query.belongsTo(s)) {
        throw const CcsopFailure('PROVIDER_SCOPE_CHANGED');
      }
      final entries = await _providerJournal.load(s);
      _check(epoch);
      if (!entries.any(
        (e) =>
            e.requestId == command.requestId &&
            jsonEncode(e.params) == jsonEncode(command.params),
      )) {
        throw const CcsopFailure('PROVIDER_ORIGINAL_REQUEST_REQUIRED');
      }
      _providerIdentity(command.query.channel);
      final raw = await _paymentCall(
        command,
        epoch,
        closeUnpaid: closeUnpaid,
        stillCurrent: stillCurrent,
      );
      _check(epoch);
      _providerIdentity(command.query.channel);
      final result = ProviderPaymentResult.parse(raw, command);
      if (result.resolved) await _providerJournal.acknowledge(s, command);
      _check(epoch);
      return result;
    } finally {
      _providerBusy = false;
    }
  }

  Future<ProviderPaymentResult> retryOriginalProvider(
    ProviderPayment command, {
    required String authCode,
    required bool Function() stillCurrent,
  }) async {
    if (_providerBusy) throw const CcsopFailure('PAYMENT_IN_PROGRESS');
    _providerBusy = true;
    try {
      final s = _providerIdentity(command.query.channel), epoch = _epoch;
      if (!command.query.belongsTo(s) ||
          !validProviderCode(command.query.channel, authCode)) {
        throw const CcsopFailure('PROVIDER_SCOPE_CHANGED');
      }
      final entries = await _providerJournal.load(s);
      _check(epoch);
      _providerIdentity(command.query.channel);
      if (!entries.any(
        (e) =>
            e.requestId == command.requestId &&
            jsonEncode(e.params) == jsonEncode(command.params),
      )) {
        throw const CcsopFailure('PROVIDER_ORIGINAL_REQUEST_REQUIRED');
      }
      final observed = ProviderPaymentResult.parse(
        await _paymentCall(command, epoch),
        command,
      );
      _check(epoch);
      _providerIdentity(command.query.channel);
      if (observed.resolved) {
        await _providerJournal.acknowledge(s, command);
        _check(epoch);
        return observed;
      }
      if (!['not_sent', 'not_observed'].contains(observed.state)) {
        return observed;
      }
      if (!stillCurrent()) throw const CcsopFailure('PAYMENT_CONTEXT_CHANGED');
      final result = ProviderPaymentResult.parse(
        await _paymentCall(
          command,
          epoch,
          authCode: authCode,
          stillCurrent: stillCurrent,
        ),
        command,
      );
      _check(epoch);
      _providerIdentity(command.query.channel);
      if (result.resolved) await _providerJournal.acknowledge(s, command);
      _check(epoch);
      return result;
    } finally {
      _providerBusy = false;
    }
  }

  bool _cashBusy = false;

  /// Routes protocol differences behind the same durable request/UI workflow.
  /// A balance intent is recovered by its original request before every debit.
  Future<Object?> _paymentCall(
    ProviderPayment command,
    int epoch, {
    String? authCode,
    bool closeUnpaid = false,
    bool Function()? stillCurrent,
  }) async {
    void check() {
      _check(epoch);
      _providerIdentity(command.query.channel);
    }

    void checkSend() {
      check();
      if (stillCurrent?.call() != true) {
        throw const CcsopFailure('PAYMENT_CONTEXT_CHANGED');
      }
    }

    check();
    if (closeUnpaid) {
      if (command.query.channel != 'alipay' || authCode != null)
        throw const CcsopFailure('PROVIDER_SCOPE_CHANGED');
      checkSend();
      return _api!.call('K261002001962', command.params);
    }
    if (command.query.channel != 'member_balance') {
      if (authCode != null) checkSend();
      return _api!.call(authCode == null ? 'K260930001949' : 'K260930001948', {
        ...command.params,
        'authCode': ?authCode,
      });
    }
    var admission = PaymentAdmissionResult.parse(
      await _api!.call('K260929001923', command.query.params),
      command.query,
    );
    check();
    if (!admission.observed) {
      if (authCode == null) {
        return {
          'result': {'state': 'not_observed', 'requestId': command.requestId},
        };
      }
      checkSend();
      final params = {...command.query.params}..remove('channel');
      final prepared = await _api!.call('K260930001926', params);
      check();
      admission = PaymentAdmissionResult.parse({
        'result': {
          'state': 'intent_observed',
          'requestId': command.requestId,
          'intent': prepared is Map ? prepared['result'] : null,
        },
      }, command.query);
    }
    if (![
      'prepared',
      'confirmed',
      'closed',
    ].contains(admission.admissionStatus)) {
      return {
        'result': {'state': 'unknown', 'requestId': command.requestId},
      };
    }
    final scope = {
      'storeRef': command.params['storeRef'],
      'orderRef': command.params['orderRef'],
      'intentRef': admission.intentRef,
      'expectedTotalCents': command.params['expectedTotalCents'],
      'accountType': command.accountType,
    };
    Object normalize(Object? raw) {
      final value = raw is Map ? raw['result'] : null;
      if (value is Map && value['state'] == 'closed_unpaid') {
        if (value['requestId'] != command.requestId ||
            value['receipt'] is! Map ||
            value['receipt']['intentRef'] != admission.intentRef) {
          throw const CcsopFailure('PROVIDER_RECEIPT_INVALID');
        }
        ProviderPaymentResult.parse(raw, command);
        return raw as Object;
      }
      if (value is! Map ||
          ![
            'confirmed',
            'not_sent',
            'closed_or_refunded',
          ].contains(value['state']) ||
          (value['state'] == 'closed_or_refunded' &&
              (value.length != 3 ||
                  value['intentRef'] != admission.intentRef ||
                  value['refundRef'] is! String ||
                  !uuidPattern.hasMatch(value['refundRef']))) ||
          (value['state'] == 'not_sent' &&
              (value.length != 2 ||
                  value['intentRef'] != admission.intentRef)) ||
          (value['state'] == 'confirmed' &&
              (value.length != 2 ||
                  value['receipt'] is! Map ||
                  value['receipt']['intentRef'] != admission.intentRef))) {
        throw const CcsopFailure('PROVIDER_RECEIPT_INVALID');
      }
      return {
        'result': {
          'state': value['state'],
          'requestId': command.requestId,
          if (value['state'] == 'confirmed') 'receipt': value['receipt'],
          if (value['state'] == 'closed_or_refunded') ...{
            'intentRef': value['intentRef'],
            'refundRef': value['refundRef'],
          },
        },
      };
    }

    final original = normalize(await _api!.call('K260930001928', scope));
    check();
    final observed = ProviderPaymentResult.parse(original, command);
    if (authCode == null || observed.confirmed) return original;
    if (observed.state != 'not_sent') return original;
    checkSend();
    final result = normalize(
      await _api!.call('K260930001927', {...scope, 'paymentCode': authCode}),
    );
    check();
    return result;
  }

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
  bool _canRetryRestore = false;
  bool get canRetryRestore => _canRetryRestore;
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
    _canRetryRestore = false;
    _error = null;
    final epoch = ++_epoch;
    _changed();
    return epoch;
  }

  Future<Map<String, dynamic>> qrLoginCall(String base, Map<String, dynamic> params,
      {required bool Function() stillCurrent}) async {
    if (_session != null || _busy) throw const CcsopFailure('SESSION_CHANGED');
    final epoch = _epoch, canonicalBase = serviceBase(base).toString();
    final device = await _vault.deviceId();
    _check(epoch);
    if (!stillCurrent()) throw const CcsopFailure('SESSION_CHANGED');
    final channel = _authFactory(canonicalBase);
    try {
      final result = await channel.call('K261004002008', {...params, 'deviceId': device});
      _check(epoch);
      if (!stillCurrent() || _session != null || _busy) throw const CcsopFailure('SESSION_CHANGED');
      if (result['sessionId'] != null) {
        final installEpoch = _begin();
        try {
          await _install(StaffSession.fromServer(result, base: canonicalBase, deviceId: device,
            expectedStore: params['storeRef'] as String?, now: _now()), installEpoch);
        } catch(error) { await _fail(error, installEpoch); rethrow; }
        finally { _finish(installEpoch); }
      }
      return result;
    } finally { channel.close(); }
  }

  Future<void> login({
    required String base,
    String? storeRef,
    Future<String?> Function(List<Map<String, String>> stores)? selectStore,
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
      var result = await auth.call('K260929001901', {
        'loginName': loginName,
        'password': password,
        'storeRef': ?storeRef,
        'deviceId': device,
      });
      _check(epoch);
      if (result['requiresStoreSelection'] == true) {
        final rawStores = result['stores'];
        if (rawStores is! List || rawStores.length < 2 || selectStore == null) {
          throw const CcsopFailure('INVALID_RESPONSE');
        }
        final stores = <Map<String, String>>[];
        final refs = <String>{};
        for (final raw in rawStores) {
          if (raw is! Map ||
              raw['storeRef'] is! String ||
              raw['storeName'] is! String) {
            throw const CcsopFailure('INVALID_RESPONSE');
          }
          final ref = raw['storeRef'] as String,
              name = raw['storeName'] as String;
          if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(ref) ||
              name.isEmpty ||
              name.length > 128 ||
              !refs.add(ref)) {
            throw const CcsopFailure('INVALID_RESPONSE');
          }
          stores.add(Map.unmodifiable({'storeRef': ref, 'storeName': name}));
        }
        storeRef = await selectStore(List.unmodifiable(stores)).timeout(
          const Duration(minutes: 2),
          onTimeout: () => throw const CcsopFailure('STORE_SELECTION_EXPIRED'),
        );
        _check(epoch);
        if (storeRef == null) return;
        if (!refs.contains(storeRef)) {
          throw const CcsopFailure('INVALID_RESPONSE');
        }
        result = await auth.call('K260929001901', {
          'loginName': loginName,
          'password': password,
          'storeRef': storeRef,
          'deviceId': device,
        });
        _check(epoch);
      }
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
    StaffSession? saved;
    bool refreshAttempted = false;
    _session = null;
    _updateOperatorAvatar(null);
    _api?.close();
    _api = null;
    _changed();
    try {
      saved = prior ?? await _vault.load(now: _now());
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
      refreshAttempted = true;
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
      // Only a transport-proven unsent refresh may retain the old credential.
      // Ambiguous delivery can rotate the token server-side and must not replay.
      final retrySaved = saved;
      if (_current(epoch) &&
          refreshAttempted &&
          retrySaved != null &&
          error is CcsopFailure &&
          error.code == 'TRANSPORT_FAILED' &&
          !error.deliveryUncertain &&
          retrySaved.canRefresh(_now())) {
        try {
          final retained = await _vault.saveIfCurrent(
            retrySaved,
            () => _current(epoch) && retrySaved.canRefresh(_now()),
          );
          if (_current(epoch)) _canRetryRestore = retained;
        } catch (_) {
          if (_current(epoch)) _error = 'SECURE_STORAGE_FAILED';
        }
      }
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
    if (_session?.employeeRef != session.employeeRef) _updateOperatorAvatar(null);
    _session = session;
    _api = api;
  }

  Future<void> _fail(Object error, int epoch) async {
    if (!_current(epoch)) return;
    _session = null;
    _updateOperatorAvatar(null);
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

  Future<Map<String,dynamic>> prepareDouyinVoucher(String scan) async {
    final identity=_session,api=_api,epoch=_epoch;
    if(identity==null||api==null||_busy||!identity.expiresAt.isAfter(_now()))throw const CcsopFailure('SESSION_REQUIRED');
    if(!identity.permissions.contains('voucher.douyin'))throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    if(scan.isEmpty||scan.length>8192)throw const FormatException();
    final random=Random.secure(),bytes=List.generate(16,(_)=>random.nextInt(256));
    bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;
    final hex=bytes.map((value)=>value.toRadixString(16).padLeft(2,'0')).join();
    final id='${hex.substring(0,8)}-${hex.substring(8,12)}-${hex.substring(12,16)}-${hex.substring(16,20)}-${hex.substring(20)}';
    final raw=await api.call('K261005002011',{'storeRef':identity.storeRef,'preparationRef':id,'scan':scan});
    _check(epoch);
    if(!identical(identity,_session)||!identity.expiresAt.isAfter(_now()))throw const CcsopFailure('SESSION_REQUIRED');
    final result=raw is Map<String,dynamic>?raw['result']:null;
    if(result is! Map<String,dynamic>||result['preparationRef']!=id||!['prepared','expired','claimed'].contains(result['state']))throw const FormatException();
    return result;
  }

  Future<Map<String,dynamic>> confirmDouyinRedemption({required String preparationRef,required String requestId,required int selectionIndex}) async {
    final identity=_session,api=_api,epoch=_epoch;
    if(identity==null||api==null||!identity.expiresAt.isAfter(_now()))throw const CcsopFailure('SESSION_REQUIRED');
    if(!identity.permissions.contains('voucher.douyin'))throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    final raw=await api.call('K261005002012',{'storeRef':identity.storeRef,'preparationRef':preparationRef,
      'requestId':requestId,'selectionIndex':selectionIndex,'confirmed':true});
    _check(epoch);
    if(!identical(identity,_session))throw const CcsopFailure('SESSION_REQUIRED');
    final result=raw is Map<String,dynamic>?raw['result']:null;
    if(result is! Map<String,dynamic>||!['completed','unknown'].contains(result['state']))throw const FormatException();
    return result;
  }

  Future<VoucherLookup> lookupVoucher({
    required String provider,
    required String requestId,
  }) async {
    final session = _session, api = _api, epoch = _epoch;
    if (session == null ||
        api == null ||
        _busy ||
        !session.expiresAt.isAfter(_now()))
      throw const CcsopFailure('SESSION_REQUIRED');
    if (!['douyin', 'meituan'].contains(provider) ||
        !uuidPattern.hasMatch(requestId))
      throw const FormatException();
    if (!session.permissions.contains('voucher.$provider'))
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    final raw = await api.call('K260930001950', {
      'storeRef': session.storeRef,
      'provider': provider,
      'requestId': requestId,
    });
    _check(epoch);
    if (!identical(session, _session) || !session.expiresAt.isAfter(_now()))
      throw const CcsopFailure('SESSION_REQUIRED');
    return VoucherLookup.parse(
      raw,
      storeRef: session.storeRef,
      employeeRef: session.employeeRef,
      provider: provider,
      requestId: requestId,
    );
  }

  Future<Object?> readVoucherReport({
    required String from,
    required String to,
    String provider = 'all',
    String? afterVoucher,
  }) async {
    final session = _session, api = _api, epoch = _epoch;
    if (session == null ||
        api == null ||
        _busy ||
        !session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!session.permissions.contains('report.read'))
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    if ((afterVoucher != null &&
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(afterVoucher)) ||
        !['all', 'douyin', 'meituan'].contains(provider) ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(from) ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(to) ||
        from.compareTo(to) > 0) {
      throw const FormatException('Invalid report filter');
    }
    final result = await api.call('K260930001924', {
      'storeRef': session.storeRef,
      'from': from,
      'to': to,
      if (provider != 'all') 'provider': provider,
      'afterVoucher': ?afterVoucher,
    });
    _check(epoch);
    if (!identical(session, _session) || !session.expiresAt.isAfter(_now()))
      throw const CcsopFailure('SESSION_REQUIRED');
    return result;
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
    final result = value is Map ? value['result'] : null;
    final operator = result is Map ? result['operator'] : null;
    _updateOperatorAvatar(operator is Map ? operator['avatarBase64'] : null);
    return value;
  }

  Future<Object?> readTableCalendar({
    required String selectedDate,
    String? afterSession,
  }) async {
    final session = _session, api = _api, epoch = _epoch;
    if (session == null ||
        api == null ||
        _busy ||
        !session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    final value = await api.call('K260929001902', {
      'storeRef': session.storeRef,
      'selectedDate': selectedDate,
      'afterSession': ?afterSession,
    });
    _check(epoch);
    if (!session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    return value;
  }

  Future<Object?> saveTableReservation(Map<String, Object> params) async {
    final identity = _session, api = _api, epoch = _epoch;
    if (identity == null ||
        api == null ||
        _busy ||
        !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    final value = await api.call('K261003002001', {
      ...params,
      'storeRef': identity.storeRef,
    });
    _check(epoch);
    return value;
  }

  Future<void> reduceUnpaidItem({
    required String tableRef,
    required String sessionRef,
    required String orderRef,
    required String productRef,
    required int expectedQuantity,
    required int expectedServedQuantity,
    int? expectedServingEpoch,
    required int expectedTotalCents,
  }) async {
    final identity = _session, api = _api, epoch = _epoch;
    if (identity == null ||
        api == null ||
        _busy ||
        !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!identity.permissions.contains('orders.create')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    await _guardItemReturn(identity, orderRef, productRef, epoch);
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final requestId =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    final params = <String, Object>{
      'storeRef': identity.storeRef,
      'tableRef': tableRef,
      'sessionRef': sessionRef,
      'orderRef': orderRef,
      'productRef': productRef,
      'requestId': requestId,
      'expectedQuantity': expectedQuantity,
      'expectedServedQuantity': expectedServedQuantity,
      'expectedServingEpoch': ?expectedServingEpoch,
      'expectedTotalCents': expectedTotalCents,
      'quantity': 1,
    };
    // No automatic retry. The quantity/total preconditions also reject a second
    // command from an old display after a lost response; reload before another tap.
    final raw = await api.call('K261002001964', params);
    _check(epoch);
    final result = raw is Map ? raw['result'] : null;
    if (result is! Map ||
        params.entries.any((e) => result[e.key] != e.value) ||
        result['operatedBy'] != identity.employeeRef ||
        result['remainingQuantity'] != expectedQuantity - 1 ||
        result['remainingTotalCents'] is! int ||
        (result['remainingTotalCents'] as int) < 0 ||
        (result['remainingTotalCents'] as int) > expectedTotalCents ||
        !(result['remainingTotalCents'] == 0
                ? const {'expired', 'waived'}
                : const {'pending'})
            .contains(result['orderStatus'])) {
      throw const CcsopFailure(
        'ORDER_REDUCTION_RECEIPT_INVALID',
        deliveryUncertain: true,
      );
    }
  }

  Future<String> authorizeItemPrice({
    required Map<String, Object> scope,
    required String identityCode,
  }) async {
    final identity = _session, api = _api, epoch = _epoch;
    if (identity == null ||
        api == null ||
        !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    final expected = <String, Object>{...scope, 'storeRef': identity.storeRef};
    final raw = await api.call('K261003002002', {
      'scope': expected,
      'identityCode': identityCode,
    });
    _check(epoch);
    final result = raw is Map ? raw['result'] : null;
    if (result is! Map ||
        result['authorizationRef'] is! String ||
        !uuidPattern.hasMatch(result['authorizationRef'] as String) ||
        result['scope'] is! Map ||
        !expected.entries.every((e) => result['scope'][e.key] == e.value))
      throw const FormatException();
    return result['authorizationRef'] as String;
  }

  Future<Map<String, dynamic>> adjustTableBill(
    Map<String, Object> request, {
    String? identityCode,
    bool queryOnly = false,
  }) async {
    final identity = _session, api = _api, epoch = _epoch;
    if (identity == null ||
        api == null ||
        _busy ||
        !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!identity.permissions.contains('orders.create'))
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    final raw = await api.call('K261004002006', {
      ...request,
      'storeRef': identity.storeRef,
      'queryOnly': queryOnly,
      if (identityCode != null) 'identityCode': identityCode,
    });
    _check(epoch);
    final result = raw is Map ? raw['result'] : null;
    if (result is! Map ||
        result['requestId'] != request['requestId'] ||
        !['applied', 'not_observed'].contains(result['state'])) {
      throw const CcsopFailure('ITEM_PRICE_STATE_CHANGED');
    }
    if (result['state'] == 'applied' &&
        [
          'totalCents',
          'discountCents',
          'changedLines',
        ].any((key) => result[key] is! int || (result[key] as int) < 0)) {
      throw const CcsopFailure('ITEM_PRICE_STATE_CHANGED');
    }
    return Map<String, dynamic>.from(result);
  }

  Future<String> repriceUnpaidItems({
    required String tableRef,
    required String sessionRef,
    required String productRef,
    required int unitPriceCents,
    String? expenseOwnerUserAccount,
    String? authorizationRef,
    required List<Map<String, Object>> items,
  }) async {
    final identity = _session, api = _api, epoch = _epoch;
    if (identity == null ||
        api == null ||
        _busy ||
        !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!identity.permissions.contains('orders.create')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    if (unitPriceCents < 0 ||
        unitPriceCents > 100000000 ||
        items.isEmpty ||
        items.length > 1000 ||
        items.map((i) => i['orderRef']).toSet().length != items.length) {
      throw const CcsopFailure('ITEM_PRICE_INVALID');
    }
    final lines = items.map((i) => Map<String, Object>.from(i)).toList()
      ..sort(
        (a, b) => (a['orderRef'] as String).compareTo(b['orderRef'] as String),
      );
    for (final line in lines) {
      await _guardItemReturn(
        identity,
        line['orderRef'] as String,
        productRef,
        epoch,
      );
    }
    final random = Random.secure(), bytes = List.generate(16, (_) => 0);
    for (var i = 0; i < 16; i++) {
      bytes[i] = random.nextInt(256);
    }
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final requestId =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    final scope = <String, Object>{
      'storeRef': identity.storeRef,
      'tableRef': tableRef,
      'sessionRef': sessionRef,
      'productRef': productRef,
      'unitPriceCents': unitPriceCents,
      if (expenseOwnerUserAccount != null)
        'expenseOwnerUserAccount': expenseOwnerUserAccount,
      if (authorizationRef != null) 'authorizationRef': authorizationRef,
    };
    final raw = await api.call('K261002001964', {
      ...scope,
      'requestId': requestId,
      'items': lines,
    });
    _check(epoch);
    final result = raw is Map ? raw['result'] : null;
    final receipts = result is Map ? result['items'] : null;
    final selectionRef = result is Map ? result['selectionRef'] : null;
    bool valid =
        result is Map &&
        result['requestId'] == requestId &&
        selectionRef is String &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(selectionRef) &&
        scope.entries.every((e) => result[e.key] == e.value) &&
        receipts is List &&
        receipts.length == lines.length;
    if (valid) {
      final refs = <Object?>{};
      for (var i = 0; i < lines.length; i++) {
        final row = receipts[i], line = lines[i];
        final quantity = line['expectedQuantity'] as int;
        final expected =
            (line['expectedTotalCents'] as int) +
            quantity *
                (unitPriceCents - (line['expectedUnitPriceCents'] as int));
        if (row is! Map ||
            !scope.entries.every((e) => row[e.key] == e.value) ||
            !line.entries.every((e) => row[e.key] == e.value) ||
            row['operatedBy'] != identity.employeeRef ||
            row['priceBatchFingerprint'] != selectionRef ||
            row['quantity'] != quantity ||
            row['remainingQuantity'] != quantity ||
            row['remainingTotalCents'] != expected ||
            row['orderStatus'] != (expected == 0 ? 'waived' : 'pending') ||
            row['requestId'] is! String ||
            !uuidPattern.hasMatch(row['requestId'] as String) ||
            !refs.add(row['requestId'])) {
          valid = false;
          break;
        }
      }
    }
    if (!valid) {
      throw const CcsopFailure(
        'ITEM_PRICE_RECEIPT_INVALID',
        deliveryUncertain: true,
      );
    }
    return selectionRef as String;
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

  Future<Map<String, dynamic>> wineStorage(Map<String, dynamic> params) async {
    final identity = _session, api = _api, epoch = _epoch;
    if (identity == null ||
        api == null ||
        !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    final raw = await api.call('K261004002007', {
      ...params,
      'storeRef': identity.storeRef,
    });
    _check(epoch);
    final result = raw is Map ? raw['result'] : null;
    if (result is! Map ||
        result['storeRef'] != identity.storeRef ||
        ![
          'tableRef',
          'sessionRef',
          'orderRef',
          'productRef',
        ].every((k) => result[k] == params[k])) {
      throw const FormatException();
    }
    return Map<String, dynamic>.from(result);
  }

  Future<List<Map<String, String?>>> tableMembers({
    required String tableRef,
    required String sessionRef,
    String? identityCode,
  }) async {
    final identity = _session, api = _api, epoch = _epoch;
    if (identity == null ||
        api == null ||
        !identity.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    final scope = {
      'storeRef': identity.storeRef,
      'tableRef': tableRef,
      'sessionRef': sessionRef,
    };
    final raw = await api.call('K261003002003', {
      ...scope,
      'action': identityCode == null ? 'list' : 'link',
      'identityCode': ?identityCode,
    });
    _check(epoch);
    final result = raw is Map ? raw['result'] : null;
    if (result is! Map ||
        !scope.entries.every((e) => result[e.key] == e.value) ||
        result['members'] is! List) {
      throw const FormatException();
    }
    final seen = <String>{};
    return List.unmodifiable(
      (result['members'] as List).map((row) {
        if (row is! Map ||
            row['userAccount'] is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{1,64}$')
                .hasMatch(row['userAccount'] as String) ||
            !seen.add(row['userAccount'] as String) ||
            (row['nickname'] != null && row['nickname'] is! String) ||
            row['linkedBy'] is! String ||
            row['linkedAt'] is! String) {
          throw const FormatException();
        }
        return Map<String, String?>.unmodifiable({
          'userAccount': row['userAccount'] as String,
          'nickname': row['nickname'] as String?,
          'avatarBase64': row['avatarBase64'] is String
              ? row['avatarBase64'] as String
              : null,
          'linkedBy': row['linkedBy'] as String,
          'linkedAt': row['linkedAt'] as String,
        });
      }),
    );
  }

  Future<TogetherAdmission> consumeTogetherAdmission(String code) async {
    final session = _session, api = _api, epoch = _epoch;
    if (session == null ||
        api == null ||
        _busy ||
        !session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!session.permissions.contains('together.admit')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    if (!TogetherAdmission.codePattern.hasMatch(code)) {
      throw const CcsopFailure('TOGETHER_ADMISSION_INVALID');
    }
    final result = await api.call('K261004001990', {
      'storeRef': session.storeRef,
      'admissionCode': code,
    });
    _check(epoch);
    if (!identical(session, _session) || !session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    return TogetherAdmission.parse(result, storeRef: session.storeRef);
  }

  Future<MemberIdentity> readMemberIdentity(String identityCode) async {
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
    if (!MemberIdentity.codePattern.hasMatch(identityCode)) {
      throw const CcsopFailure('CASHIER_MEMBER_IDENTITY_INVALID');
    }
    final elapsed = Stopwatch()..start();
    final raw = await api.call('K261001001951', {
      'storeRef': session.storeRef,
      'identityCode': identityCode,
    });
    _check(epoch);
    if (!session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    return MemberIdentity.parse(
      raw,
      storeRef: session.storeRef,
      elapsed: elapsed.elapsed,
    );
  }

  StaffSession _seatingIdentity() {
    final session = _session;
    if (_disposed ||
        _busy ||
        session == null ||
        _api == null ||
        !session.expiresAt.isAfter(_now())) {
      throw const CcsopFailure('SESSION_REQUIRED');
    }
    if (!session.permissions.contains('table.open') ||
        !session.permissions.contains('orders.create')) {
      throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
    }
    return session;
  }

  Future<T> _seatingOperation<T>(Future<T> Function() work) async {
    if (_seatingBusy) throw const CcsopFailure('SEATING_IN_PROGRESS');
    _seatingBusy = true;
    try {
      return await work();
    } finally {
      _seatingBusy = false;
    }
  }

  Future<List<PendingSeating>> pendingSeating() async {
    final session = _seatingIdentity(), epoch = _epoch;
    final rows = await _seatingJournal.load(session);
    _check(epoch);
    _seatingIdentity();
    return rows;
  }

  Future<SeatingResult> _seatingCall(
    PendingSeating command,
    StaffSession session,
    int epoch,
    String interfaceId,
    Map<String, dynamic> params,
  ) async {
    _check(epoch);
    _seatingIdentity();
    if (!command.belongsTo(session))
      throw const CcsopFailure('SEATING_SCOPE_CHANGED');
    final raw = await _api!.call(interfaceId, params);
    _check(epoch);
    _seatingIdentity();
    final result = SeatingResult.parse(raw, command);
    if (interfaceId != 'K261001001953' && !result.terminal)
      throw const CcsopFailure('SEATING_RESPONSE_INVALID');
    if (result.terminal) await _seatingJournal.acknowledge(session, result);
    _check(epoch);
    _seatingIdentity();
    return result;
  }

  Future<SeatingResult> confirmSeating(
    PendingSeating command,
    String identityCode, {
    required bool confirmed,
    required bool Function() stillCurrent,
  }) => _seatingOperation(() async {
    final session = _seatingIdentity(), epoch = _epoch;
    void check() {
      _check(epoch);
      _seatingIdentity();
      if (!confirmed ||
          !stillCurrent() ||
          !command.belongsTo(session) ||
          !MemberIdentity.codePattern.hasMatch(identityCode)) {
        throw const CcsopFailure('SEATING_CONFIRMATION_REQUIRED');
      }
    }

    check();
    // Save and verify the recovery scope before admission. Never save the QR.
    await _seatingJournal.save(command, session);
    check();
    return _seatingCall(command, session, epoch, 'K261001001952', {
      ...command.params,
      'identityCode': identityCode,
      'arrivalConfirmed': true,
      'reservationChecked': true,
    });
  });

  Future<SeatingResult> recoverSeating(
    String requestId, {
    bool cancelUnsent = false,
    bool Function()? stillCurrent,
  }) => _seatingOperation(() async {
    final session = _seatingIdentity(), epoch = _epoch;
    final rows = await _seatingJournal.load(session);
    _check(epoch);
    _seatingIdentity();
    final matches = rows.where((row) => row.requestId == requestId).toList();
    if (matches.length != 1)
      throw const CcsopFailure('SEATING_PENDING_NOT_FOUND');
    final command = matches.single;
    final observed = await _seatingCall(
      command,
      session,
      epoch,
      'K261001001953',
      command.lookup,
    );
    if (observed.terminal || !cancelUnsent) return observed;
    if (stillCurrent == null || !stillCurrent())
      throw const CcsopFailure('SEATING_SCOPE_CHANGED');
    return _seatingCall(command, session, epoch, 'K261001001954', {
      ...command.params,
      'cancellationConfirmed': true,
    });
  });

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

  Future<List<PendingItemReturn>> pendingItemReturns() async {
    final identity = _servingIdentity(), epoch = _epoch;
    final entries = await _itemReturnJournal.load(identity);
    _check(epoch);
    _servingIdentity();
    return entries;
  }

  Future<void> _guardItemReturn(
    StaffSession identity,
    String orderRef,
    String productRef,
    int epoch,
  ) async {
    final entries = await _itemReturnJournal.load(identity);
    _check(epoch);
    if (entries.any(
      (entry) => entry.orderRef == orderRef && entry.productRef == productRef,
    )) {
      throw const CcsopFailure('ITEM_RETURN_ALREADY_PENDING');
    }
  }

  Future<ItemReturnResult> _itemReturnCall(
    PendingItemReturn command,
    StaffSession identity,
    int epoch, {
    required bool lookup,
  }) async {
    _check(epoch);
    _servingIdentity();
    if (!command.belongsTo(identity)) {
      throw const CcsopFailure('ITEM_RETURN_SCOPE_CHANGED');
    }
    final raw = await _api!.call(
      lookup ? 'K261002001990' : 'K261002001969',
      command.params,
    );
    _check(epoch);
    _servingIdentity();
    final result = ItemReturnResult.parse(raw, command);
    if (!lookup && !result.confirmed) {
      throw const CcsopFailure('ITEM_RETURN_RESPONSE_INVALID');
    }
    if (result.confirmed) {
      await _itemReturnJournal.acknowledge(identity, result);
    }
    _check(epoch);
    _servingIdentity();
    return result;
  }

  Future<ItemReturnResult> confirmItemReturn({
    required Map<String, dynamic> fields,
    required int unitPriceCents,
  }) => _servingOperation(() async {
    final identity = _servingIdentity(), epoch = _epoch;
    final command = PendingItemReturn.prepare(
      identity: identity,
      fields: fields,
      unitPriceCents: unitPriceCents,
      now: _now(),
    );
    final serving = await _servingJournal.load(identity);
    _check(epoch);
    if (serving.any((entry) => entry.lineKey == command.lineKey)) {
      throw const CcsopFailure('SERVING_ALREADY_PENDING');
    }
    await _itemReturnJournal.save(command, identity);
    _check(epoch);
    return _itemReturnCall(command, identity, epoch, lookup: false);
  });

  /// A query never repeats the mutation. Resending requires an explicit action
  /// and always uses the exact persisted original request.
  Future<ItemReturnResult> recoverItemReturn(
    String requestId, {
    bool retryOriginal = false,
  }) => _servingOperation(() async {
    final identity = _servingIdentity(), epoch = _epoch;
    final entries = await _itemReturnJournal.load(identity);
    _check(epoch);
    final matches = entries
        .where((entry) => entry.requestId == requestId)
        .toList();
    if (matches.length != 1) {
      throw const CcsopFailure('ITEM_RETURN_PENDING_NOT_FOUND');
    }
    final command = matches.single;
    final result = await _itemReturnCall(
      command,
      identity,
      epoch,
      lookup: true,
    );
    if (!result.confirmed && retryOriginal) {
      return _itemReturnCall(command, identity, epoch, lookup: false);
    }
    return result;
  });

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
      command.recall
          ? (lookup ? 'K261002001968' : 'K261002001967')
          : (lookup ? 'K260929001920' : 'K260929001919'),
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
    int? expectedServingEpoch,
    required bool confirmed,
  }) => _servingOperation(() async {
    final identity = _servingIdentity(), epoch = _epoch;
    await _guardItemReturn(identity, orderRef, productRef, epoch);
    final command = PendingServing.prepare(
      identity: identity,
      tableRef: tableRef,
      sessionRef: sessionRef,
      orderRef: orderRef,
      productRef: productRef,
      quantity: quantity,
      expectedServedQuantity: expectedServedQuantity,
      targetServedQuantity: targetServedQuantity,
      expectedServingEpoch: expectedServingEpoch,
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
  Future<ReceiptDocument> readReceiptDocument(String orderRef) async {
    final epoch = _epoch;
    final store = _session?.storeRef;
    void validate() {
      _check(epoch);
      final identity = _session;
      if (_busy ||
          identity == null ||
          _api == null ||
          !identity.expiresAt.isAfter(_now())) {
        throw const CcsopFailure('SESSION_REQUIRED');
      }
      if (identity.storeRef != store ||
          !identity.permissions.contains('orders.read')) {
        throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
      }
    }

    validate();
    if (!RegExp(r'^D[0-9]{11}$').hasMatch(orderRef))
      throw const CcsopFailure('RECEIPT_ORDER_INVALID');
    final raw = await _api!.call('K260930001932', {
      'storeRef': store,
      'orderRef': orderRef,
    });
    validate();
    return ReceiptDocument.parse(raw, storeRef: store!, orderRef: orderRef);
  }

  /// Original settled table receipt only; never confirms or retries a payment.
  Future<TableReceiptDocument> readTableReceiptDocument(
    String checkoutRef,
  ) async {
    final epoch = _epoch;
    final store = _session?.storeRef;
    void validate() {
      _check(epoch);
      final identity = _session;
      if (_busy ||
          identity == null ||
          _api == null ||
          !identity.expiresAt.isAfter(_now())) {
        throw const CcsopFailure('SESSION_REQUIRED');
      }
      if (identity.storeRef != store ||
          !identity.permissions.contains('orders.read')) {
        throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
      }
    }

    validate();
    if (!RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(checkoutRef)) {
      throw const CcsopFailure('TABLE_RECEIPT_CHECKOUT_INVALID');
    }
    final raw = await _api!.call('K260930001936', {
      'storeRef': store,
      'checkoutRef': checkoutRef,
    });
    validate();
    return TableReceiptDocument.parse(
      raw,
      storeRef: store!,
      checkoutRef: checkoutRef,
    );
  }

  /// Query-only channel recovery may finish a previously paid recharge on the
  /// server. It never sends a new payer code, prepares a new order or retries pay.
  Future<RechargeResult> queryRecharge(
    String rechargeRef, {
    required String channel,
    int? expectedPrincipalCents,
  }) async {
    final epoch = _epoch, store = _session?.storeRef;
    if (!validRechargeRef(rechargeRef) ||
        !['wechat', 'alipay'].contains(channel) ||
        (expectedPrincipalCents != null &&
            (expectedPrincipalCents < 1 ||
                expectedPrincipalCents > 100000000))) {
      throw const CcsopFailure('RECHARGE_QUERY_INVALID');
    }
    void validate() {
      _check(epoch);
      final identity = _session;
      if (_busy ||
          identity == null ||
          _api == null ||
          !identity.expiresAt.isAfter(_now())) {
        throw const CcsopFailure('SESSION_REQUIRED');
      }
      if (identity.storeRef != store ||
          !identity.permissions.contains('payment.$channel')) {
        throw const CcsopFailure('CASHIER_PERMISSION_DENIED');
      }
    }

    validate();
    final raw = await _api!.call('K260930001934', {
      'storeRef': store,
      'rechargeRef': rechargeRef,
    });
    validate();
    return RechargeResult.parse(
      raw,
      storeRef: store!,
      rechargeRef: rechargeRef,
      expectedPrincipalCents: expectedPrincipalCents,
    );
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
    bool noCashCollectedConfirmed = false,
    bool cashReturnedConfirmed = false,
  }) => _cashOperation(() async {
    if (noCashCollectedConfirmed == cashReturnedConfirmed) {
      throw const CcsopFailure('CASH_CONFIRMATION_REQUIRED');
    }
    final identity = _cashIdentity(), epoch = _epoch;
    final previous = await _pendingCash(requestId, identity, epoch);
    final command = previous.recordClosure(
      noCashCollectedConfirmed: noCashCollectedConfirmed,
      cashReturnedConfirmed: cashReturnedConfirmed,
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
    required String? memberRef,
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
  Future<RestoredCart> restoreCartDraft(CartDraft draft) =>
      _orderOperation(() async {
        final identity = _orderIdentity(), epoch = _epoch;
        if (!draft.belongsTo(identity)) {
          throw const CcsopFailure('CART_DRAFT_CONTEXT_CHANGED');
        }
        final saved = await cartDrafts();
        if (!saved.any((d) => d.signature == draft.signature)) {
          throw const CcsopFailure('CART_DRAFT_EDIT_CONFLICT');
        }
        return _refreshCartSelection(draft, identity, epoch);
      });

  /// Revalidate an in-memory selection without persisting or submitting it.
  Future<RestoredCart> refreshCartSelection({
    required OrderContextSnapshot context,
    required String? memberRef,
    required List<OrderSelection> items,
  }) => _orderOperation(() async {
    final identity = _orderIdentity(), epoch = _epoch;
    final draft = CartDraft.capture(
      identity: identity,
      context: context,
      memberRef: memberRef,
      items: items,
      now: _now(),
    );
    return _refreshCartSelection(draft, identity, epoch);
  });

  Future<RestoredCart> _refreshCartSelection(
    CartDraft draft,
    StaffSession identity,
    int epoch,
  ) async {
    await _requireNoPendingCart(draft.tableRef);
    OrderContextSnapshot? context;
    String? cursor;
    for (var page = 0; page < 200; page++) {
      final next = await readOrderContext(
        tableRef: draft.tableRef,
        sessionRef: draft.sessionRef,
        afterMember: cursor,
      );
      if (draft.memberRef == null
          ? next.tableOrderAllowed
          : next.members.any((m) => m.reference == draft.memberRef)) {
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
  }

  Future<OrderRequestResult> submitOrder({
    required OrderContextSnapshot context,
    required String? memberRef,
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
      interfaceId == 'K260929001912'
          ? (Map<String, dynamic>.of(
              command.params,
            )..removeWhere((key, value) => key == 'memberRef' && value == null))
          : command.lookup,
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
    Map<String, dynamic>? selectedRule,
  }) => _openingOperation(() async {
    final identity = _openingIdentity(), epoch = _epoch;
    final pending = PendingOpening.prepare(
      session: identity,
      context: context,
      partySize: partySize,
      memberRefs: memberRefs,
      arrivalConfirmed: arrivalConfirmed,
      reservationChecked: reservationChecked,
      selectedRule: selectedRule,
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
    _canRetryRestore = false;
    _auth?.close();
    _auth = null;
    _session = null;
    _updateOperatorAvatar(null);
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
    _updateOperatorAvatar(null);
    operatorAvatar.dispose();
    super.dispose();
  }
}
