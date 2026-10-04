import 'dart:convert';

import '../auth/session_vault.dart';

/// Transport state only. No state here asserts paper output or payment success.
class PrintAttempt {
  // One whole document, up to 32 bounded raster pages. No bitmap is persisted.
  static const maxDocumentBytes = 5000000;
  PrintAttempt._(
    this.id,
    this.contentHash,
    this.targetHash,
    this.byteCount,
    this.state,
    this.documentHash,
  );
  final String id, contentHash, targetHash, state;
  final int byteCount;
  final String? documentHash;
  bool get requiresReview => state == 'sending' || state == 'unknown';
  Map<String, dynamic> encode() => {
    'id': id,
    'contentHash': contentHash,
    'targetHash': targetHash,
    'byteCount': byteCount,
    'state': state,
    if (documentHash != null) 'documentHash': documentHash,
  };
  factory PrintAttempt.decode(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw.length != (raw.containsKey('documentHash') ? 6 : 5) ||
        (raw.containsKey('documentHash') &&
            (raw['documentHash'] is! String ||
                !RegExp(r'^[0-9a-f]{64}$')
                    .hasMatch(raw['documentHash'] as String))) ||
        raw['id'] is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(raw['id'] as String) ||
        raw['contentHash'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(raw['contentHash'] as String) ||
        raw['targetHash'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(raw['targetHash'] as String) ||
        raw['byteCount'] is! int ||
        (raw['byteCount'] as int) < 1 ||
        (raw['byteCount'] as int) > maxDocumentBytes ||
        !{
          'prepared',
          'sending',
          'transport_accepted',
          'unknown',
          'cancelled',
          'reviewed',
        }.contains(raw['state'])) {
      throw const FormatException('PRINT_ATTEMPT_INVALID');
    }
    return PrintAttempt._(
      raw['id'] as String,
      raw['contentHash'] as String,
      raw['targetHash'] as String,
      raw['byteCount'] as int,
      raw['state'] as String,
      raw['documentHash'] as String?,
    );
  }
}

/// No automatic retry, expiry purge, logout cleanup or plaintext fallback.
/// Hashes bind exact bytes and a current attachment selection, not permanent hardware identity.
class PrintAttemptJournal {
  PrintAttemptJournal({SecretStorage? storage})
    : _storage = storage ?? PlatformSecretStorage();
  final SecretStorage _storage;
  static const key = 'cashier_print_attempts_v1';
  static Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _tail.then((_) => work());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<List<PrintAttempt>> _read() async {
    final raw = await _storage.read(key);
    if (raw == null) return [];
    if (raw.length > 1000000) {
      throw const FormatException('PRINT_JOURNAL_INVALID');
    }
    final value = jsonDecode(raw);
    if (value is! Map ||
        value.length != 2 ||
        value['version'] != 1 ||
        value['entries'] is! List ||
        (value['entries'] as List).length > 1000) {
      throw const FormatException('PRINT_JOURNAL_INVALID');
    }
    final entries = (value['entries'] as List)
        .map(PrintAttempt.decode)
        .toList();
    if (entries.map((e) => e.id).toSet().length != entries.length) {
      throw const FormatException('PRINT_JOURNAL_INVALID');
    }
    return entries;
  }

  Future<void> _write(List<PrintAttempt> entries) async {
    final raw = jsonEncode({
      'version': 1,
      'entries': entries.map((e) => e.encode()).toList(),
    });
    if (raw.length > 1000000) throw const FormatException('PRINT_JOURNAL_FULL');
    await _storage.write(key, raw);
    if (await _storage.read(key) != raw) {
      throw const FormatException('PRINT_JOURNAL_READBACK_FAILED');
    }
  }

  Future<List<PrintAttempt>> load() =>
      _serial(() async => List.unmodifiable(await _read()));
  Future<void> prepare({
    required String id,
    required String contentHash,
    required String targetHash,
    required int byteCount,
    String? documentHash,
    bool confirmedReprint = false,
  }) => _serial(() async {
    final candidate = PrintAttempt.decode({
      'id': id,
      'contentHash': contentHash,
      'targetHash': targetHash,
      'byteCount': byteCount,
      'state': 'prepared',
      'documentHash': ?documentHash,
    });
    final entries = await _read();
    if (entries.any((e) => e.id == id)) {
      throw const FormatException('PRINT_ATTEMPT_EXISTS');
    }
    if (confirmedReprint && documentHash == null)
      throw const FormatException('PRINT_SCOPE_REQUIRED');
    if (confirmedReprint) {
      // Explicit operator reprint only: retain previous evidence as reviewed.
      for (var i = 0; i < entries.length; i++) {
        if (entries[i].documentHash == documentHash &&
            entries[i].requiresReview) {
          entries[i] = PrintAttempt.decode({
            ...entries[i].encode(),
            'state': 'reviewed',
          });
        }
      }
    }
    if (entries.any((e) => e.requiresReview)) {
      throw const FormatException('PRINT_REVIEW_REQUIRED');
    }
    if (!confirmedReprint &&
        documentHash != null &&
        entries.any(
          (e) => e.documentHash == documentHash && e.state != 'cancelled',
        )) {
      throw const FormatException('PRINT_DOCUMENT_ALREADY_ATTEMPTED');
    }
    if (entries.length >= 1000) {
      throw const FormatException('PRINT_JOURNAL_FULL');
    }
    await _write([...entries, candidate]);
  });

  /// Must finish successfully before invoking a transport. A failed readback
  /// leaves an uncertain durable state; the caller must not send any bytes.
  Future<void> beginSend(
    String id, {
    required String contentHash,
    required String targetHash,
    required bool confirmed,
  }) => _serial(() async {
    if (!confirmed) throw const FormatException('PRINT_CONFIRMATION_REQUIRED');
    final entries = await _read();
    final selected = entries.where((e) => e.id == id).toList();
    if (selected.length != 1 ||
        selected.single.state != 'prepared' ||
        selected.single.contentHash != contentHash ||
        selected.single.targetHash != targetHash ||
        entries.any((e) => e.requiresReview)) {
      throw const FormatException('PRINT_REVIEW_REQUIRED');
    }
    await _write(
      entries
          .map(
            (e) => e.id == id
                ? PrintAttempt.decode({...e.encode(), 'state': 'sending'})
                : e,
          )
          .toList(),
    );
  });
  Future<void> finish(
    String id, {
    required int? acceptedBytes,
  }) => _serial(() async {
    final entries = await _read();
    final selected = entries.where((e) => e.id == id).toList();
    if (selected.length != 1 || selected.single.state != 'sending') {
      throw const FormatException('PRINT_STATE_INVALID');
    }
    // Partial writes, exceptions and even zero accepted bytes are not proof of
    // no output: a native failure may have lost its progress response.
    final state = acceptedBytes == selected.single.byteCount
        ? 'transport_accepted'
        : 'unknown';
    await _write(
      entries
          .map(
            (e) => e.id == id
                ? PrintAttempt.decode({...e.encode(), 'state': state})
                : e,
          )
          .toList(),
    );
  });
  Future<void> cancelPrepared(String id) => _serial(() async {
    final entries = await _read();
    final selected = entries.where((e) => e.id == id).toList();
    if (selected.length != 1 || selected.single.state != 'prepared') {
      throw const FormatException('PRINT_STATE_INVALID');
    }
    await _write(
      entries
          .map(
            (e) => e.id == id
                ? PrintAttempt.decode({...e.encode(), 'state': 'cancelled'})
                : e,
          )
          .toList(),
    );
  });
}
