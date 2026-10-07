import 'dart:convert';

import '../network/ccsop_client.dart';
import '../network/ccsop_crypto.dart';

final uuidPattern = RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
);
final _reference = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
const staffPermissions = {
  'cashbook.review',
  'purchase.buy',
  'workbench.read',
  'orders.read',
  'table.open',
  'orders.create',
  'price.adjust',
  'price.waive',
  'orders.serve',
  'table.clear',
  'payment.cash',
  'payment.wechat',
  'payment.alipay',
  'payment.balance',
  'payment.refund',
  'voucher.meituan',
  'voucher.douyin',
  'together.admit',
  'shift.manage',
  'report.read',
};

String _text(Object? value, {int max = 128, RegExp? pattern}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      value.contains(RegExp(r'[\x00-\x1f]')) ||
      (pattern != null && !pattern.hasMatch(value))) {
    throw const FormatException('Invalid session field');
  }
  return value;
}

DateTime _time(Object? value) {
  if (value is! int || value <= 0 || value > 8640000000000000) {
    throw const FormatException('Invalid expiry');
  }
  return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
}

/// Validated server projection, not local authorization. Never print or put in ordinary preferences.
class StaffSession {
  StaffSession._({
    required this.base,
    required this.deviceId,
    required this.employeeRef,
    required this.displayName,
    required this.storeRef,
    required this.storeName,
    required this.sessionId,
    required this.apiKeyId,
    required this._apiKey,
    required this._refreshToken,
    required this.expiresAt,
    required this.refreshExpiresAt,
    required this.permissions,
  });
  final Uri base;
  final String deviceId,
      employeeRef,
      displayName,
      storeRef,
      sessionId,
      apiKeyId;
  final String? storeName;
  final String _apiKey, _refreshToken;
  final DateTime expiresAt, refreshExpiresAt;
  final Set<String> permissions;
  CcsopCredentials get credentials => CcsopCredentials(
    apiKeyId: apiKeyId,
    sessionId: sessionId,
    apiKey: _apiKey,
  );
  Map<String, dynamic> refreshRequest() => {
    'sessionId': sessionId,
    'deviceId': deviceId,
    'refreshToken': _refreshToken,
  };
  bool canRefresh(DateTime now) =>
      refreshExpiresAt.isAfter(now.add(const Duration(seconds: 1)));

  factory StaffSession.fromServer(
    Map<String, dynamic> value, {
    required String base,
    required String deviceId,
    String? expectedStore,
    DateTime? now,
    bool allowExpiredAccess = false,
  }) {
    try {
      final employee = jsonObject(value['employee']);
      final store = value['store'] != null
          ? jsonObject(value['store'])['storeRef']
          : value['storeRef'];
      final storeRef = _text(store, max: 64, pattern: _reference);
      if (expectedStore != null && storeRef != expectedStore) {
        throw const FormatException('Wrong store');
      }
      final expires = _time(value['expiresAtMs']),
          refreshExpires = _time(value['refreshExpiresAtMs']);
      final current = now ?? DateTime.now();
      if (!refreshExpires.isAfter(expires) ||
          !refreshExpires.isAfter(current) ||
          (!allowExpiredAccess && !expires.isAfter(current))) {
        throw const FormatException('Expired session');
      }
      final rawPermissions = value['permissions'];
      if (rawPermissions is! List ||
          rawPermissions.isEmpty ||
          rawPermissions.length > 32 ||
          rawPermissions.any(
            (p) => p is! String || !staffPermissions.contains(p),
          )) {
        throw const FormatException('Invalid permissions');
      }
      final permissions = rawPermissions.cast<String>().toSet();
      if (permissions.length != rawPermissions.length ||
          !permissions.contains('workbench.read')) {
        throw const FormatException('Missing workbench');
      }
      final secretPattern = RegExp(r'^[A-Za-z0-9_-]{43}$');
      return StaffSession._(
        base: serviceBase(base),
        deviceId: _text(deviceId, pattern: uuidPattern),
        employeeRef: _text(
          employee['employeeRef'],
          pattern: RegExp(r'^E[0-9]{11}$'),
        ),
        displayName: _text(employee['displayName'], max: 100),
        storeRef: storeRef,
        storeName:
            value['store'] is Map &&
                (value['store'] as Map)['storeName'] != null
            ? _text((value['store'] as Map)['storeName'], max: 128)
            : value['storeName'] == null
            ? null
            : _text(value['storeName'], max: 128),
        sessionId: _text(value['sessionId'], pattern: uuidPattern),
        apiKeyId: _text(value['apiKeyId'], pattern: uuidPattern),
        apiKey: _text(value['apiKey'], pattern: secretPattern),
        refreshToken: _text(value['refreshToken'], pattern: secretPattern),
        expiresAt: expires,
        refreshExpiresAt: refreshExpires,
        permissions: Set.unmodifiable(permissions),
      );
    } catch (_) {
      throw const CcsopFailure('INVALID_STAFF_SESSION');
    }
  }

  /// Only SessionVault may persist this encoded value via encrypted storage.
  String encodeForSecureStorage() => jsonEncode({
    'version': 1,
    'base': base.toString(),
    'deviceId': deviceId,
    'storeRef': storeRef,
    'value': {
      'employee': {'employeeRef': employeeRef, 'displayName': displayName},
      'storeRef': storeRef,
      if (storeName != null) 'storeName': storeName,
      'sessionId': sessionId,
      'apiKeyId': apiKeyId,
      'apiKey': _apiKey,
      'refreshToken': _refreshToken,
      'expiresAtMs': expiresAt.millisecondsSinceEpoch,
      'refreshExpiresAtMs': refreshExpiresAt.millisecondsSinceEpoch,
      'permissions': permissions.toList(),
    },
  });

  factory StaffSession.fromSecureStorage(String encoded, {DateTime? now}) {
    try {
      if (encoded.length > 16384) {
        throw const FormatException('Session too large');
      }
      final data = jsonObject(jsonDecode(encoded));
      if (data['version'] != 1) {
        throw const FormatException('Unknown storage version');
      }
      return StaffSession.fromServer(
        jsonObject(data['value']),
        base: data['base'] as String,
        deviceId: data['deviceId'] as String,
        expectedStore: data['storeRef'] as String,
        now: now,
        allowExpiredAccess: true,
      );
    } catch (_) {
      throw const CcsopFailure('INVALID_STAFF_SESSION');
    }
  }
}
