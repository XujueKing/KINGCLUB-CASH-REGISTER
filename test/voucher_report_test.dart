import 'package:flutter_test/flutter_test.dart';

import 'package:kingclub_cash_register/src/live/voucher_report.dart';

Map<String, Object?> fixture() => {
  'storeRef': 'TEST_STORE',
  'from': '2026-09-30',
  'to': '2026-09-30',
  'provider': 'all',
  'currency': 'CNY',
  'details': <Object?>[],
  'nextAfterVoucher': null,
  for (final key in VoucherReport.amountKeys) key: '0',
  for (final key in VoucherReport.countKeys) key: 0,
};
VoucherReport parse(Map<String, Object?> value) => VoucherReport.parse(
  {'result': value},
  storeRef: 'TEST_STORE',
  from: '2026-09-30',
  to: '2026-09-30',
  provider: 'all',
);
void main() {
  Map<String, Object?> detail(int index) => {
    'voucherRef': index.toRadixString(16).padLeft(64, '0'),
    'provider': 'douyin',
    'certificateId': 'TEST_$index',
    'reversed': false,
    'redemptionDay': null,
    'expectedDay': null,
    'valuationStatus': 'unvalued',
    'netReceivableCents': null,
    'outstandingCents': null,
    'receivedCents': '0',
    'returnedCents': '0',
    'repayableCents': '0',
  };
  test(
    'retains unvalued amounts as unknown and validates full-page cursors',
    () {
      final raw = fixture()
        ..['details'] = [for (var i = 1; i <= 50; i++) detail(i)]
        ..['nextAfterVoucher'] = detail(50)['voucherRef'];
      final report = parse(raw);
      expect(report.details.length, 50);
      expect(report.details.first.money('outstandingCents'), isNull);
      expect(report.nextAfter, detail(50)['voucherRef']);
      raw['nextAfterVoucher'] = detail(49)['voucherRef'];
      expect(() => parse(raw), throwsFormatException);
    },
  );
  test('rejects duplicate rows and unvalued amounts represented as zero', () {
    expect(
      () => parse(fixture()..['details'] = [detail(1), detail(1)]),
      throwsFormatException,
    );
    expect(
      () => parse(
        fixture()..['details'] = [detail(1)..['outstandingCents'] = '0'],
      ),
      throwsFormatException,
    );
    expect(
      () => parse(
        fixture()..['details'] = [detail(1)..['expectedDay'] = '2026-02-31'],
      ),
      throwsFormatException,
    );
  });
  test('formats exact large amounts without double rounding', () {
    final raw = fixture()..['closingReceivableCents'] = '900719925474099301';
    expect(parse(raw).money('closingReceivableCents'), '9007199254740993.01');
  });
  test('keeps returns distinct and permits negative net receipts', () {
    final raw = fixture()
      ..['returnedCents'] = '101'
      ..['cashNetCents'] = '-101';
    expect(parse(raw).money('cashNetCents'), '-1.01');
  });
  for (final key in ['storeRef', 'from', 'to', 'provider', 'currency']) {
    test(
      'rejects different $key',
      () => expect(
        () => parse(fixture()..[key] = 'OTHER'),
        throwsFormatException,
      ),
    );
  }
  test(
    'rejects partial or inconsistent totals rather than defaulting to zero',
    () {
      expect(
        () => parse(fixture()..remove('unvaluedCount')),
        throwsFormatException,
      );
      expect(
        () => parse(fixture()..['cashNetCents'] = '1'),
        throwsFormatException,
      );
      expect(
        () => parse(fixture()..['closingReceivableCents'] = 1.1),
        throwsFormatException,
      );
    },
  );
}
