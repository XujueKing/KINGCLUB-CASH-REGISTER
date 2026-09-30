import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/hardware/print_attempt_journal.dart';

import 'balance_refund_command_test.dart' show Storage;

void main() {
  final id = '1' * 32, content = '2' * 64, target = '3' * 64;
  Future<void> prepare(PrintAttemptJournal journal, [String? otherId]) =>
      journal.prepare(
        id: otherId ?? id,
        contentHash: content,
        targetHash: target,
        byteCount: 100,
      );
  Future<void> send(PrintAttemptJournal journal) => journal.beginSend(
    id,
    contentHash: content,
    targetHash: target,
    confirmed: true,
  );
  test('transport acceptance is distinct from paper completion', () async {
    final journal = PrintAttemptJournal(storage: Storage());
    await prepare(journal);
    await send(journal);
    await journal.finish(id, acceptedBytes: 100);
    expect((await journal.load()).single.state, 'transport_accepted');
    await expectLater(send(journal), throwsFormatException);
  });
  test(
    'restart after send fence blocks automatic retry and new attempts',
    () async {
      final storage = Storage(),
          journal = PrintAttemptJournal(storage: storage);
      await prepare(journal);
      await send(journal);
      final restarted = PrintAttemptJournal(storage: storage);
      expect((await restarted.load()).single.requiresReview, isTrue);
      await expectLater(send(restarted), throwsFormatException);
      await expectLater(prepare(restarted, '4' * 32), throwsFormatException);
      await expectLater(restarted.cancelPrepared(id), throwsFormatException);
    },
  );
  for (final count in [null, 0, 50, 101, -1]) {
    test(
      'ambiguous or partial transport result $count stays unknown',
      () async {
        final journal = PrintAttemptJournal(storage: Storage());
        await prepare(journal);
        await send(journal);
        await journal.finish(id, acceptedBytes: count);
        expect((await journal.load()).single.state, 'unknown');
        await expectLater(send(journal), throwsFormatException);
      },
    );
  }
  test(
    'changed content or device and missing consent never reach sending',
    () async {
      final journal = PrintAttemptJournal(storage: Storage());
      await prepare(journal);
      await expectLater(
        journal.beginSend(
          id,
          contentHash: 'a' * 64,
          targetHash: target,
          confirmed: true,
        ),
        throwsFormatException,
      );
      await expectLater(
        journal.beginSend(
          id,
          contentHash: content,
          targetHash: 'b' * 64,
          confirmed: true,
        ),
        throwsFormatException,
      );
      await expectLater(
        journal.beginSend(
          id,
          contentHash: content,
          targetHash: target,
          confirmed: false,
        ),
        throwsFormatException,
      );
      expect((await journal.load()).single.state, 'prepared');
      await journal.cancelPrepared(id);
      expect((await journal.load()).single.state, 'cancelled');
    },
  );
  test('readback failure prevents a successful send fence', () async {
    final storage = Storage(), journal = PrintAttemptJournal(storage: storage);
    await prepare(journal);
    storage.discardWrite = true;
    await expectLater(send(journal), throwsFormatException);
    expect((await journal.load()).single.state, 'prepared');
  });
}
