import 'dart:convert';

import '../network/ccsop_client.dart';
import 'table_checkout_command.dart';

Map<String, dynamic> _object(Object? raw, List<String> keys) {
  if (raw is! Map<String, dynamic> ||
      raw.length != keys.length ||
      !raw.keys.toSet().containsAll(keys)) {
    throw const FormatException();
  }
  return raw;
}

/// Only a complete original settlement is resolved. Payment pending/unknown/
/// settlement_pending never permits a new collection or journal removal.
class TableCheckoutResult {
  TableCheckoutResult._(
    this.state,
    this.checkoutRef,
    this._command, {
    this.settledAt,
  });
  final String state, checkoutRef, _command;
  final DateTime? settledAt;
  bool get settled => state == 'settled';
  bool matches(TableCheckoutCommand command) =>
      _command == jsonEncode(command.encoded);
  factory TableCheckoutResult.parse(
    Object? raw,
    TableCheckoutCommand command, {
    required String checkoutRef,
  }) {
    try {
      if (!RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(checkoutRef)) {
        throw const FormatException();
      }
      final body = _object(raw, ['result'])['result'];
      if (body is! Map<String, dynamic>) throw const FormatException();
      final state = body['state'];
      final row = _object(
        body,
        state == 'settled'
            ? ['state', 'checkoutRef', 'receipt']
            : ['state', 'checkoutRef'],
      );
      if (row['checkoutRef'] != checkoutRef ||
          ![
            'not_sent',
            'pending',
            'unknown',
            'review_required',
            'settlement_pending',
            'settled',
          ].contains(state) ||
          (['cash', 'member_balance'].contains(command.channel) &&
              ['pending', 'unknown', 'review_required'].contains(state))) {
        throw const FormatException();
      }
      if (state != 'settled') {
        return TableCheckoutResult._(
          state as String,
          checkoutRef,
          jsonEncode(command.encoded),
        );
      }
      final r = _object(row['receipt'], [
        'version',
        'checkoutRef',
        'storeRef',
        'tableRef',
        'sessionRef',
        'currency',
        'totalCents',
        'parentPaymentRef',
        'channel',
        'accountType',
        'snapshotFingerprint',
        'orderCount',
        'allocations',
        'settledBy',
        'settledAt',
        'settlementStatus',
      ]);
      if (r['version'] is! int ||
          r['version'] != 1 ||
          r['checkoutRef'] != checkoutRef ||
          r['storeRef'] != command.storeRef ||
          r['tableRef'] != command.tableRef ||
          r['sessionRef'] != command.sessionRef ||
          r['currency'] != 'CNY' ||
          r['totalCents'] is! int ||
          r['totalCents'] != command.totalCents ||
          r['channel'] != command.channel ||
          r['accountType'] != command.accountType ||
          r['snapshotFingerprint'] != command.fingerprint ||
          r['orderCount'] is! int ||
          r['orderCount'] != command.orderCount ||
          r['settledBy'] != command.employeeRef ||
          r['settlementStatus'] != 'settled') {
        throw const FormatException();
      }
      final payment = r['parentPaymentRef'];
      if (command.channel == 'cash' || command.channel == 'member_balance') {
        if (payment !=
            '${command.channel == 'cash' ? 'cash' : 'balance'}:$checkoutRef') {
          throw const FormatException();
        }
      } else if (payment is! String ||
          payment.length > 128 ||
          !RegExp('^${command.channel}:[A-Za-z0-9_-]{1,64}\$')
              .hasMatch(payment)) {
        throw const FormatException();
      }
      final time = r['settledAt'];
      if (time is! String ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')
              .hasMatch(time)) {
        throw const FormatException();
      }
      final settledAt = DateTime.parse(time);
      if (settledAt.toIso8601String() != time) throw const FormatException();
      final allocations = r['allocations'];
      if (allocations is! List || allocations.length != command.orderCount) {
        throw const FormatException();
      }
      final ids = <String>{};
      var sum = 0;
      for (final raw in allocations) {
        final a = _object(raw, [
          'orderRef',
          'totalCents',
          'inventoryAction',
          'updateCashierOrigin',
          'orderPaymentRef',
        ]);
        final order = a['orderRef'], cents = a['totalCents'];
        if (order is! String ||
            !RegExp(r'^D[0-9]{11}$').hasMatch(order) ||
            !ids.add(order) ||
            cents is! int ||
            cents < 1 ||
            cents > 100000000 ||
            ![
              'issue_reserved',
              'already_issued',
            ].contains(a['inventoryAction']) ||
            a['updateCashierOrigin'] is! bool ||
            a['orderPaymentRef'] != 'table:$checkoutRef:$order') {
          throw const FormatException();
        }
        sum += cents;
      }
      if (sum != command.totalCents) throw const FormatException();
      // Provider references and employee data are validated but not retained by the UI result.
      return TableCheckoutResult._(
        'settled',
        checkoutRef,
        jsonEncode(command.encoded),
        settledAt: settledAt,
      );
    } catch (_) {
      throw const CcsopFailure('TABLE_CHECKOUT_RESULT_INVALID');
    }
  }
}
