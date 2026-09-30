import 'dart:convert';
import 'dart:math';

import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import 'balance_refund_context.dart';

/// Immutable original request. Contains neither a payment code nor session secrets.
class PendingBalanceRefund {
  PendingBalanceRefund._(
    this.base,
    this.employeeRef,
    this.deviceId,
    this.params,
  );
  final String base, employeeRef, deviceId;
  final Map<String, dynamic> params;
  String get storeRef => params['storeRef'] as String;
  String get orderRef => params['orderRef'] as String;
  String get refundRef => params['refundRef'] as String;
  String get signature => jsonEncode(encode());
  String get requestKey => jsonEncode([base, refundRef]);
  String get orderKey => jsonEncode([base, storeRef, orderRef]);
  bool belongsTo(StaffSession staff) =>
      base == staff.base.toString() &&
      employeeRef == staff.employeeRef &&
      deviceId == staff.deviceId &&
      storeRef == staff.storeRef;
  Map<String, dynamic> encode() => {
    'base': base,
    'employeeRef': employeeRef,
    'deviceId': deviceId,
    'params': params,
  };

  factory PendingBalanceRefund.prepare({
    required StaffSession identity,
    required BalanceRefundContext context,
    required DateTime now,
    required bool confirmed,
    required String reason,
    required List<Map<String, dynamic>> dispositions,
  }) {
    if (!confirmed ||
        context.alreadyRefunded ||
        context.storeRef != identity.storeRef ||
        !identity.expiresAt.isAfter(now) ||
        !identity.permissions.contains('payment.refund')) {
      throw const CcsopFailure('BALANCE_REFUND_CONFIRMATION_REQUIRED');
    }
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    final command = PendingBalanceRefund.decode({
      'base': identity.base.toString(),
      'employeeRef': identity.employeeRef,
      'deviceId': identity.deviceId,
      'params': {
        'storeRef': context.storeRef,
        'orderRef': context.orderRef,
        'originalIntentRef': context.originalIntentRef,
        'refundRef': id,
        'expectedTotalCents': context.totalCents,
        'accountType': context.accountType,
        'reason': reason,
        'dispositions': dispositions,
      },
    });
    final original = {
      for (final source in context.sources)
        source.originalMovementRef: source.issuedQuantity,
    };
    final choices = command.params['dispositions'] as List;
    if (choices.length != original.length ||
        choices.any(
          (choice) =>
              !original.containsKey(choice['originalMovementRef']) ||
              (choice['returnQuantity'] as int) >
                  original[choice['originalMovementRef']]!,
        )) {
      throw const CcsopFailure('BALANCE_REFUND_DISPOSITION_INVALID');
    }
    return command;
  }

  factory PendingBalanceRefund.decode(Object? raw) {
    try {
      final envelope = _object(raw, {
        'base',
        'employeeRef',
        'deviceId',
        'params',
      });
      final base = envelope['base'];
      final uri = base is String ? Uri.tryParse(base) : null;
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const FormatException();
      }
      final employee = _match(envelope['employeeRef'], r'^E[0-9]{11}$');
      final device = _uuid(envelope['deviceId']);
      final p = _object(envelope['params'], {
        'storeRef',
        'orderRef',
        'originalIntentRef',
        'refundRef',
        'expectedTotalCents',
        'accountType',
        'reason',
        'dispositions',
      });
      final original = _uuid(p['originalIntentRef']),
          refund = _uuid(p['refundRef']);
      if (original == refund ||
          !{'platform_cash', 'store_balance'}.contains(p['accountType'])) {
        throw const FormatException();
      }
      final rawChoices = p['dispositions'];
      if (rawChoices is! List ||
          rawChoices.isEmpty ||
          rawChoices.length > 50000) {
        throw const FormatException();
      }
      final refs = <String>{};
      final choices =
          rawChoices.map((raw) {
            final d = _object(raw, {
              'originalMovementRef',
              'returnQuantity',
              'physicalReturnConfirmed',
              'reason',
            });
            final movement = _match(d['originalMovementRef'], r'^M[0-9]{11}$');
            final quantity = _integer(d['returnQuantity'], 0, 1000);
            if (!refs.add(movement) ||
                d['physicalReturnConfirmed'] is! bool ||
                (quantity > 0 && d['physicalReturnConfirmed'] != true)) {
              throw const FormatException();
            }
            return Map<String, dynamic>.unmodifiable({
              'originalMovementRef': movement,
              'returnQuantity': quantity,
              'physicalReturnConfirmed': d['physicalReturnConfirmed'],
              'reason': _reason(d['reason']),
            });
          }).toList()..sort(
            (a, b) => (a['originalMovementRef'] as String).compareTo(
              b['originalMovementRef'] as String,
            ),
          );
      return PendingBalanceRefund._(
        uri.toString(),
        employee,
        device,
        Map.unmodifiable({
          'storeRef': _match(p['storeRef'], r'^[A-Za-z0-9_-]{1,64}$'),
          'orderRef': _match(p['orderRef'], r'^D[0-9]{11}$'),
          'originalIntentRef': original,
          'refundRef': refund,
          'expectedTotalCents': _integer(p['expectedTotalCents'], 1, 100000000),
          'accountType': p['accountType'],
          'reason': _reason(p['reason']),
          'dispositions': List.unmodifiable(choices),
        }),
      );
    } catch (_) {
      throw const CcsopFailure('BALANCE_REFUND_COMMAND_INVALID');
    }
  }
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !value.keys.every(keys.contains)) {
    throw const FormatException();
  }
  return value;
}

String _match(Object? value, String pattern) {
  if (value is! String || !RegExp(pattern).hasMatch(value)) {
    throw const FormatException();
  }
  return value;
}

String _uuid(Object? value) {
  if (value is! String || !uuidPattern.hasMatch(value)) {
    throw const FormatException();
  }
  return value.toLowerCase();
}

int _integer(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const FormatException();
  }
  return value;
}

String _reason(Object? value) {
  if (value is! String || value.trim().isEmpty || value.trim().length > 500) {
    throw const FormatException();
  }
  return value.trim();
}
