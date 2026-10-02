import '../network/ccsop_client.dart';

Map<String, dynamic> _object(Object? value) {
  if (value is! Map<String, dynamic>) throw const FormatException();
  return value;
}

String _text(Object? value, {int max = 256}) {
  if (value is! String ||
      value.isEmpty ||
      value.length > max ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw const FormatException();
  }
  return value;
}

String _ref(Object? value) {
  final result = _text(value, max: 64);
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(result)) {
    throw const FormatException();
  }
  return result;
}

int _number(Object? value) {
  if (value is! int || value < 0 || value > 9007199254740991) {
    throw const FormatException();
  }
  return value;
}

String _date(Object? value) {
  final result = _text(value, max: 10);
  final date = DateTime.tryParse(result);
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(result) ||
      date == null ||
      date.toIso8601String().substring(0, 10) != result) {
    throw const FormatException();
  }
  return result;
}

/// Cents remain integers; no binary floating-point rounding of transaction totals.
String formatCents(int cents) =>
    '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';

class TableSessionSnapshot {
  TableSessionSnapshot(Map<String, dynamic> value)
    : reference = _ref(value['sessionRef']),
      status = _text(value['status']),
      paymentTiming = _text(value['paymentTiming']),
      temporaryHold = value['temporaryHold'] == true,
      businessDate = _date(value['businessDate']),
      partySize = value['partySize'] == null
          ? null
          : _number(value['partySize']),
      partyRevision = _number(value['partyRevision']),
      openedAt = value['openedAt'] == null
          ? null
          : DateTime.parse(_text(value['openedAt'])),
      elapsedMinutes = _number(value['elapsedMinutes']),
      paidCents = _number(value['paidCents']),
      pendingCents = _number(value['pendingCents']),
      paidOrders = _number(value['paidOrders']),
      refundedCents = value.containsKey('refundedCents')
          ? _number(value['refundedCents'])
          : 0,
      refundedOrders = value.containsKey('refundedOrders')
          ? _number(value['refundedOrders'])
          : 0,
      pendingOrders = _number(value['pendingOrders']) {
    if ((value.containsKey('temporaryHold') &&
            value['temporaryHold'] is! bool) ||
        value.containsKey('refundedCents') !=
            value.containsKey('refundedOrders') ||
        (refundedOrders == 0
            ? refundedCents != 0
            : refundedCents < refundedOrders) ||
        !value.containsKey('partySize') ||
        !{'open', 'clearing'}.contains(status) ||
        !{'prepay', 'postpay'}.contains(paymentTiming)) {
      throw const FormatException();
    }
  }
  final String reference, status, paymentTiming, businessDate;
  final bool temporaryHold;
  final DateTime? openedAt;
  final int? partySize;
  final int partyRevision,
      elapsedMinutes,
      paidCents,
      pendingCents,
      paidOrders,
      refundedCents,
      refundedOrders,
      pendingOrders;
}

class LiveTable {
  LiveTable(Map<String, dynamic> value)
    : reference = _ref(value['tableRef']),
      name = _text(value['tableName']),
      tableMode = value['tableMode'] == null ? null : _text(value['tableMode']),
      status = _text(value['tableStatus']),
      minimumSeats = value['minimumSeats'] == null
          ? null
          : _number(value['minimumSeats']),
      maximumSeats = _number(value['maximumSeats']),
      session = value['session'] == null
          ? null
          : TableSessionSnapshot(_object(value['session'])) {
    if ((tableMode != null &&
            !{
              'manual',
              'aa',
              'minimum_spend',
              'minimum_people',
            }.contains(tableMode)) ||
        !value.containsKey('session') ||
        !value.containsKey('minimumSeats') ||
        (minimumSeats != null && minimumSeats! > maximumSeats) ||
        !{'active', 'disabled'}.contains(status)) {
      throw const FormatException();
    }
  }
  final String reference, name, status;
  final String? tableMode;
  final int? minimumSeats;
  final int maximumSeats;
  final TableSessionSnapshot? session;
  String get stateLabel => status != 'active'
      ? 'tableDisabled'
      : session == null
      ? 'free'
      : session!.status == 'clearing'
      ? 'cleaning'
      : session!.temporaryHold
      ? 'tableTemporaryHold'
      : session!.pendingCents > 0
      ? 'tablePaymentPending'
      : 'tableOpen';
}

/// One server transaction/page, not a claim of an atomic all-store snapshot.
class TableSnapshot {
  TableSnapshot._(
    this.storeName,
    this.currency,
    this.businessDate,
    this.observedAt,
    this.tables,
    this.nextAfterTable,
  );
  final String storeName, currency, businessDate;
  final DateTime observedAt;
  final List<LiveTable> tables;
  final String? nextAfterTable;

  factory TableSnapshot.parse(
    Object? raw, {
    required String storeRef,
    required String employeeRef,
    String? afterTable,
  }) {
    try {
      final result = _object(_object(raw)['result']);
      final store = _object(result['store']);
      final operator = _object(result['operator']);
      if (store['storeRef'] != storeRef ||
          operator['employeeRef'] != employeeRef) {
        throw const FormatException();
      }
      final permissions = operator['permissions'];
      if (permissions is! List || !permissions.contains('workbench.read')) {
        throw const FormatException();
      }
      final currency = _text(store['currency'], max: 3);
      if (!RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
        throw const FormatException();
      }
      final observed = _text(result['observedAt']);
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}T.*Z$').hasMatch(observed)) {
        throw const FormatException();
      }
      final observedAt = DateTime.parse(observed);
      if (observedAt.toUtc().toIso8601String() != observed ||
          !result.containsKey('nextAfterTable')) {
        throw const FormatException();
      }
      final rawTables = result['tables'];
      if (rawTables is! List || rawTables.length > 100) {
        throw const FormatException();
      }
      final tables = rawTables
          .map((value) => LiveTable(_object(value)))
          .toList();
      if (tables.map((table) => table.reference).toSet().length !=
              tables.length ||
          tables.any((table) => table.reference == afterTable)) {
        throw const FormatException();
      }
      final next = result['nextAfterTable'] == null
          ? null
          : _ref(result['nextAfterTable']);
      if (next != null &&
          (tables.length != 100 ||
              next != tables.last.reference ||
              next == afterTable)) {
        throw const FormatException();
      }
      return TableSnapshot._(
        _text(store['storeName']),
        currency,
        _date(store['businessDate']),
        observedAt,
        List.unmodifiable(tables),
        next,
      );
    } catch (_) {
      throw const CcsopFailure('INVALID_WORKBENCH_SNAPSHOT');
    }
  }
}
