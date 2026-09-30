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

/// A closed admission or not_cancelled is not cancellation evidence. Only the
/// complete original server receipt permits removal from the recovery journal.
class TableCheckoutCancellation {
  TableCheckoutCancellation._(
    this.cancelled,
    this.checkoutRef,
    this._command,
    this.cancelledAt,
  );
  final bool cancelled;
  final String checkoutRef, _command;
  final DateTime? cancelledAt;
  bool matches(TableCheckoutCommand command) =>
      _command == jsonEncode(command.encoded);
  factory TableCheckoutCancellation.parse(
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
      final cancelled = body['state'] == 'cancelled_unsent';
      final row = _object(
        body,
        cancelled
            ? ['state', 'checkoutRef', 'receipt']
            : ['state', 'checkoutRef'],
      );
      if (row['checkoutRef'] != checkoutRef ||
          (!cancelled && row['state'] != 'not_cancelled')) {
        throw const FormatException();
      }
      if (!cancelled) {
        return TableCheckoutCancellation._(
          false,
          checkoutRef,
          jsonEncode(command.encoded),
          null,
        );
      }
      final receipt = _object(row['receipt'], [
        'version',
        'state',
        'scope',
        'orderCount',
        'orderRefs',
        'cancelledAt',
      ]);
      final scope = _object(receipt['scope'], [
        'checkoutRef',
        'requestId',
        'employeeRef',
        'storeRef',
        'tableRef',
        'sessionRef',
        'channel',
        'accountType',
        'currency',
        'totalCents',
        'snapshotFingerprint',
      ]);
      final expected = <String, dynamic>{
        'checkoutRef': checkoutRef,
        'requestId': command.requestId,
        'employeeRef': command.employeeRef,
        'storeRef': command.storeRef,
        'tableRef': command.tableRef,
        'sessionRef': command.sessionRef,
        'channel': command.channel,
        'accountType': command.accountType,
        'currency': 'CNY',
        'totalCents': command.totalCents,
        'snapshotFingerprint': command.fingerprint,
      };
      if (receipt['version'] is! int ||
          receipt['version'] != 1 ||
          receipt['state'] != 'cancelled_unsent' ||
          receipt['orderCount'] is! int ||
          receipt['orderCount'] != command.orderCount ||
          scope['totalCents'] is! int ||
          expected.entries.any((entry) => scope[entry.key] != entry.value)) {
        throw const FormatException();
      }
      final orders = receipt['orderRefs'];
      if (orders is! List || orders.length != command.orderCount) {
        throw const FormatException();
      }
      String? previous;
      for (final order in orders) {
        if (order is! String ||
            !RegExp(r'^D[0-9]{11}$').hasMatch(order) ||
            (previous != null && previous.compareTo(order) >= 0)) {
          throw const FormatException();
        }
        previous = order;
      }
      final time = receipt['cancelledAt'];
      if (time is! String ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')
              .hasMatch(time)) {
        throw const FormatException();
      }
      final at = DateTime.parse(time);
      if (at.toIso8601String() != time) throw const FormatException();
      return TableCheckoutCancellation._(
        true,
        checkoutRef,
        jsonEncode(command.encoded),
        at,
      );
    } catch (_) {
      throw const CcsopFailure('TABLE_CHECKOUT_CANCELLATION_INVALID');
    }
  }
}
