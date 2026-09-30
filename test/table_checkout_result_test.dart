import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_command.dart';
import 'package:kingclub_cash_register/src/live/table_checkout_result.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'table_checkout_command_test.dart' as fixture;

const checkout = '00000000-0000-4000-8000-000000000001';
Map<String, dynamic> settlementFixture(TableCheckoutCommand c) => {
  'result': {
    'state': 'settled',
    'checkoutRef': checkout,
    'receipt': {
      'version': 1,
      'checkoutRef': checkout,
      'storeRef': c.storeRef,
      'tableRef': c.tableRef,
      'sessionRef': c.sessionRef,
      'currency': 'CNY',
      'totalCents': c.totalCents,
      'parentPaymentRef': c.channel == 'cash'
          ? 'cash:$checkout'
          : c.channel == 'member_balance'
          ? 'balance:$checkout'
          : '${c.channel}:TEST_TRANSACTION',
      'channel': c.channel,
      'accountType': c.accountType,
      'snapshotFingerprint': c.fingerprint,
      'orderCount': 2,
      'settledBy': c.employeeRef,
      'settledAt': '2026-09-30T00:00:00.000Z',
      'settlementStatus': 'settled',
      'allocations': [
        for (var n = 1; n <= 2; n++)
          {
            'orderRef': 'D0000000000$n',
            'totalCents': n * 100,
            'inventoryAction': 'issue_reserved',
            'updateCashierOrigin': false,
            'orderPaymentRef': 'table:$checkout:D0000000000$n',
          },
      ],
    },
  },
};
void main() {
  test(
    'all channels share original settlement validation without account mixing',
    () {
      for (final channel in ['wechat', 'alipay', 'cash', 'member_balance']) {
        for (final account
            in channel == 'member_balance'
                ? ['platform_cash', 'store_balance']
                : [null]) {
          final c = TableCheckoutCommand.decode({
            ...fixture.command().encoded,
            'channel': channel,
            'accountType': account,
          });
          final result = TableCheckoutResult.parse(
            settlementFixture(c),
            c,
            checkoutRef: checkout,
          );
          expect(result.settled, true);
          expect(result.matches(c), true);
          expect(result.settledAt, isNotNull);
        }
      }
    },
  );
  test('pending outcomes retain original instead of implying completion', () {
    final c = TableCheckoutCommand.decode({
      ...fixture.command().encoded,
      'channel': 'wechat',
      'accountType': null,
    });
    for (final state in [
      'not_sent',
      'pending',
      'unknown',
      'review_required',
      'settlement_pending',
    ]) {
      final result = TableCheckoutResult.parse(
        {
          'result': {'state': state, 'checkoutRef': checkout},
        },
        c,
        checkoutRef: checkout,
      );
      expect(result.settled, false);
      expect(result.settledAt, isNull);
    }
  });
  for (final field in [
    'storeRef',
    'tableRef',
    'sessionRef',
    'checkoutRef',
    'totalCents',
    'accountType',
    'parentPaymentRef',
    'snapshotFingerprint',
    'orderCount',
    'settledBy',
    'settledAt',
    'settlementStatus',
    'version',
    'extra',
  ]) {
    test('rejects corrupt settlement $field', () {
      final c = fixture.command(), raw = settlementFixture(c);
      ((raw['result'] as Map)['receipt'] as Map)[field] = 'wrong';
      expect(
        () => TableCheckoutResult.parse(raw, c, checkoutRef: checkout),
        throwsA(isA<CcsopFailure>()),
      );
    });
  }
  test('rejects duplicate allocations and swapped original checkout', () {
    final c = fixture.command(), raw = settlementFixture(c);
    final rows =
        ((raw['result'] as Map)['receipt'] as Map)['allocations'] as List;
    rows[1] = rows[0];
    expect(
      () => TableCheckoutResult.parse(raw, c, checkoutRef: checkout),
      throwsA(isA<CcsopFailure>()),
    );
    expect(
      () => TableCheckoutResult.parse(
        settlementFixture(c),
        c,
        checkoutRef: '00000000-0000-4000-8000-000000000002',
      ),
      throwsA(isA<CcsopFailure>()),
    );
  });
}
