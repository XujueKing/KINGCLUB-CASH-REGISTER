import 'dart:convert';
import 'dart:math';

import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';

Map<String, dynamic> _map(Object? v) {
  if (v is! Map<String, dynamic>) throw const FormatException();
  return v;
}

bool _cents(Object? v) => v is int && v >= 1 && v <= 100000000;
bool _uuid(Object? v) => v is String && uuidPattern.hasMatch(v);

/// Durable original request plus irreversible local decision. Never an authorization or payment receipt.
class PendingCash {
  PendingCash._(
    this.base,
    this.employeeRef,
    this.deviceId,
    this.params,
    this.intentRef,
    this.receivedCents,
    this.closeRequested,
  );
  final String base, employeeRef, deviceId;
  final Map<String, dynamic> params;
  final String? intentRef;
  final int? receivedCents;
  final bool closeRequested;
  String get storeRef => params['storeRef'] as String;
  String get orderRef => params['orderRef'] as String;
  String get requestId => params['requestId'] as String;
  int get totalCents => params['expectedTotalCents'] as int;
  bool get initial =>
      intentRef == null && receivedCents == null && !closeRequested;
  bool belongsTo(StaffSession s) =>
      base == s.base.toString() &&
      employeeRef == s.employeeRef &&
      deviceId == s.deviceId &&
      storeRef == s.storeRef;
  Map<String, dynamic> encode() => {
    'base': base,
    'employeeRef': employeeRef,
    'deviceId': deviceId,
    'params': params,
    'intentRef': intentRef,
    'receivedCents': receivedCents,
    'closeRequested': closeRequested,
  };
  String get signature => jsonEncode(encode());
  Map<String, dynamic> get lookup => Map.unmodifiable({
    'storeRef': storeRef,
    'orderRef': orderRef,
    'requestId': requestId,
  });
  Map<String, dynamic> get confirm {
    if (intentRef == null || receivedCents == null || closeRequested) {
      throw const CcsopFailure('CASH_DECISION_REQUIRED');
    }
    return Map.unmodifiable({
      'storeRef': storeRef,
      'orderRef': orderRef,
      'intentRef': intentRef,
      'expectedTotalCents': totalCents,
      'receivedCents': receivedCents,
      'cashReceivedConfirmed': true,
    });
  }

  Map<String, dynamic> get close {
    if (intentRef == null || !closeRequested) {
      throw const CcsopFailure('CASH_DECISION_REQUIRED');
    }
    return Map.unmodifiable({
      ...lookup,
      'intentRef': intentRef,
      'expectedTotalCents': totalCents,
      if (receivedCents == null)
        'noCashCollectedConfirmed': true
      else
        'cashReturnedConfirmed': true,
    });
  }

