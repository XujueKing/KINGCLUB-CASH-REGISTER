import 'dart:convert';
import 'dart:math';

import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';

bool _ref(Object? v) =>
    v is String && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(v);
bool _int(Object? v, int min, int max) => v is int && v >= min && v <= max;
Map<String, dynamic> _map(Object? v) {
  if (v is! Map<String, dynamic>) throw const FormatException();
  return v;
}

/// Original physical-return decision. Never a payment authorization or receipt.
class PendingItemReturn {
  PendingItemReturn._(
    this.base,
    this.employeeRef,
    this.deviceId,
    this.unitPriceCents,
    this.params,
  );
  final String base, employeeRef, deviceId;
  final int unitPriceCents;
  final Map<String, dynamic> params;
  String get requestId => params['requestId'] as String;
  String get orderRef => params['orderRef'] as String;
  String get productRef => params['productRef'] as String;
  String get storeRef => params['storeRef'] as String;
  String get signature => jsonEncode(encode());
  String get requestKey => jsonEncode([base, employeeRef, requestId]);
  String get lineKey => jsonEncode([base, storeRef, orderRef, productRef]);
  bool belongsTo(StaffSession identity) =>
      base == identity.base.toString() &&
      employeeRef == identity.employeeRef &&
      deviceId == identity.deviceId &&
      storeRef == identity.storeRef;
  Map<String, dynamic> encode() => {
    'base': base,
    'employeeRef': employeeRef,
    'deviceId': deviceId,
    'unitPriceCents': unitPriceCents,
    'params': params,
  };

  factory PendingItemReturn.prepare({
    required StaffSession identity,
    required Map<String, dynamic> fields,
    required int unitPriceCents,
    required DateTime now,
  }) {
    if (!identity.expiresAt.isAfter(now) ||
        !identity.permissions.contains('orders.create') ||
        !identity.permissions.contains('orders.serve') ||
        ((fields['returnedServedQuantity'] as int? ?? 0) > 0 &&
            !identity.permissions.contains('payment.refund'))) {
      throw const CcsopFailure('ITEM_RETURN_SCOPE_CHANGED');
    }
    final random = Random.secure(),
        bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
    return PendingItemReturn.decode({
      'base': identity.base.toString(),
      'employeeRef': identity.employeeRef,
      'deviceId': identity.deviceId,
      'unitPriceCents': unitPriceCents,
      'params': {...fields, 'storeRef': identity.storeRef, 'requestId': id},
    });
  }

  factory PendingItemReturn.decode(Object? raw) {
    try {
      final v = _map(raw), p = _map(v['params']);
      final uri = v['base'] is String
          ? Uri.tryParse(v['base'] as String)
          : null;
      if (v.length != 5 ||
          p.length != 13 ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          v['employeeRef'] is! String ||
          !RegExp(r'^E[0-9]{11}$').hasMatch(v['employeeRef'] as String) ||
          v['deviceId'] is! String ||
          !uuidPattern.hasMatch(v['deviceId'] as String) ||
          ![p['storeRef'], p['tableRef'], p['productRef']].every(_ref) ||
          p['sessionRef'] is! String ||
          !(RegExp(r'^H[0-9]{11}$').hasMatch(p['sessionRef']) ||
              uuidPattern.hasMatch(p['sessionRef'])) ||
          p['orderRef'] is! String ||
          !RegExp(r'^D[0-9]{11}$').hasMatch(p['orderRef']) ||
          p['requestId'] is! String ||
          !uuidPattern.hasMatch(p['requestId']) ||
          !_int(p['expectedQuantity'], 1, 1000) ||
          !_int(p['expectedServedQuantity'], 0, 1000) ||
          !_int(p['expectedServingEpoch'], 0, 999999) ||
          !_int(p['expectedTotalCents'], 1, 100000000) ||
          !_int(p['quantity'], 1, 1000) ||
          !_int(p['returnedServedQuantity'], 0, 1000) ||
          !_int(v['unitPriceCents'], 0, 100000000) ||
          p['physicalReturnConfirmed'] != true) {
        throw const FormatException();
      }
      final quantity = p['expectedQuantity'] as int,
          served = p['expectedServedQuantity'] as int,
          returned = p['quantity'] as int,
          returnedServed = p['returnedServedQuantity'] as int;
      if (served > quantity ||
          returned > quantity ||
          returnedServed > served ||
          returnedServed > returned ||
          served - returnedServed > quantity - returned ||
          quantity * (v['unitPriceCents'] as int) >
              (p['expectedTotalCents'] as int)) {
        throw const FormatException();
      }
      final normalized = <String, dynamic>{};
      for (final key in [
        'storeRef',
        'tableRef',
        'sessionRef',
        'orderRef',
        'productRef',
        'requestId',
        'expectedQuantity',
        'expectedServedQuantity',
        'expectedServingEpoch',
        'expectedTotalCents',
        'quantity',
        'returnedServedQuantity',
        'physicalReturnConfirmed',
      ]) {
        normalized[key] = p[key];
      }
      normalized['requestId'] = (p['requestId'] as String).toLowerCase();
      return PendingItemReturn._(
        uri.toString(),
        v['employeeRef'],
        v['deviceId'],
        v['unitPriceCents'],
        Map.unmodifiable(normalized),
      );
    } catch (_) {
      throw const CcsopFailure('ITEM_RETURN_COMMAND_INVALID');
    }
  }
}

