import 'dart:convert';
import 'dart:math';

import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';

Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) throw const FormatException();
  return value;
}

bool _ref(Object? value) =>
    value is String && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(value);
bool _count(Object? value, int min, int max) =>
    value is int && value >= min && value <= max;
bool _business(Object? value, String prefix) =>
    value is String &&
    (RegExp('^$prefix[0-9]{11}\$').hasMatch(value) ||
        uuidPattern.hasMatch(value));

/// A physical-delivery decision awaiting server confirmation, not a fulfillment receipt.
class PendingServing {
  PendingServing._(
    this.base,
    this.employeeRef,
    this.deviceId,
    this.quantity,
    this.params,
  );
  final String base, employeeRef, deviceId;
  final int quantity;
  final Map<String, dynamic> params;
  String get storeRef => params['storeRef'] as String;
  String get tableRef => params['tableRef'] as String;
  String get sessionRef => params['sessionRef'] as String;
  String get orderRef => params['orderRef'] as String;
  String get productRef => params['productRef'] as String;
  String get requestId => params['requestId'] as String;
  int get before => params['expectedServedQuantity'] as int;
  int get after => params['targetServedQuantity'] as int;
  Map<String, dynamic> get lookup => Map.unmodifiable({
    'storeRef': storeRef,
    'tableRef': tableRef,
    'sessionRef': sessionRef,
    'orderRef': orderRef,
    'productRef': productRef,
    'requestId': requestId,
  });
  bool belongsTo(StaffSession identity) =>
      base == identity.base.toString() &&
      employeeRef == identity.employeeRef &&
      deviceId == identity.deviceId &&
      storeRef == identity.storeRef;
  Map<String, dynamic> encode() => {
    'base': base,
    'employeeRef': employeeRef,
    'deviceId': deviceId,
    'quantity': quantity,
    'params': params,
  };
  String get signature => jsonEncode(encode());
  String get requestKey => jsonEncode([base, employeeRef, requestId]);
  String get lineKey => jsonEncode([base, storeRef, orderRef, productRef]);

  factory PendingServing.prepare({
    required StaffSession identity,
    required String tableRef,
    required String sessionRef,
    required String orderRef,
    required String productRef,
    required int quantity,
    required int expectedServedQuantity,
    required int targetServedQuantity,
    required DateTime now,
    required bool confirmed,
  }) {
    if (!confirmed) throw const CcsopFailure('SERVING_CONFIRMATION_REQUIRED');
    if (!identity.expiresAt.isAfter(now) ||
        !identity.permissions.contains('orders.serve')) {
      throw const CcsopFailure('SERVING_SCOPE_CHANGED');
    }
    final random = Random.secure(),
        bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return PendingServing.decode({
      'base': identity.base.toString(),
      'employeeRef': identity.employeeRef,
      'deviceId': identity.deviceId,
      'quantity': quantity,
      'params': {
        'storeRef': identity.storeRef,
        'tableRef': tableRef,
        'sessionRef': sessionRef,
        'orderRef': orderRef,
        'productRef': productRef,
        'requestId': id,
        'expectedServedQuantity': expectedServedQuantity,
        'targetServedQuantity': targetServedQuantity,
      },
    });
  }
  factory PendingServing.decode(Object? raw) {
    try {
      final value = _map(raw), params = _map(value['params']);
      final uri = value['base'] is String
          ? Uri.tryParse(value['base'] as String)
          : null;
      if (value.length != 5 ||
          params.length != 8 ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          value['employeeRef'] is! String ||
          !RegExp(r'^E[0-9]{11}$').hasMatch(value['employeeRef'] as String) ||
          value['deviceId'] is! String ||
          !uuidPattern.hasMatch(value['deviceId'] as String) ||
          ![
            params['storeRef'],
            params['tableRef'],
            params['productRef'],
          ].every(_ref) ||
          !_business(params['sessionRef'], 'H') ||
          !_business(params['orderRef'], 'D') ||
          params['requestId'] is! String ||
          !uuidPattern.hasMatch(params['requestId'] as String) ||
          !_count(value['quantity'], 1, 1000) ||
          !_count(params['expectedServedQuantity'], 0, 999) ||
          !_count(params['targetServedQuantity'], 1, 1000)) {
        throw const FormatException();
      }
      final before = params['expectedServedQuantity'] as int,
          after = params['targetServedQuantity'] as int,
          quantity = value['quantity'] as int;
      if (after <= before || after > quantity) throw const FormatException();
      return PendingServing._(
        uri.toString(),
        value['employeeRef'] as String,
        value['deviceId'] as String,
        quantity,
        Map.unmodifiable({
          'storeRef': params['storeRef'],
          'tableRef': params['tableRef'],
          'sessionRef': params['sessionRef'],
          'orderRef': params['orderRef'],
          'productRef': params['productRef'],
          'requestId': params['requestId'],
          'expectedServedQuantity': before,
          'targetServedQuantity': after,
        }),
      );
    } catch (_) {
      throw const CcsopFailure('SERVING_COMMAND_INVALID');
    }
  }
}

class ServingResult {
  ServingResult._(this.confirmed, this.commandSignature);
  final bool confirmed;
  final String commandSignature;
  factory ServingResult.parse(Object? raw, PendingServing command) {
    try {
      final value = _map(_map(raw)['result']);
      if (value['requestId'] != command.requestId) {
        throw const FormatException();
      }
      if (value['state'] == 'not_observed' && value.length == 2) {
        return ServingResult._(false, command.signature);
      }
      if (value['state'] != 'confirmed' || value.length != 3) {
        throw const FormatException();
      }
      final receipt = _map(value['receipt']);
      if (receipt.length != 12 ||
          command.lookup.entries.any((e) => receipt[e.key] != e.value) ||
          receipt['servedBy'] != command.employeeRef ||
          receipt['servedBefore'] is! int ||
          receipt['servedAfter'] is! int ||
          receipt['deliveredQuantity'] is! int ||
          receipt['remainingQuantity'] is! int ||
          receipt['complete'] is! bool ||
          receipt['servedBefore'] != command.before ||
          receipt['servedAfter'] != command.after ||
          receipt['deliveredQuantity'] != command.after - command.before ||
          receipt['remainingQuantity'] != command.quantity - command.after ||
          receipt['complete'] != (command.after == command.quantity)) {
        throw const FormatException();
      }
      return ServingResult._(true, command.signature);
    } catch (_) {
      throw const CcsopFailure('SERVING_RESPONSE_INVALID');
    }
  }
}
