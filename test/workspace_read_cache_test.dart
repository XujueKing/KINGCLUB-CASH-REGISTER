import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/workspace_read_cache.dart';

void main() {
  test(
    'overlapping reads share work only within the same staff session',
    () async {
      final staff = Object(), otherStaff = Object();
      final gate = Completer<int>();
      var calls = 0;
      Future<int> read() {
        calls++;
        return gate.future;
      }

      final first = WorkspaceReadCache.readOnce(staff, 'bill/V1', read);
      final duplicate = WorkspaceReadCache.readOnce(staff, 'bill/V1', read);
      final isolated = WorkspaceReadCache.readOnce(otherStaff, 'bill/V1', read);
      expect(calls, 2);
      gate.complete(10);
      expect(await Future.wait([first, duplicate, isolated]), [10, 10, 10]);
      await WorkspaceReadCache.readOnce(staff, 'bill/V1', read);
      expect(calls, 3);
    },
  );

  test('failed read is not retained and can be retried', () async {
    final staff = Object();
    await expectLater(
      WorkspaceReadCache.readOnce<int>(
        staff,
        'bill/V1',
        () async => throw StateError('offline'),
      ),
      throwsStateError,
    );
    expect(
      await WorkspaceReadCache.readOnce(staff, 'bill/V1', () async => 12),
      12,
    );
  });
}
