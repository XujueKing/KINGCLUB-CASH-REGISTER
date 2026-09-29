import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';

Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) throw const FormatException();
  return value;
}

String _text(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 256 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw const FormatException();
  }
  return value;
}

String _ref(Object? value) {
  final text = _text(value);
  if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(text)) {
    throw const FormatException();
  }
  return text;
}

int _int(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const FormatException();
  }
  return value;
}

String _choice(Object? value, Set<String> choices) {
  if (value is! String || !choices.contains(value)) {
    throw const FormatException();
  }
  return value;
}

String _date(Object? value) {
  final text = _text(value);
  final parsed = DateTime.tryParse(text);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text) ||
      parsed == null ||
      parsed.toIso8601String().substring(0, 10) != text) {
    throw const FormatException();
  }
  return text;
}

/// Display/preflight only. Neither admission nor permission to execute an opening.
class OpeningContext {
  OpeningContext._(Map<String, dynamic> value)
    : storeRef = _ref(value['storeRef']),
      tableId = _ref(value['tableId']),
      tableName = _text(value['tableName']),
      tableStatus = _choice(value['tableStatus'], {'active', 'disabled'}),
      paymentTiming = _choice(value['paymentTiming'], {'prepay', 'postpay'}),
      businessDate = _date(value['businessDate']),
      maximumSeats = _int(value['maximumSeats'], 1, 65535),
      minimumSeats =
          value['minimumSeats'] == null && value['tableStatus'] == 'disabled'
          ? null
          : _int(value['minimumSeats'], 1, 65535),
      ruleSource = _choice(value['ruleSource'], {
        'configured',
        'manual_default',
      }) {
    if (!value.containsKey('minimumSeats') ||
        (minimumSeats != null && minimumSeats! > maximumSeats) ||
        value['openingEnabled'] is! bool ||
        value['requiresStaffConfirmation'] != true ||
        value['automaticReservationCheck'] != false) {
      throw const FormatException();
    }
    openingEnabled = value['openingEnabled'] as bool;
    final snapshot = _map(value['rule']);
    if (_date(snapshot['businessDate']) != businessDate) {
      throw const FormatException();
    }
    revision = _int(snapshot['revision'], 0, 4294967295);
    final rule = _map(snapshot['rule']);
    mode = _choice(rule['mode'], {
      'manual',
      'minimum_people',
      'minimum_spend',
      'aa',
    });
    final allowed = {
      'mode',
      'reservationRequired',
      if (mode == 'minimum_people') 'minimumPeople',
      if (mode == 'minimum_spend') 'minimumSpendCents',
    };
    if (rule.keys.any((key) => !allowed.contains(key)) ||
        (rule.containsKey('reservationRequired') &&
            rule['reservationRequired'] is! bool)) {
      throw const FormatException();
    }
    reservationRequired = rule['reservationRequired'] == true;
    minimumPeople = mode == 'minimum_people'
        ? _int(rule['minimumPeople'], 1, 65535)
        : null;
    minimumSpendCents = mode == 'minimum_spend'
        ? _int(rule['minimumSpendCents'], 1, 2147483647)
        : null;
    if ((ruleSource == 'configured' && revision == 0) ||
        (ruleSource == 'manual_default' &&
            (revision != 0 || mode != 'manual' || rule.length != 1))) {
      throw const FormatException();
    }
    if (!value.containsKey('activeSession')) throw const FormatException();
    final active = value['activeSession'];
    activeSessionRef = active == null ? null : _ref(_map(active)['sessionRef']);
    activeSessionStatus = active == null
        ? null
        : _choice(_map(active)['status'], {'open', 'clearing'});
    final observed = _text(value['observedAt']);
    observedAt = DateTime.parse(observed);
    if (!observed.endsWith('Z') ||
        observedAt.toUtc().toIso8601String() != observed) {
      throw const FormatException();
    }
  }

