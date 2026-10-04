import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_document_renderer.dart';
import 'package:kingclub_cash_register/src/hardware/receipt_print_identity.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'table_receipt_document_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('customer receipt preserves line prices and one parent tender without internal IDs', () {
    final document = fixture.parse(fixture.tableReceiptFixture());
    for (final language in UiLanguage.values) {
      for (final width in [384, 512, 576]) {
        final plan = ReceiptRasterPlan.forTable(
          document,
          language: language,
          widthDots: width,
        );
        final blocks = plan.pages.expand((page) => page).toList();
        expect(plan.header, isNot(contains(fixture.checkout)));
        expect(blocks.join(), isNot(contains('TEST_STORE')));
        expect(blocks.join(), isNot(contains('TEST_SESSION')));
        expect(blocks.join(), isNot(contains('UTC')));
        expect(
          blocks.where(
            (text) =>
                text == '${tr(language, 'provider_member_balance')}  3.00',
          ),
          hasLength(1),
        );
        expect(blocks, contains('${tr(language, 'receiptPrincipal')}  2.40'));
        expect(blocks, contains('${tr(language, 'receiptGift')}  0.60'));
        expect(
          blocks.where(
            (text) => text.startsWith('${tr(language, 'orderPreviewTotal')}  '),
          ),
          hasLength(1),
        );
        for (final order in document.orders) {
          expect(
            blocks.where((text) => text.endsWith(': ${order.orderRef}')),
            hasLength(1),
          );
        }
        expect(() => plan.pages.clear(), throwsUnsupportedError);
        expect(() => plan.pages.first.clear(), throwsUnsupportedError);
      }
    }
  });
  test('cash and platform cash do not reuse store gift amounts', () {
    for (final tender in [
      {'channel': 'cash', 'receivedCents': 500, 'changeCents': 200},
      {
        'channel': 'member_balance',
        'accountType': 'platform_cash',
        'principalCents': 300,
        'giftCents': 0,
      },
    ]) {
      final raw = fixture.tableReceiptFixture();
      raw['result']['tender'] = tender;
      final plan = ReceiptRasterPlan.forTable(
        fixture.parse(raw),
        language: UiLanguage.values.first,
        widthDots: 576,
      );
      final text = plan.pages.expand((page) => page).join('\n');
      expect(text, isNot(contains('  0.60')));
      expect(text, contains(tender['channel'] == 'cash' ? '  5.00' : '  0.00'));
    }
  });
  test('table print identity is parent-scoped and namespaced', () {
    final identity = ReceiptPrintIdentity.forTable(
      base: 'https://test.invalid',
      storeRef: 'TEST_STORE',
      checkoutRef: fixture.checkout,
    );
    expect(jsonDecode(identity.canonical), [
      'table-receipt-v1',
      'https://test.invalid',
      'TEST_STORE',
      fixture.checkout,
    ]);
    expect(
      () => ReceiptPrintIdentity.forTable(
        base: 'https://test.invalid',
        storeRef: 'TEST_STORE',
        checkoutRef: 'D00000000001',
      ),
      throwsFormatException,
    );
    expect(
      () => ReceiptPrintIdentity(
        base: 'https://test.invalid',
        storeRef: 'TEST_STORE',
        orderRef: fixture.checkout,
      ),
      throwsFormatException,
    );
    expect(
      () => ReceiptPrintIdentity.forTable(
        base: 'https://test.invalid?token=forbidden',
        storeRef: 'TEST_STORE',
        checkoutRef: fixture.checkout,
      ),
      throwsFormatException,
    );
  });
}
