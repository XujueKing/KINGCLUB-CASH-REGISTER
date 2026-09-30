import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_command.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'table_checkout_command_test.dart' as fixture;

Map<String, dynamic> admissionFixture(TableCheckoutCommand c) => {
  'result': {
    'state': 'admission_observed',
    'requestId': c.requestId,
    'checkoutRef': '00000000-0000-4000-8000-000000000001',
    'paymentStatus': 'prepared',
    'storeRef': c.storeRef,
    'tableRef': c.tableRef,
    'sessionRef': c.sessionRef,
    'channel': c.channel,
    'accountType': c.accountType,
    'currency': 'CNY',
    'totalCents': c.totalCents,
    'orderCount': c.orderCount,
    'snapshotFingerprint': c.fingerprint,
  },
};
void main() {
  test(
    'accepts admission metadata and not-observed without claiming settlement',
    () {
      final c = fixture.command();
      for (final status in [
        'prepared',
        'pending',
        'unknown',
        'paid',
        'settled',
        'closed',
      ]) {
        final raw = admissionFixture(c);
        (raw['result'] as Map)['paymentStatus'] = status;
        final result = TableCheckoutAdmission.parse(raw, c);
        expect(result.observed, true);
        expect(result.paymentStatus, status);
      }
      final absent = TableCheckoutAdmission.parse({
        'result': {'state': 'not_observed', 'requestId': c.requestId},
      }, c);
      expect(absent.observed, false);
      expect(absent.checkoutRef, isNull);
    },
  );
  for (final field in [
    'requestId',
    'checkoutRef',
    'storeRef',
    'tableRef',
    'sessionRef',
    'channel',
    'accountType',
    'currency',
    'totalCents',
    'orderCount',
    'snapshotFingerprint',
    'paymentStatus',
    'receipt',
  ]) {
    test('rejects mismatched or injected admission $field', () {
      final c = fixture.command(), raw = admissionFixture(c);
      (raw['result'] as Map)[field] = 'wrong';
      expect(
        () => TableCheckoutAdmission.parse(raw, c),
        throwsA(isA<CcsopFailure>()),
      );
    });
  }
}