  final String storeRef,
      tableId,
      tableName,
      tableStatus,
      paymentTiming,
      businessDate,
      ruleSource;
  final int maximumSeats;
  final int? minimumSeats;
  late final bool openingEnabled, reservationRequired;
  late final int revision;
  late final String mode;
  late final int? minimumPeople, minimumSpendCents;
  late final String? activeSessionRef, activeSessionStatus;
  late final DateTime observedAt;

  factory OpeningContext.parse(
    Object? raw, {
    required String storeRef,
    required String tableId,
  }) {
    try {
      final context = OpeningContext._(_map(_map(raw)['result']));
      if (context.storeRef != storeRef || context.tableId != tableId) {
        throw const FormatException();
      }
      return context;
    } catch (_) {
      throw const CcsopFailure('INVALID_OPENING_CONTEXT');
    }
  }
}

/// Original committed receipt, not evidence that its table session is still open.
class OpeningReceipt {
  OpeningReceipt._(Map<String, dynamic> value)
    : storeRef = _ref(value['storeRef']),
      tableId = _ref(value['tableId']),
      sessionRef = _ref(value['sessionRef']),
      businessDate = _date(value['businessDate']),
      paymentTiming = _choice(value['paymentTiming'], {'prepay', 'postpay'}) {
    if (!RegExp(r'^H[0-9]{11}$').hasMatch(sessionRef) &&
        !uuidPattern.hasMatch(sessionRef)) {
      throw const FormatException();
    }
    final members = value['memberRefs'];
    if (members is! List || members.length > 1000) {
      throw const FormatException();
    }
    memberRefs = List.unmodifiable(members.map(_ref));
    if (memberRefs.toSet().length != memberRefs.length) {
      throw const FormatException();
    }
  }
  final String storeRef, tableId, sessionRef, businessDate, paymentTiming;
  late final List<String> memberRefs;
}

enum OpeningLookupState { confirmed, notObserved, cancelled }

class OpeningLookup {
  OpeningLookup._(
    this.state,
    this.requestId,
    this.receipt,
    this.storeRef,
    this.tableId,
  );
  final OpeningLookupState state;
  final String requestId;
  final String storeRef, tableId;
  final OpeningReceipt? receipt;

  /// 1906 returns a receipt directly; associate it with the command we sent.
  factory OpeningLookup.fromSubmission(
    Object? raw, {
    required String storeRef,
    required String tableId,
    required String requestId,
  }) {
    try {
      return OpeningLookup.parse(
        {
          'result': {
            'state': 'confirmed',
            'requestId': requestId,
            'receipt': _map(raw)['result'],
          },
        },
        storeRef: storeRef,
        tableId: tableId,
        requestId: requestId,
      );
    } catch (_) {
      throw const CcsopFailure(
        'INVALID_OPENING_RECEIPT',
        deliveryUncertain: true,
      );
    }
  }

  factory OpeningLookup.parse(
    Object? raw, {
    required String storeRef,
    required String tableId,
    required String requestId,
  }) {
    try {
      final result = _map(_map(raw)['result']);
      if (!uuidPattern.hasMatch(requestId) ||
          result['requestId'] != requestId) {
        throw const FormatException();
      }
      _ref(storeRef);
      _ref(tableId);
      final state = _choice(result['state'], {
        'confirmed',
        'not_observed',
        'cancelled',
      });
      if (state != 'confirmed') {
        if (result.containsKey('receipt')) throw const FormatException();
        return OpeningLookup._(
          state == 'cancelled'
              ? OpeningLookupState.cancelled
              : OpeningLookupState.notObserved,
          requestId,
          null,
          storeRef,
          tableId,
        );
      }
      final receipt = OpeningReceipt._(_map(result['receipt']));
      if (receipt.storeRef != storeRef || receipt.tableId != tableId) {
        throw const FormatException();
      }
      return OpeningLookup._(
        OpeningLookupState.confirmed,
        requestId,
        receipt,
        storeRef,
        tableId,
      );
    } catch (_) {
      throw const CcsopFailure('INVALID_OPENING_RECEIPT');
    }
  }
}