class ItemReturnResult {
  ItemReturnResult._(this.confirmed, this.commandSignature);
  final bool confirmed;
  final String commandSignature;
  factory ItemReturnResult.parse(Object? raw, PendingItemReturn command) {
    try {
      final result = _map(_map(raw)['result']), p = command.params;
      if (result['requestId'] != command.requestId) {
        throw const FormatException();
      }
      if (result['state'] == 'not_observed' && result.length == 2) {
        return ItemReturnResult._(false, command.signature);
      }
      if (result.length != 21 ||
          p.entries.any(
            (e) =>
                result[e.key] != e.value ||
                (e.value is int && result[e.key] is! int),
          ) ||
          result['operation'] != 'return_cancel' ||
          result['operatedBy'] != command.employeeRef ||
          !_int(result['remainingQuantity'], 0, 1000) ||
          result['remainingQuantity'] !=
              p['expectedQuantity'] - p['quantity'] ||
          !_int(result['remainingServedQuantity'], 0, 1000) ||
          result['remainingServedQuantity'] !=
              p['expectedServedQuantity'] - p['returnedServedQuantity'] ||
          !_int(result['servingEpoch'], 1, 1000000) ||
          result['servingEpoch'] != p['expectedServingEpoch'] + 1 ||
          !_int(result['remainingTotalCents'], 0, 100000000) ||
          result['remainingTotalCents'] !=
              p['expectedTotalCents'] -
                  p['quantity'] * command.unitPriceCents ||
          !(result['remainingTotalCents'] == 0
                  ? const {'expired', 'waived'}
                  : const {'pending'})
              .contains(result['orderStatus'])) {
        throw const FormatException();
      }
      final stock = _map(result['stockReturn']);
      if (stock.length != 11 ||
          stock['version'] is! int ||
          stock['version'] != 1 ||
          !_int(stock['quantity'], 1, 1000) ||
          stock['returnRef'] != command.requestId ||
          stock['employeeRef'] != command.employeeRef ||
          stock['purpose'] != 'unpaid_cancel' ||
          stock['physicalReturnConfirmed'] != true ||
          [
            'storeRef',
            'orderRef',
            'productRef',
            'quantity',
          ].any((key) => stock[key] != p[key])) {
        throw const FormatException();
      }
      for (final key in ['allocations', 'movements']) {
        final list = stock[key];
        if (list is! List || list.isEmpty || list.length > 10000) {
          throw const FormatException();
        }
        var total = 0;
        for (final rawRow in list) {
          final row = _map(rawRow);
          if (!_ref(row['batchRef']) ||
              !_int(row['quantity'], 1, 1000) ||
              (row['costCents'] != null &&
                  (row['costCents'] is! String ||
                      !RegExp(r'^(0|[1-9][0-9]{0,17})$')
                          .hasMatch(row['costCents'])))) {
            throw const FormatException();
          }
          if (key == 'allocations') {
            if (row.length != 4 || !_ref(row['originalMovementRef'])) {
              throw const FormatException();
            }
          } else if (row.length != 6 ||
              !_ref(row['movementRef']) ||
              !_int(row['onHandBefore'], 0, 4294967295) ||
              !_int(row['onHandAfter'], 0, 4294967295) ||
              row['onHandAfter'] - row['onHandBefore'] != row['quantity']) {
            throw const FormatException();
          }
          total += row['quantity'] as int;
        }
        if (total != p['quantity']) throw const FormatException();
      }
      return ItemReturnResult._(true, command.signature);
    } catch (_) {
      throw const CcsopFailure('ITEM_RETURN_RESPONSE_INVALID');
    }
  }
}
