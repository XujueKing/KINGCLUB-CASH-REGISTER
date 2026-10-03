import 'dart:convert';
import 'dart:math';

import '../auth/session_vault.dart';
import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import 'opening_snapshot.dart';

/// Immutable command and recovery ownership; no API key or refresh token is stored.
class PendingOpening {
  PendingOpening._(this.base, this.employeeRef, this.deviceId, this._params);
  final String base, employeeRef, deviceId;
  final Map<String, dynamic> _params;
  String get storeRef => _params['storeRef'] as String;
  String get tableId => _params['tableId'] as String;
  String get requestId => _params['requestId'] as String;
  Map<String, dynamic> get params => Map.unmodifiable({
    ..._params,
    'memberRefs': List<String>.unmodifiable(_params['memberRefs'] as List),
    'staffConfirmation': const {
      'arrivalConfirmed': true,
      'reservationChecked': true,
    },
  });
  bool belongsTo(StaffSession session) =>
      base == session.base.toString() &&
      employeeRef == session.employeeRef &&
      deviceId == session.deviceId &&
      storeRef == session.storeRef;

  factory PendingOpening.prepare({
    required StaffSession session,
    required OpeningContext context,
    required int? partySize,
    required List<String> memberRefs,
    required bool arrivalConfirmed,
    required bool reservationChecked,
    Map<String, dynamic>? selectedRule,
  }) {
    if (!session.permissions.contains('table.open') ||
        context.storeRef != session.storeRef ||
        !context.openingEnabled ||
        context.tableStatus != 'active' ||
        context.activeSessionRef != null ||
        !arrivalConfirmed ||
        !reservationChecked) {
      throw const CcsopFailure('OPENING_CONFIRMATION_REQUIRED');
    }
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return PendingOpening._decode({
      'base': session.base.toString(),
      'employeeRef': session.employeeRef,
      'deviceId': session.deviceId,
      'params': {
        'selectedRule': ?selectedRule,
        'storeRef': session.storeRef,
        'tableId': context.tableId,
        'requestId': id,
        'expectedPaymentTiming': context.paymentTiming,
        'expectedBusinessDate': context.businessDate,
        'expectedRuleRevision': context.revision,
        'expectedRuleMode': context.mode,
        'memberRefs': List<String>.of(memberRefs)..sort(),
        'partySize': partySize,
        'manualOverride': false,
        'staffConfirmation': {
          'arrivalConfirmed': true,
          'reservationChecked': true,
        },
      },
    });
  }

  Map<String, dynamic> _encode() => {
    'base': base,
    'employeeRef': employeeRef,
    'deviceId': deviceId,
    'params': params,
  };

  static PendingOpening _decode(Object? raw) {
    if (raw is! Map<String, dynamic> || raw.length != 4) {
      throw const FormatException();
    }
    final base = raw['base'],
        employee = raw['employeeRef'],
        device = raw['deviceId'],
        p = raw['params'];
    final uri = base is String ? Uri.tryParse(base) : null;
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        employee is! String ||
        !RegExp(r'^E[0-9]{11}$').hasMatch(employee) ||
        device is! String ||
        !uuidPattern.hasMatch(device) ||
        p is! Map<String, dynamic> ||
        p.length != (p.containsKey('selectedRule') ? 12 : 11)) {
      throw const FormatException();
    }
    bool ref(Object? value) =>
        value is String && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(value);
    final id = p['requestId'],
        date = p['expectedBusinessDate'],
        revision = p['expectedRuleRevision'];
    final members = p['memberRefs'],
        size = p['partySize'],
        confirmation = p['staffConfirmation'];
    final parsed = date is String ? DateTime.tryParse(date) : null;
    if (!ref(p['storeRef']) ||
        !ref(p['tableId']) ||
        id is! String ||
        !uuidPattern.hasMatch(id) ||
        date is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        parsed == null ||
        parsed.toIso8601String().substring(0, 10) != date ||
        revision is! int ||
        revision < 0 ||
        revision > 4294967295 ||
        !{'prepay', 'postpay'}.contains(p['expectedPaymentTiming']) ||
        !{
          'manual',
          'minimum_people',
          'minimum_spend',
          'aa',
        }.contains(p['expectedRuleMode']) ||
        !p.containsKey('partySize') ||
        (size != null && (size is! int || size < 1 || size > 65535)) ||
        members is! List ||
        members.length > 1000 ||
        members.any((m) => !ref(m)) ||
        members.toSet().length != members.length ||
        p['manualOverride'] != false ||
        confirmation is! Map ||
        confirmation.length != 2 ||
        confirmation['arrivalConfirmed'] != true ||
        confirmation['reservationChecked'] != true) {
      throw const FormatException();
    }
    final selected = p['selectedRule'];
    if (p.containsKey('selectedRule')) {
      if (selected is! Map<String, dynamic>) throw const FormatException();
      final mode = selected['mode'];
      final field = mode == 'minimum_people'
          ? 'minimumPeople'
          : mode == 'minimum_spend'
          ? 'minimumSpendCents'
          : null;
      if (!{'manual', 'aa', 'minimum_people', 'minimum_spend'}.contains(mode) ||
          selected.length != (field == null ? 1 : 2) ||
          (field != null &&
              (selected[field] is! int || (selected[field] as int) <= 0))) {
        throw const FormatException();
      }
    }
    return PendingOpening._(
      base as String,
      employee,
      device,
      Map.unmodifiable({
        ...p,
        'memberRefs': List<String>.unmodifiable(members),
        'staffConfirmation': const {
          'arrivalConfirmed': true,
          'reservationChecked': true,
        },
      }),
    );
  }
}

