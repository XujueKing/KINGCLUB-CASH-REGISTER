import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/together_admission.dart';
import 'package:kingclub_cash_register/src/live/together_admission_dialog.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'live_tables_panel_test.dart' show TableAuth;
import 'staff_session_test.dart' as a;
import 'catalog_snapshot_test.dart' show Api;

import 'package:kingclub_cash_register/src/network/ccsop_client.dart';

Map<String, dynamic> receipt({
  bool replayed = false,
  String store = 'test-store',
}) => {
  'result': {
    'storeRef': store,
    'bookingRef': 'booking-1',
    'partyRef': 'party-1',
    'employeeRef': 'E00000000001',
    'releasedCents': '10000',
    'usedAt': '2026-10-04T12:00:00.000Z',
    'replayed': replayed,
  },
};

class AdmissionAuth extends TableAuth {
  AdmissionAuth() : super(permissions: ['workbench.read', 'together.admit']);
  final scans = <String>[];
  Completer<TogetherAdmission>? pending;
  @override
  Future<TogetherAdmission> consumeTogetherAdmission(String code) async {
    scans.add(code);
    return pending == null
        ? TogetherAdmission.parse(
            receipt(replayed: scans.length > 1),
            storeRef: 'test-store',
          )
        : pending!.future;
  }
}

void main() {
  test(
    'controller binds store and permission, rejects late logout reply',
    () async {
      for (final allowed in [false, true]) {
        final login = a.TestAuth()
          ..result = {
            ...a.response(),
            'permissions': ['workbench.read', if (allowed) 'together.admit'],
          };
        final api = Api()..pendingRead = Completer<Object?>();
        final auth = a.controller(a.TestStorage(), login, api);
        await a.login(auth);
        if (!allowed) {
          await expectLater(
            auth.consumeTogetherAdmission('KCTICKET1:${'A' * 43}'),
            throwsA(isA<CcsopFailure>()),
          );
          expect(api.id, isNull);
        } else {
          final pending = auth.consumeTogetherAdmission(
            'KCTICKET1:${'A' * 43}',
          );
          final rejected = expectLater(pending, throwsA(isA<CcsopFailure>()));
          expect(api.id, 'K261004001990');
          expect(api.params!['storeRef'], 'test-store');
          await auth.logout();
          api.pendingRead!.complete(receipt());
          await rejected;
        }
        auth.dispose();
      }
    },
  );
  test('rejects cross-store and malformed receipts', () {
    expect(
      () => TogetherAdmission.parse(
        receipt(store: 'other'),
        storeRef: 'test-store',
      ),
      throwsFormatException,
    );
    final invalid = receipt();
    (invalid['result'] as Map)['releasedCents'] = '-1';
    expect(
      () => TogetherAdmission.parse(invalid, storeRef: 'test-store'),
      throwsFormatException,
    );
  });
  testWidgets(
    'scanner excludes payment codes, shows replay, detaches on close',
    (tester) async {
      final auth = AdmissionAuth(),
          events = StreamController<String>.broadcast();
      await tester.pumpWidget(
        MaterialApp(
          home: TogetherAdmissionDialog(
            auth: auth,
            language: UiLanguage.zh,
            scannerEvents: events.stream,
          ),
        ),
      );
      events.add('KCPAY1:${'A' * 43}');
      await tester.pumpAndSettle();
      expect(auth.scans, isEmpty);
      events.add('KCTICKET1:${'A' * 43}');
      await tester.pumpAndSettle();
      expect(
        find.text(tr(UiLanguage.zh, 'togetherAdmissionSuccess')),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      events.add('KCTICKET1:${'A' * 43}');
      await tester.pumpAndSettle();
      expect(
        find.text(tr(UiLanguage.zh, 'togetherAdmissionRepeated')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      expect(events.hasListener, isFalse);
      await events.close();
      auth.dispose();
    },
  );
  testWidgets('busy scans ignored and background discards late success', (
    tester,
  ) async {
    final auth = AdmissionAuth()..pending = Completer<TogetherAdmission>();
    final events = StreamController<String>.broadcast();
    await tester.pumpWidget(
      MaterialApp(
        home: TogetherAdmissionDialog(
          auth: auth,
          language: UiLanguage.zh,
          scannerEvents: events.stream,
        ),
      ),
    );
    events.add('KCTICKET1:${'A' * 43}');
    await tester.pump();
    events.add('KCTICKET1:${'B' * 43}');
    await tester.pump();
    expect(auth.scans, hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    auth.pending!.complete(
      TogetherAdmission.parse(receipt(), storeRef: 'test-store'),
    );
    await tester.pump();
    expect(
      find.text(tr(UiLanguage.zh, 'togetherAdmissionSuccess')),
      findsNothing,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
    await events.close();
    auth.dispose();
  });
}
