import 'dart:convert';
import 'dart:math';

import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';

bool _ref(Object? v) =>
    v is String && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(v);
bool _count(Object? v, int max) => v is int && v >= 0 && v <= max;

/// A confirmed employee decision, not proof that the table was closed.
class PendingTableClear {
  PendingTableClear._(this.base, this.employeeRef, this.deviceId, this.params);
  final String base, employeeRef, deviceId;
  final Map<String, dynamic> params;
  String get storeRef => params['storeRef'] as String;
  String get tableRef => params['tableRef'] as String;
  String get sessionRef => params['sessionRef'] as String;
  String get requestId => params['requestId'] as String;
  Map<String, dynamic> get lookup => Map.unmodifiable({
    'storeRef': storeRef,
    'tableRef': tableRef,
    'sessionRef': sessionRef,
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
    'params': params,
  };
  String get signature => jsonEncode(encode());
  String get requestKey => jsonEncode([base, employeeRef, requestId]);
  String get sessionKey => jsonEncode([base, storeRef, sessionRef]);

  factory PendingTableClear.prepare({
    required StaffSession identity,
    required String tableRef,
    required String sessionRef,
    required DateTime now,
    required bool confirmed,
  }) {
    if (!confirmed) {
      throw const CcsopFailure('TABLE_CLEAR_CONFIRMATION_REQUIRED');
    }
    if (!identity.expiresAt.isAfter(now) ||
        !identity.permissions.contains('table.clear')) {
      throw const CcsopFailure('TABLE_CLEAR_SCOPE_CHANGED');
    }
    final random = Random.secure(),
        bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return PendingTableClear.decode({
      'base': identity.base.toString(),
      'employeeRef': identity.employeeRef,
      'deviceId': identity.deviceId,
      'params': {
        'storeRef': identity.storeRef,
        'tableRef': tableRef,
        'sessionRef': sessionRef,
        'requestId': id,
        'clearConfirmed': true,
      },
    });
  }
  factory PendingTableClear.decode(Object? raw) {
    try {
      if (raw is! Map<String, dynamic> || raw.length != 4) {
        throw const FormatException();
      }
      final params = raw['params'], base = raw['base'];
      final uri = base is String ? Uri.tryParse(base) : null;
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          raw['employeeRef'] is! String ||
          !RegExp(r'^E[0-9]{11}$').hasMatch(raw['employeeRef'] as String) ||
          raw['deviceId'] is! String ||
          !uuidPattern.hasMatch(raw['deviceId'] as String) ||
          params is! Map<String, dynamic> ||
          params.length != 5 ||
          !_ref(params['storeRef']) ||
          !_ref(params['tableRef']) ||
          params['sessionRef'] is! String ||
          !(uuidPattern.hasMatch(params['sessionRef'] as String) ||
              RegExp(r'^H[0-9]{11}$')
                  .hasMatch(params['sessionRef'] as String)) ||
          params['requestId'] is! String ||
          !uuidPattern.hasMatch(params['requestId'] as String) ||
          params['clearConfirmed'] != true) {
        throw const FormatException();
      }
      return PendingTableClear._(
        uri.toString(),
        raw['employeeRef'] as String,
        raw['deviceId'] as String,
        Map.unmodifiable({
          'storeRef': params['storeRef'],
          'tableRef': params['tableRef'],
          'sessionRef': params['sessionRef'],
          'requestId': params['requestId'],
          'clearConfirmed': true,
        }),
      );
    } catch (_) {
      throw const CcsopFailure('TABLE_CLEAR_COMMAND_INVALID');
    }
  }
}

class TableClearResult {
  TableClearResult._(this.confirmed, this.commandSignature, this.receipt);
  final bool confirmed;
  final String commandSignature;

  /// Historical original receipt only; never infer the current table/session from this.
  final Map<String, dynamic>? receipt;
  factory TableClearResult.parse(Object? raw, PendingTableClear command) {
    try {
      if (raw is! Map<String, dynamic>) throw const FormatException();
      final value = raw['result'];
      if (value is! Map<String, dynamic> ||
          value['requestId'] != command.requestId) {
        throw const FormatException();
      }
      if (value['state'] == 'not_observed' && value.length == 2) {
        return TableClearResult._(false, command.signature, null);
      }
      final receipt = value['receipt'];
      if (value['state'] != 'confirmed' ||
          value.length != 3 ||
          receipt is! Map<String, dynamic> ||
          receipt.length !=
              (receipt.containsKey('refundedOrderCount') ? 12 : 11) ||
          (receipt.containsKey('refundedOrderCount') &&
              (!_count(receipt['refundedOrderCount'], 1000) ||
                  receipt['refundedOrderCount'] == 0)) ||
          command.lookup.entries.any((e) => receipt[e.key] != e.value) ||
          receipt['clearedBy'] != command.employeeRef ||
          receipt['closureStatus'] != 'closed' ||
          !_count(receipt['paidOrderCount'], 1000) ||
          !_count(receipt['expiredOrderCount'], 1000) ||
          !_count(receipt['settledCents'], 100000000000) ||
          !_count(receipt['departedSeatCount'], 10000)) {
        throw const FormatException();
      }
      final paid = receipt['paidOrderCount'] as int,
          expired = receipt['expiredOrderCount'] as int,
          settled = receipt['settledCents'] as int;
      final refunded = receipt['refundedOrderCount'] as int? ?? 0;
      if (paid + expired + refunded > 1000 ||
          (paid == 0
              ? settled != 0
              : settled < paid || settled > paid * 100000000)) {
        throw const FormatException();
      }
      final stamp = receipt['closedAt'];
      if (stamp is! String ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')
              .hasMatch(stamp) ||
          DateTime.tryParse(stamp)?.toUtc().toIso8601String() != stamp) {
        throw const FormatException();
      }
      return TableClearResult._(
        true,
        command.signature,
        Map.unmodifiable(receipt),
      );
    } catch (_) {
      throw const CcsopFailure('TABLE_CLEAR_RESPONSE_INVALID');
    }
  }
}
