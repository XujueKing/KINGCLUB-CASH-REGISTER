import '../network/ccsop_client.dart';

Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) throw const FormatException();
  return value;
}

String _text(Object? value, int max) {
  if (value is! String ||
      value.trim().isEmpty ||
      value.length > max ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw const FormatException();
  }
  return value;
}

String _ref(Object? value) {
  final text = _text(value, 64);
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(text)) {
    throw const FormatException();
  }
  return text;
}

class SeatedOrderMember {
  SeatedOrderMember._(this.reference, this.nickname, this.eligible);
  final String reference;
  final String? nickname;
  final bool eligible;
}

/// An observation of seat eligibility, never a payer mandate or final order authorization.
class OrderContextSnapshot {
  OrderContextSnapshot._(
    this.storeRef,
    this.tableRef,
    this.sessionRef,
    this.tableName,
    this.currency,
    this.paymentTiming,
    this.partySize,
    this.members,
    this.nextAfterMember,
    this.observedAt,
    this.tableOrderAllowed,
  );
  final String storeRef,
      tableRef,
      sessionRef,
      tableName,
      currency,
      paymentTiming;
  final int? partySize;
  final List<SeatedOrderMember> members;
  final String? nextAfterMember;
  final DateTime observedAt;
  final bool tableOrderAllowed;

  factory OrderContextSnapshot.parse(
    Object? raw, {
    required String storeRef,
    required String tableRef,
    required String sessionRef,
    String? afterMember,
  }) {
    try {
      final value = _map(_map(raw)['result']),
          session = _map(_map(_map(raw)['result'])['session']);
      if (_ref(value['storeRef']) != storeRef ||
          _ref(value['tableRef']) != tableRef ||
          _ref(session['sessionRef']) != sessionRef ||
          session['status'] != 'open' ||
          !{'prepay', 'postpay'}.contains(session['paymentTiming'])) {
        throw const FormatException();
      }
      if (!RegExp(
        r'^(H[0-9]{11}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$',
      ).hasMatch(sessionRef)) {
        throw const FormatException();
      }
      final currency = _text(value['currency'], 3);
      if (!RegExp(r'^[A-Z]{3}$').hasMatch(currency) ||
          !session.containsKey('partySize')) {
        throw const FormatException();
      }
      final party = session['partySize'];
      if (party != null && (party is! int || party < 1 || party > 65535)) {
        throw const FormatException();
      }
      final rows = value['members'];
      if (rows is! List || rows.length > 50) throw const FormatException();
      var previous = afterMember ?? '';
      final members = <SeatedOrderMember>[];
      for (final row in rows) {
        final member = _map(row), reference = _ref(_map(row)['memberRef']);
        if (reference.compareTo(previous) <= 0 ||
            member['eligible'] is! bool ||
            !member.containsKey('nickname')) {
          throw const FormatException();
        }
        previous = reference;
        members.add(
          SeatedOrderMember._(
            reference,
            member['nickname'] == null ? null : _text(member['nickname'], 64),
            member['eligible'] as bool,
          ),
        );
      }
      if (!value.containsKey('nextAfterMember')) throw const FormatException();
      final next = value['nextAfterMember'] == null
          ? null
          : _ref(value['nextAfterMember']);
      if (next != null &&
          (members.length != 50 || members.last.reference != next)) {
        throw const FormatException();
      }
      final time = _text(value['observedAt'], 24);
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')
          .hasMatch(time)) {
        throw const FormatException();
      }
      final observedAt = DateTime.parse(time);
      if (observedAt.toIso8601String() != time) throw const FormatException();
      return OrderContextSnapshot._(
        storeRef,
        tableRef,
        sessionRef,
        _text(value['tableName'], 256),
        currency,
        session['paymentTiming'] as String,
        party as int?,
        List.unmodifiable(members),
        next,
        observedAt,
        value['tableOrderAllowed'] == true,
      );
    } catch (_) {
      throw const CcsopFailure('INVALID_ORDER_CONTEXT');
    }
  }
}
