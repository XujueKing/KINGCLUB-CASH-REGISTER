import 'dart:convert';
import 'dart:math';

import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import 'member_identity.dart';
import 'order_context_snapshot.dart';

bool _ref(Object? value) =>
    value is String && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(value);
bool _label(Object? value) =>
    value is String &&
    value.trim().isNotEmpty &&
    value.length <= 256 &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

/// Original recovery scope. The QR secret is deliberately never part of this object.
class PendingSeating {
  PendingSeating._(
    this.base,
    this.employeeRef,
    this.deviceId,
    this.tableName,
    this.memberName,
    this.params,
  );
  final String base, employeeRef, deviceId, tableName;
  final String? memberName;
  final Map<String, dynamic> params;
  String get storeRef => params['storeRef'] as String;
  String get tableRef => params['tableRef'] as String;
  String get sessionRef => params['sessionRef'] as String;
  String get requestId => params['requestId'] as String;
  String get memberRef => params['expectedMemberRef'] as String;
  Map<String, dynamic> get lookup => Map.unmodifiable({
    for (final key in ['storeRef', 'tableRef', 'sessionRef', 'requestId'])
      key: params[key],
  });
  bool belongsTo(StaffSession session) =>
      base == session.base.toString() &&
      employeeRef == session.employeeRef &&
      deviceId == session.deviceId &&
      storeRef == session.storeRef;
  Map<String, dynamic> encode() => {
    'base': base,
    'employeeRef': employeeRef,
    'deviceId': deviceId,
    'tableName': tableName,
    'memberName': memberName,
    'params': params,
  };
  String get signature => jsonEncode(encode());
  String get requestKey => jsonEncode([base, employeeRef, requestId]);
  String get memberKey => jsonEncode([base, storeRef, memberRef]);

  factory PendingSeating.prepare({
    required StaffSession session,
    required OrderContextSnapshot context,
    required MemberIdentity member,
    required DateTime now,
    required bool arrivalConfirmed,
    required bool reservationChecked,
  }) {
    if (!session.expiresAt.isAfter(now) ||
        context.storeRef != session.storeRef ||
        !session.permissions.contains('orders.create') ||
        !session.permissions.contains('table.open') ||
        !arrivalConfirmed ||
        !reservationChecked) {
      throw const CcsopFailure('SEATING_CONFIRMATION_REQUIRED');
    }
    final random = Random.secure(),
        bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    final request =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return PendingSeating.decode({
      'base': session.base.toString(),
      'employeeRef': session.employeeRef,
      'deviceId': session.deviceId,
      'tableName': context.tableName,
      'memberName': member.nickname,
      'params': {
        'storeRef': session.storeRef,
        'tableRef': context.tableRef,
        'sessionRef': context.sessionRef,
        'requestId': request,
        'expectedMemberRef': member.memberRef,
      },
    });
  }
  factory PendingSeating.decode(Object? raw) {
    try {
      if (raw is! Map<String, dynamic> ||
          raw.length != 6 ||
          raw['params'] is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final params = raw['params'] as Map<String, dynamic>;
      final uri = raw['base'] is String
          ? Uri.tryParse(raw['base'] as String)
          : null;
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
          !_label(raw['tableName']) ||
          !raw.containsKey('memberName') ||
          (raw['memberName'] != null && !_label(raw['memberName'])) ||
          params.length != 5 ||
          ![
            'storeRef',
            'tableRef',
            'expectedMemberRef',
          ].every((key) => _ref(params[key])) ||
          params['sessionRef'] is! String ||
          !(RegExp(r'^H[0-9]{11}$').hasMatch(params['sessionRef'] as String) ||
              uuidPattern.hasMatch(params['sessionRef'] as String)) ||
          params['requestId'] is! String ||
          !uuidPattern.hasMatch(params['requestId'] as String)) {
        throw const FormatException();
      }
      return PendingSeating._(
        uri.toString(),
        raw['employeeRef'] as String,
        raw['deviceId'] as String,
        raw['tableName'] as String,
        raw['memberName'] as String?,
        Map.unmodifiable({
          for (final key in [
            'storeRef',
            'tableRef',
            'sessionRef',
            'requestId',
            'expectedMemberRef',
          ])
            key: params[key],
        }),
      );
    } catch (_) {
      throw const CcsopFailure('SEATING_COMMAND_INVALID');
    }
  }
}

class SeatingResult {
  SeatingResult._(this.state, this.commandSignature);
  final String state, commandSignature;
  bool get confirmed => state == 'confirmed';
  bool get terminal => state == 'confirmed' || state == 'cancelled';
  factory SeatingResult.parse(Object? raw, PendingSeating command) {
    try {
      if (raw is! Map<String, dynamic> ||
          raw['result'] is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final result = raw['result'] as Map<String, dynamic>;
      if (result.length != 2) throw const FormatException();
      if (['not_observed', 'cancelled'].contains(result['state']) &&
          result['requestId'] == command.requestId) {
        return SeatingResult._(result['state'] as String, command.signature);
      }
      if (result['state'] != 'confirmed' ||
          result['receipt'] is! Map<String, dynamic>) {
        throw const FormatException();
      }
      final receipt = result['receipt'] as Map<String, dynamic>;
      if (receipt.length != 8 ||
          command.lookup.entries.any((e) => receipt[e.key] != e.value) ||
          receipt['memberRef'] != command.memberRef ||
          receipt['seatedBy'] != command.employeeRef ||
          receipt['alreadySeated'] is! bool ||
          receipt['seatingStatus'] != 'seated') {
        throw const FormatException();
      }
      return SeatingResult._('confirmed', command.signature);
    } catch (_) {
      throw const CcsopFailure('SEATING_RESPONSE_INVALID');
    }
  }
}