/// One encrypted envelope, serialised across instances in the application isolate.
/// Unknown/corrupt records are never silently discarded. Not a cross-process database.
class OpeningJournal {
  OpeningJournal({SecretStorage? storage})
    : _storage = storage ?? PlatformSecretStorage();
  final SecretStorage _storage;
  static const storageKey = 'pending_table_openings_v1';
  static Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) async {
      try {
        return await operation();
      } on CcsopFailure {
        rethrow;
      } catch (_) {
        throw const CcsopFailure('OPENING_JOURNAL_UNAVAILABLE');
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<List<PendingOpening>> _read() async {
    final encoded = await _storage.read(storageKey);
    if (encoded == null) return [];
    if (encoded.length > 8000000) throw const FormatException();
    final value = jsonDecode(encoded);
    if (value is! Map ||
        value.length != 2 ||
        value['version'] != 1 ||
        value['entries'] is! List ||
        (value['entries'] as List).length > 100) {
      throw const FormatException();
    }
    final entries = (value['entries'] as List)
        .map(PendingOpening._decode)
        .toList();
    final identities = entries
        .map((e) => jsonEncode([e.base, e.storeRef, e.tableId]))
        .toSet();
    if (identities.length != entries.length ||
        entries.map((e) => e.requestId).toSet().length != entries.length) {
      throw const FormatException();
    }
    return entries;
  }

  Future<void> _write(List<PendingOpening> entries) async {
    final encoded = jsonEncode({
      'version': 1,
      'entries': entries.map((e) => e._encode()).toList(),
    });
    await _storage.write(storageKey, encoded);
    if (await _storage.read(storageKey) != encoded) {
      throw const CcsopFailure('OPENING_JOURNAL_UNAVAILABLE');
    }
  }

  Future<List<PendingOpening>> load(StaffSession session) => _serial(
    () async =>
        List.unmodifiable((await _read()).where((e) => e.belongsTo(session))),
  );

  /// Must finish before sending a command. Never overwrites another unresolved request for the table.
  Future<void> save(PendingOpening pending, StaffSession session) =>
      _serial(() async {
        if (!pending.belongsTo(session)) {
          throw const CcsopFailure('OPENING_SCOPE_CHANGED');
        }
        final entries = await _read();
        for (final old in entries) {
          if (old.base == pending.base &&
              old.storeRef == pending.storeRef &&
              old.tableId == pending.tableId) {
            if (jsonEncode(old._encode()) == jsonEncode(pending._encode())) {
              return;
            }
            throw const CcsopFailure('OPENING_ALREADY_PENDING');
          }
        }
        if (entries.length >= 100 ||
            entries.any((e) => e.requestId == pending.requestId)) {
          throw const CcsopFailure('OPENING_JOURNAL_FULL');
        }
        await _write([...entries, pending]);
      });

  /// Remove only a matching server-confirmed receipt or permanent cancellation.
  Future<void> acknowledge(StaffSession session, OpeningLookup lookup) =>
      _serial(() async {
        if (lookup.state == OpeningLookupState.notObserved) {
          throw const CcsopFailure('OPENING_RESULT_UNCONFIRMED');
        }
        final entries = await _read();
        final matches = entries
            .where((e) => e.requestId == lookup.requestId)
            .toList();
        if (matches.isEmpty) return;
        final pending = matches.single;
        if (!pending.belongsTo(session) ||
            lookup.storeRef != pending.storeRef ||
            lookup.tableId != pending.tableId) {
          throw const CcsopFailure('OPENING_RECEIPT_MISMATCH');
        }
        if (lookup.state == OpeningLookupState.cancelled) {
          await _write(
            entries.where((e) => e.requestId != lookup.requestId).toList(),
          );
          return;
        }
        final receipt = lookup.receipt!;
        final expectedMembers = List<String>.of(
          pending._params['memberRefs'] as List<String>,
        )..sort();
        final actualMembers = List<String>.of(receipt.memberRefs)..sort();
        if (!pending.belongsTo(session) ||
            receipt.storeRef != pending.storeRef ||
            receipt.tableId != pending.tableId ||
            receipt.businessDate != pending._params['expectedBusinessDate'] ||
            receipt.paymentTiming != pending._params['expectedPaymentTiming'] ||
            jsonEncode(expectedMembers) != jsonEncode(actualMembers)) {
          throw const CcsopFailure('OPENING_RECEIPT_MISMATCH');
        }
        await _write(
          entries.where((e) => e.requestId != lookup.requestId).toList(),
        );
      });
}
