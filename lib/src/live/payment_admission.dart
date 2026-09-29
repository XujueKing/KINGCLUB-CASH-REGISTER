import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';

const paymentPermissions = <String, String>{
  'cash': 'payment.cash',
  'wechat': 'payment.wechat',
  'alipay': 'payment.alipay',
  'member_balance': 'payment.balance',
};

/// Original request lookup only. Does not generate a request ID or authorize payment.
class PaymentAdmissionQuery {
  PaymentAdmissionQuery._(
    this.base,
    this.employeeRef,
    this.deviceId,
    this.params,
  );
  final String base, employeeRef, deviceId;
  final Map<String, dynamic> params;
  String get requestId => params['requestId'] as String;
  String get channel => params['channel'] as String;
  String get permission => paymentPermissions[channel]!;
  bool belongsTo(StaffSession identity) =>
      base == identity.base.toString() &&
      employeeRef == identity.employeeRef &&
      deviceId == identity.deviceId &&
      params['storeRef'] == identity.storeRef;

  factory PaymentAdmissionQuery.original({
    required StaffSession identity,
    required String orderRef,
    required String requestId,
    required String channel,
    required int expectedTotalCents,
    required String currency,
  }) {
    if (!RegExp(r'^D[0-9]{11}$').hasMatch(orderRef) ||
        !uuidPattern.hasMatch(requestId) ||
        !paymentPermissions.containsKey(channel) ||
        expectedTotalCents < 1 ||
        expectedTotalCents > 100000000 ||
        currency != 'CNY') {
      throw const CcsopFailure('PAYMENT_ADMISSION_REQUEST_INVALID');
    }
    return PaymentAdmissionQuery._(
      identity.base.toString(),
      identity.employeeRef,
      identity.deviceId,
      Map.unmodifiable({
        'storeRef': identity.storeRef,
        'orderRef': orderRef,
        'requestId': requestId.toLowerCase(),
        'channel': channel,
        'expectedTotalCents': expectedTotalCents,
        'currency': currency,
      }),
    );
  }
}

/// Admission evidence, never a verified payment, closure, refund or retry permission.
class PaymentAdmissionResult {
  PaymentAdmissionResult._(this.observed, this.intentRef, this.admissionStatus);
  final bool observed;
  final String? intentRef, admissionStatus;

  factory PaymentAdmissionResult.parse(
    Object? raw,
    PaymentAdmissionQuery query,
  ) {
    try {
      if (raw is! Map<String, dynamic>) throw const FormatException();
      final value = raw['result'];
      if (value is! Map<String, dynamic> ||
          value['requestId'] != query.requestId) {
        throw const FormatException();
      }
      if (value['state'] == 'not_observed' && value.length == 2) {
        return PaymentAdmissionResult._(false, null, null);
      }
      final intent = value['intent'];
      if (value['state'] != 'intent_observed' ||
          value.length != 3 ||
          intent is! Map<String, dynamic> ||
          intent.length != 8 ||
          intent['intentRef'] is! String ||
          !uuidPattern.hasMatch(intent['intentRef'] as String) ||
          intent['totalCents'] is! int ||
          intent['totalCents'] != query.params['expectedTotalCents'] ||
          !{
            'prepared',
            'pending',
            'unknown',
            'confirmed',
            'closed',
          }.contains(intent['intentStatus'])) {
        throw const FormatException();
      }
      for (final field in [
        'storeRef',
        'orderRef',
        'requestId',
        'channel',
        'currency',
      ]) {
        if (intent[field] != query.params[field]) throw const FormatException();
      }
      return PaymentAdmissionResult._(
        true,
        intent['intentRef'] as String,
        intent['intentStatus'] as String,
      );
    } catch (_) {
      throw const CcsopFailure('PAYMENT_ADMISSION_RESPONSE_INVALID');
    }
  }
}
