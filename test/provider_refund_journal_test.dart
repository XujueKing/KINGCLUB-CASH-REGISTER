import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/provider_refund_journal.dart';

import 'staff_session_test.dart' as staff;

void main() {
  final command = <String, dynamic>{
    'action': 'refund',
    'orderRef': 'D00000000001',
    'productRef': 'TEST_PRODUCT',
    'requestId': '00000000-0000-4000-8000-000000000001',
  };
  test(
    'preserves original refund across reopen and prevents concurrent overwrite',
    () async {
      final storage = staff.TestStorage(), identity = staff.session();
      final a = ProviderRefundJournal(
            identity,
            command['orderRef'],
            storage: storage,
          ),
          b = ProviderRefundJournal(
            identity,
            command['orderRef'],
            storage: storage,
          );
      final first = a.save(command),
          second = b.save({
            ...command,
            'requestId': '00000000-0000-4000-8000-000000000002',
          });
      await expectLater(second, throwsFormatException);
      await first;
      expect((await b.read())!['command'], command);
      await expectLater(b.acknowledge('wrong'), throwsFormatException);
      expect(await b.read(), isNotNull);
      await b.acknowledge(command['requestId']);
      expect(await a.read(), isNull);
    },
  );
  test('storage errors do not silently allow a new refund', () async {
    final storage = staff.TestStorage()..fail = true;
    final journal = ProviderRefundJournal(
      staff.session(),
      command['orderRef'],
      storage: storage,
    );
    await expectLater(journal.save(command), throwsA(anything));
  });
}
