import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../network/ccsop_client.dart';
import 'balance_refund_command.dart';

/// Matched server result, not inferred from a transport status or refreshed balance.
class BalanceRefundResult {
  BalanceRefundResult._(
    this.confirmed,
    this.commandSignature,
    this.principalCents,
    this.giftCents,
  );
  final bool confirmed;
  final String commandSignature;
  final int? principalCents, giftCents;

  static Future<BalanceRefundResult> parse(
    Object? raw,
    PendingBalanceRefund command,
  ) async {
    try {
      if (raw is! Map<String, dynamic>) throw const FormatException();
      final value = raw['result'];
      if (value is! Map<String, dynamic>) throw const FormatException();
      if (value.length == 2 &&
          value['state'] == 'not_observed' &&
          value['refundRef'] == command.refundRef) {
        return BalanceRefundResult._(false, command.signature, null, null);
      }
      final r = value['receipt'], p = command.params;
      if (value.length != 2 ||
          value['state'] != 'refunded' ||
          r is! Map<String, dynamic> ||
          r.length != 17 ||
          r['version'] != 1 ||
          r['state'] != 'refunded' ||
          r['currency'] != 'CNY' ||
          r['refundedBy'] != command.employeeRef ||
          r['totalCents'] != p['expectedTotalCents'] ||
          [
            'storeRef',
            'orderRef',
            'refundRef',
            'originalIntentRef',
            'accountType',
            'reason',
          ].any((key) => r[key] != p[key]) ||
          r['userAccount'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{1,64}$')
              .hasMatch(r['userAccount'] as String)) {
        throw const FormatException();
      }
      final principal = r['principalCents'], gift = r['giftCents'];
      if (principal is! int ||
          gift is! int ||
          principal < 0 ||
          gift < 0 ||
          principal + gift != p['expectedTotalCents'] ||
          (p['accountType'] == 'platform_cash' && gift != 0)) {
        throw const FormatException();
      }
      final digest = await Sha256().hash(
        utf8.encode(
          jsonEncode({
            'version': 1,
            'employeeRef': command.employeeRef,
            'storeRef': p['storeRef'],
            'orderRef': p['orderRef'],
            'originalIntentRef': p['originalIntentRef'],
            'refundRef': p['refundRef'],
            'expectedTotalCents': p['expectedTotalCents'],
            'accountType': p['accountType'],
            'reason': p['reason'],
            'dispositions': p['dispositions'],
          }),
        ),
      );
      if (r['fingerprint'] !=
          digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()) {
        throw const FormatException();
      }
      final money = r['money'];
      if (money is! Map<String, dynamic> ||
          [
            'accountType',
            'storeRef',
            'userAccount',
            'refundRef',
            'originalIntentRef',
          ].any((key) => money[key] != r[key]) ||
          money['totalCents'] != '${r['totalCents']}' ||
          money['principalCents'] != '$principal' ||
          money['giftCents'] != '$gift') {
        throw const FormatException();
      }
      final stock = r['stock'];
      if (stock is! Map<String, dynamic> ||
          stock.length != 5 ||
          [
            'storeRef',
            'orderRef',
            'refundRef',
          ].any((key) => stock[key] != p[key]) ||
          stock['dispositions'] is! List ||
          stock['movements'] is! List) {
        throw const FormatException();
      }
      final choices = {
        for (final d in p['dispositions'] as List)
          d['originalMovementRef'] as String: d,
      };
      final seen = <String>{};
      final expectedReturns = <String, int>{};
      for (final d in stock['dispositions'] as List) {
        if (d is! Map<String, dynamic> ||
            d.length != 8 ||
            d['originalMovementRef'] is! String) {
          throw const FormatException();
        }
        final ref = d['originalMovementRef'] as String,
            original = choices[d['originalMovementRef']];
        if (original == null ||
            !seen.add(ref) ||
            [
              'returnQuantity',
              'physicalReturnConfirmed',
              'reason',
            ].any((key) => d[key] != original[key]) ||
            d['notReturnedQuantity'] is! int ||
            (d['notReturnedQuantity'] as int) < 0 ||
            (d['notReturnedQuantity'] as int) + (d['returnQuantity'] as int) >
                1000) {
          throw const FormatException();
        }
        if ((d['returnQuantity'] as int) > 0) {
          expectedReturns[ref] = d['returnQuantity'] as int;
        }
      }
      if (seen.length != choices.length) throw const FormatException();
      final movementIds = <String>{};
      for (final m in stock['movements'] as List) {
        if (m is! Map<String, dynamic> ||
            m.length != 3 ||
            m['movementRef'] is! String ||
            !RegExp(r'^M[0-9]{11}$').hasMatch(m['movementRef'] as String) ||
            !movementIds.add(m['movementRef'] as String) ||
            !expectedReturns.containsKey(m['originalMovementRef']) ||
            expectedReturns.remove(m['originalMovementRef']) != m['quantity']) {
          throw const FormatException();
        }
      }
      if (expectedReturns.isNotEmpty) throw const FormatException();
      return BalanceRefundResult._(true, command.signature, principal, gift);
    } catch (_) {
      throw const CcsopFailure('BALANCE_REFUND_RESPONSE_INVALID');
    }
  }
}
