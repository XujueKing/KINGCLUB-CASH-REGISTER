import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/table_snapshot.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

import 'support/table_fixture.dart';

TableSnapshot parse(Object? raw, {String? cursor}) => TableSnapshot.parse(
  raw,
  storeRef: 'test-store',
  employeeRef: 'E00000000001',
  afterTable: cursor,
);

void main() {
  test(
    'Snapshot keeps unknown party size, original business day and exact cents',
    () {
      final data = parse(tableFixture());
      expect(data.tables.single.session!.partySize, isNull);
      expect(data.tables.single.session!.businessDate, '2026-09-28');
      expect(data.tables.single.stateLabel, 'tableOpen');
      expect(formatCents(1201), '12.01');
      expect(formatCents(9007199254740991), '90071992547409.91');
      expect(() => data.tables.clear(), throwsUnsupportedError);
    },
  );
  test('Cross-store or cross-employee response fails closed', () {
    for (final key in ['store', 'operator']) {
      final data = tableFixture();
      data['result'][key][key == 'store' ? 'storeRef' : 'employeeRef'] =
          'other';
      expect(() => parse(data), throwsA(isA<CcsopFailure>()));
    }
  });
  test(
    'Missing, negative, floating or unsafe money is not converted to zero',
    () {
      for (final value in [null, -1, 1.5, '12', 9007199254740992]) {
        final data = tableFixture();
        data['result']['tables'][0]['session']['paidCents'] = value;
        expect(() => parse(data), throwsA(isA<CcsopFailure>()));
      }
    },
  );
  test('Pagination is bounded, unique and uses the final table cursor', () {
    expect(
      parse(tableFixture(count: 100, next: 'test-099')).nextAfterTable,
      'test-099',
    );
    expect(() => parse(tableFixture(count: 101)), throwsA(isA<CcsopFailure>()));
    expect(
      () => parse(tableFixture(count: 1, next: 'test-000')),
      throwsA(isA<CcsopFailure>()),
    );
    expect(
      () => parse(tableFixture(), cursor: 'test-000'),
      throwsA(isA<CcsopFailure>()),
    );
    final duplicate = tableFixture(count: 2);
    duplicate['result']['tables'][1]['tableRef'] = 'test-000';
    expect(() => parse(duplicate), throwsA(isA<CcsopFailure>()));
  });
  test('Inactive table is not mislabelled empty; clearing is not open', () {
    final disabled = tableFixture();
    disabled['result']['tables'][0]['tableStatus'] = 'disabled';
    disabled['result']['tables'][0]['minimumSeats'] = null;
    disabled['result']['tables'][0]['session'] = null;
    expect(parse(disabled).tables.single.stateLabel, 'tableDisabled');
    expect(parse(disabled).tables.single.minimumSeats, isNull);
    disabled['result']['tables'][0]['tableStatus'] = 'active';
    expect(() => parse(disabled), throwsA(isA<CcsopFailure>()));
    final clearing = tableFixture();
    clearing['result']['tables'][0]['session']['status'] = 'clearing';
    expect(parse(clearing).tables.single.stateLabel, 'cleaning');
  });
}
