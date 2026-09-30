import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/voucher_lookup.dart';

const requestId = '00000000-0000-4000-8000-000000000001';
Map<String, Object?> fixture() => {
  'storeRef': 'TEST_STORE',
  'employeeRef': 'E00000000001',
  'provider': 'douyin',
  'requestId': requestId,
  'state': 'recorded',
  'receipt': {
    'results': [
      {'result': 0, 'certificateId': 'TEST_CERT', 'verifyId': 'TEST_VERIFY'},
      {'result': 1208},
    ],
  },
};
VoucherLookup parse(Map<String, Object?> value) => VoucherLookup.parse(
  {'result': value},
  storeRef: 'TEST_STORE',
  employeeRef: 'E00000000001',
  provider: 'douyin',
  requestId: requestId,
);
void main() {
  test('keeps partial success and failed rows distinct', () {
    final result = parse(fixture());
    expect(result.state, 'recorded');
    expect(result.rows.map((r) => r.code), [0, 1208]);
  });
  for (final key in ['storeRef', 'employeeRef', 'provider', 'requestId']) {
    test(
      'rejects mismatched $key',
      () => expect(
        () => parse(fixture()..[key] = 'OTHER'),
        throwsFormatException,
      ),
    );
  }
  test('unknown cannot carry success evidence', () {
    expect(
      () => parse(fixture()..['state'] = 'unknown'),
      throwsFormatException,
    );
    expect(
      parse(
        fixture()
          ..['state'] = 'unknown'
          ..remove('receipt'),
      ).rows,
      isEmpty,
    );
  });
  test('recorded requires nonempty valid per-coupon proof', () {
    expect(
      () => parse(fixture()..['receipt'] = {'results': []}),
      throwsFormatException,
    );
    expect(
      () => parse(
        fixture()
          ..['receipt'] = {
            'results': [
              {'result': 0},
            ],
          },
      ),
      throwsFormatException,
    );
  });
}
