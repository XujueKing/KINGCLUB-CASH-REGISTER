import '../network/ccsop_client.dart';

bool validRechargeRef(String value) => RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
).hasMatch(value);

Map<String, dynamic> _object(Object? value, List<String> keys) {
  if (value is! Map<String, dynamic> || value.length != keys.length ||
      !value.keys.toSet().containsAll(keys)) {
    throw const FormatException();
  }
  return value;
}
int _cents(Object? value, {bool positive = false}) {
  if (value is! String || !RegExp(r'^(0|[1-9][0-9]{0,8})$').hasMatch(value)) {
    throw const FormatException();
  }
  final amount = int.parse(value);
  if (amount > 100000000 || (positive && amount == 0)) throw const FormatException();
  return amount;
}

/// Only `credited` is a balance-credit success. Provider-paid/credit-pending must
/// not be treated as a new spendable amount. Contains no payer code or identity.
class RechargeResult {
  const RechargeResult._(this.state, this.rechargeRef, this.storeRef, {this.principalCents,
    this.giftCents, this.creditedAt});
  final String state, rechargeRef, storeRef;
  final int? principalCents, giftCents;
  final DateTime? creditedAt;
  bool get credited => state == 'credited';
  bool get requiresReview => state == 'review_required';

  factory RechargeResult.parse(Object? raw, {required String storeRef,
    required String rechargeRef, int? expectedPrincipalCents}) {
    try {
      if (!validRechargeRef(rechargeRef) ||
          !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(storeRef) ||
          (expectedPrincipalCents != null && (expectedPrincipalCents < 1 || expectedPrincipalCents > 100000000))) {
        throw const FormatException();
      }
      final envelope = _object(raw, ['result']);
      final value = envelope['result'];
      if (value is! Map<String, dynamic>) throw const FormatException();
      final state = value['state'];
      const states = ['not_sent','pending','unknown','review_required','credit_pending','credited'];
      if (!states.contains(state) || value['rechargeRef'] != rechargeRef) throw const FormatException();
      _object(value, state == 'credited' ? ['state','rechargeRef','receipt'] : ['state','rechargeRef']);
      if (state != 'credited') return RechargeResult._(state as String, rechargeRef, storeRef);
      final receipt = _object(value['receipt'], ['version','rechargeRef','storeRef','userAccount',
        'currency','accountType','lotRef','principalCents','giftCents','creditedAt']);
      if (receipt['version'] != 1 || receipt['rechargeRef'] != rechargeRef || receipt['storeRef'] != storeRef ||
          receipt['currency'] != 'CNY' || receipt['accountType'] != 'store_balance' ||
          receipt['userAccount'] is! String || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(receipt['userAccount'] as String) ||
          receipt['lotRef'] is! String || !validRechargeRef(receipt['lotRef'] as String)) {
        throw const FormatException();
      }
      final principal = _cents(receipt['principalCents'], positive: true), gift = _cents(receipt['giftCents']);
      if (expectedPrincipalCents != null && principal != expectedPrincipalCents) throw const FormatException();
      final timestamp = receipt['creditedAt'];
      if (timestamp is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$').hasMatch(timestamp)) {
        throw const FormatException();
      }
      final at = DateTime.parse(timestamp);
      if (at.toIso8601String() != timestamp) throw const FormatException();
      return RechargeResult._('credited', rechargeRef, storeRef, principalCents: principal, giftCents: gift, creditedAt: at);
    } catch (_) { throw const CcsopFailure('RECHARGE_RESULT_INVALID'); }
  }
}