  factory PendingCash.prepare({
    required StaffSession identity,
    required String orderRef,
    required int totalCents,
    required DateTime now,
  }) {
    if (!identity.expiresAt.isAfter(now) ||
        !identity.permissions.contains('payment.cash')) {
      throw const CcsopFailure('CASH_SCOPE_CHANGED');
    }
    final random = Random.secure(),
        bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return PendingCash.decode({
      'base': identity.base.toString(),
      'employeeRef': identity.employeeRef,
      'deviceId': identity.deviceId,
      'params': {
        'storeRef': identity.storeRef,
        'orderRef': orderRef,
        'requestId': id,
        'expectedTotalCents': totalCents,
        'currency': 'CNY',
      },
      'intentRef': null,
      'receivedCents': null,
      'closeRequested': false,
    });
  }
  factory PendingCash.decode(Object? raw) {
    try {
      final v = _map(raw), p = _map(v['params']);
      final uri = v['base'] is String
          ? Uri.tryParse(v['base'] as String)
          : null;
      if (v.length != 7 ||
          p.length != 5 ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          v['employeeRef'] is! String ||
          !RegExp(r'^E[0-9]{11}$').hasMatch(v['employeeRef'] as String) ||
          !_uuid(v['deviceId']) ||
          p['storeRef'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(p['storeRef'] as String) ||
          p['orderRef'] is! String ||
          !RegExp(r'^D[0-9]{11}$').hasMatch(p['orderRef'] as String) ||
          !_uuid(p['requestId']) ||
          !_cents(p['expectedTotalCents']) ||
          p['currency'] != 'CNY' ||
          (v['intentRef'] != null && !_uuid(v['intentRef'])) ||
          v['closeRequested'] is! bool ||
          (v['receivedCents'] != null &&
              (!_cents(v['receivedCents']) ||
                  (v['receivedCents'] as int) <
                      (p['expectedTotalCents'] as int))) ||
          ((v['receivedCents'] != null || v['closeRequested'] == true) &&
              v['intentRef'] == null)) {
        throw const FormatException();
      }
      return PendingCash._(
        v['base'] as String,
        v['employeeRef'] as String,
        v['deviceId'] as String,
        Map.unmodifiable({
          'storeRef': p['storeRef'],
          'orderRef': p['orderRef'],
          'requestId': p['requestId'],
          'expectedTotalCents': p['expectedTotalCents'],
          'currency': 'CNY',
        }),
        v['intentRef'] as String?,
        v['receivedCents'] as int?,
        v['closeRequested'] as bool,
      );
    } catch (_) {
      throw const CcsopFailure('CASH_COMMAND_INVALID');
    }
  }
  PendingCash observe(CashResult result) {
    if (result.commandSignature != signature ||
        result.intentRef == null ||
        (intentRef != null && intentRef != result.intentRef)) {
      throw const CcsopFailure('CASH_RECEIPT_MISMATCH');
    }
    return PendingCash.decode({...encode(), 'intentRef': result.intentRef});
  }

  PendingCash recordConfirmation(
    int received, {
    required bool cashReceivedConfirmed,
  }) {
    if (!cashReceivedConfirmed ||
        intentRef == null ||
        closeRequested ||
        (receivedCents != null && receivedCents != received)) {
      throw const CcsopFailure('CASH_DECISION_CONFLICT');
    }
    return PendingCash.decode({...encode(), 'receivedCents': received});
  }

  PendingCash recordClosure({
    bool noCashCollectedConfirmed = false,
    bool cashReturnedConfirmed = false,
  }) {
    if (intentRef == null ||
        noCashCollectedConfirmed == cashReturnedConfirmed ||
        (receivedCents == null
            ? !noCashCollectedConfirmed
            : !cashReturnedConfirmed)) {
      throw const CcsopFailure('CASH_DECISION_CONFLICT');
    }
    return PendingCash.decode({...encode(), 'closeRequested': true});
  }

  bool follows(PendingCash old) =>
      base == old.base &&
      employeeRef == old.employeeRef &&
      deviceId == old.deviceId &&
      jsonEncode(params) == jsonEncode(old.params) &&
      (old.intentRef == null || intentRef == old.intentRef) &&
      (old.receivedCents == null || receivedCents == old.receivedCents) &&
      (!old.closeRequested ||
          (closeRequested && receivedCents == old.receivedCents));
}

enum CashState { notObserved, prepared, needsLookup, confirmed, closed }

enum CashResponse { prepare, lookup, confirm, close }

/// Only exact server evidence matched to a persisted command can terminate its journal entry.
class CashResult {
  CashResult._(
    this.state,
    this.commandSignature,
    this.intentRef,
    this.canConfirmCash,
    this.receivedCents,
    this.changeCents,
  );
  final CashState state;
  final String commandSignature;
  final String? intentRef;
  final bool canConfirmCash;
  final int? receivedCents, changeCents;
  bool get terminal =>
      state == CashState.confirmed || state == CashState.closed;
  factory CashResult.parse(
    Object? raw,
    PendingCash command, {
    required CashResponse response,
  }) {
    try {
      final r = _map(_map(raw)['result']);
      String? intent;
      void scope(Map<String, dynamic> v) {
        if (v['storeRef'] != command.storeRef ||
            v['orderRef'] != command.orderRef ||
            !_uuid(v['intentRef']) ||
            (command.intentRef != null &&
                v['intentRef'] != command.intentRef) ||
            v['totalCents'] is! int ||
            v['totalCents'] != command.totalCents ||
            v['currency'] != 'CNY') {
          throw const FormatException();
        }
        intent = v['intentRef'] as String;
      }

      CashResult result(
        CashState s, {
        bool allowed = false,
        int? received,
        int? change,
      }) =>
          CashResult._(s, command.signature, intent, allowed, received, change);
      if (response == CashResponse.prepare) {
        scope(r);
        if (r.length != 8 ||
            r['requestId'] != command.requestId ||
            r['channel'] != 'cash' ||
            !{
              'prepared',
              'pending',
              'unknown',
              'confirmed',
              'closed',
            }.contains(r['intentStatus'])) {
          throw const FormatException();
        }
        // Replayed preparation does not check current expiry or provide a final receipt.
        return result(CashState.needsLookup);
      }
      final state = response == CashResponse.confirm
          ? 'confirmed'
          : response == CashResponse.close
          ? 'closed'
          : r['state'];
      if (response == CashResponse.lookup &&
          r['requestId'] != command.requestId) {
        throw const FormatException();
      }
      if (state == 'not_observed') {
        if (response != CashResponse.lookup ||
            r.length != 2 ||
            command.intentRef != null) {
          throw const FormatException();
        }
        return result(CashState.notObserved);
      }
      if (state == 'prepared') {
        scope(r);
        if (response != CashResponse.lookup ||
            r.length != 9 ||
            !{'prepay', 'postpay'}.contains(r['paymentTiming']) ||
            r['canConfirmCash'] is! bool) {
          throw const FormatException();
        }
        return result(CashState.prepared, allowed: r['canConfirmCash'] as bool);
      }
      if (!{'confirmed', 'closed'}.contains(state)) {
        throw const FormatException();
      }
      if (response == CashResponse.lookup && r.length != 3) {
        throw const FormatException();
      }
      final receipt = response == CashResponse.lookup ? _map(r['receipt']) : r;
      scope(receipt);
      if (receipt['channel'] != 'cash') throw const FormatException();
      if (state == 'confirmed') {
        if (receipt.length != 11 ||
            receipt['confirmedBy'] != command.employeeRef ||
            receipt['confirmationStatus'] != 'confirmed' ||
            receipt['paymentRef'] != 'cash:$intent' ||
            command.receivedCents == null ||
            command.closeRequested ||
            receipt['receivedCents'] is! int ||
            receipt['receivedCents'] != command.receivedCents ||
            receipt['changeCents'] is! int ||
            receipt['changeCents'] !=
                command.receivedCents! - command.totalCents) {
          throw const FormatException();
        }
        return result(
          CashState.confirmed,
          received: receipt['receivedCents'] as int,
          change: receipt['changeCents'] as int,
        );
      }
      if (receipt.length != 10 ||
          receipt['requestId'] != command.requestId ||
          receipt['closedBy'] != command.employeeRef ||
          (command.receivedCents == null
              ? receipt['noCashCollectedConfirmed'] != true
              : receipt['cashReturnedConfirmed'] != true) ||
          receipt['closureStatus'] != 'closed' ||
          !command.closeRequested) {
        throw const FormatException();
      }
      return result(CashState.closed);
    } catch (_) {
      throw const CcsopFailure('CASH_RECEIPT_MISMATCH');
    }
  }
}
