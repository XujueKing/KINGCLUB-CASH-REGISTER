import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kingclub_cash_register/src/live/balance_refund_command.dart';
import 'package:kingclub_cash_register/src/live/balance_refund_journal.dart';
import 'package:kingclub_cash_register/src/live/balance_refund_result.dart';
import 'balance_refund_command_test.dart' as c;

Future<Map<String, dynamic>> response(PendingBalanceRefund command) async {
  final p = command.params;
  final hash = await Sha256().hash(
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
  return {
    'result': {
      'state': 'refunded',
      'receipt': {
        'version': 1,
        'state': 'refunded',
        'refundRef': command.refundRef,
        'storeRef': command.storeRef,
        'orderRef': command.orderRef,
        'originalIntentRef': p['originalIntentRef'],
        'accountType': 'store_balance',
        'userAccount': 'TEST_MEMBER',
        'totalCents': 100,
        'principalCents': 80,
        'giftCents': 20,
        'currency': 'CNY',
        'refundedBy': command.employeeRef,
        'reason': p['reason'],
        'fingerprint': hash.bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        'money': {
          'accountType': 'store_balance',
          'storeRef': command.storeRef,
          'userAccount': 'TEST_MEMBER',
          'refundRef': command.refundRef,
          'originalIntentRef': p['originalIntentRef'],
          'totalCents': '100',
          'principalCents': '80',
          'giftCents': '20',
          'allocations': [],
        },
        'stock': {
          'refundRef': command.refundRef,
          'storeRef': command.storeRef,
          'orderRef': command.orderRef,
          'movements': [],
          'dispositions': [
            <String, dynamic>{
              ...(p['dispositions'] as List).single,
              'productRef': 'TEST_PRODUCT',
              'batchRef': 'TEST_BATCH',
              'notReturnedQuantity': 2,
              'returnedCostCents': '0',
            },
          ],
        },
      },
    },
  };
}

void main() {
  test(
    'matched confirmed response releases only its saved original request',
    () async {
      final command = c.command(),
          journal = BalanceRefundJournal(storage: c.Storage());
      await journal.save(command, c.identity);
      final result = await BalanceRefundResult.parse(
        await response(command),
        command,
      );
      expect(result.confirmed, isTrue);
      expect(result.principalCents, 80);
      expect(result.giftCents, 20);
      await journal.acknowledge(c.identity, result);
      expect(await journal.load(c.identity), isEmpty);
    },
  );
  test(
    'not observed is not a successful refund and cannot erase pending request',
    () async {
      final command = c.command(),
          journal = BalanceRefundJournal(storage: c.Storage());
      await journal.save(command, c.identity);
      final result = await BalanceRefundResult.parse({
        'result': {'state': 'not_observed', 'refundRef': command.refundRef},
      }, command);
      expect(result.confirmed, isFalse);
      await expectLater(
        journal.acknowledge(c.identity, result),
        c.fails('BALANCE_REFUND_RESULT_UNCONFIRMED'),
      );
      expect(await journal.load(c.identity), hasLength(1));
    },
  );
  for (final kind in [
    'refund',
    'employee',
    'digest',
    'total',
    'split',
    'money',
    'disposition',
    'movement',
  ]) {
    test('rejects mismatched $kind', () async {
      final command = c.command(), raw = await response(command);
      final r = raw['result']['receipt'] as Map<String, dynamic>;
      switch (kind) {
        case 'refund':
          r['refundRef'] = '00000000-0000-4000-8000-000000000099';
          break;
        case 'employee':
          r['refundedBy'] = 'E00000000002';
          break;
        case 'digest':
          r['fingerprint'] = '0' * 64;
          break;
        case 'total':
          r['totalCents'] = 101;
          break;
        case 'split':
          r['giftCents'] = 21;
          break;
        case 'money':
          r['money']['userAccount'] = 'OTHER_MEMBER';
          break;
        case 'disposition':
          r['stock']['dispositions'][0]['reason'] = 'CHANGED';
          break;
        case 'movement':
          r['stock']['movements'] = [
            {
              'movementRef': 'M00000000002',
              'originalMovementRef': 'M00000000001',
              'quantity': 1,
            },
          ];
          break;
      }
      await expectLater(
        BalanceRefundResult.parse(raw, command),
        c.fails('BALANCE_REFUND_RESPONSE_INVALID'),
      );
    });
  }
}
