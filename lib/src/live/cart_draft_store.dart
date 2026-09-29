import 'dart:convert';

import '../auth/session_vault.dart';
import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import 'cart_draft.dart';

/// Separate from the immutable submitted-order journal. No network or auto purge.
class CartDraftStore {
  CartDraftStore({SecretStorage? storage})
    : _storage = storage ?? PlatformSecretStorage();
  final SecretStorage _storage;
  static const storageKey = 'staff_cart_drafts_v1';
  static Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) async {
      try {
        return await operation();
      } on CcsopFailure {
        rethrow;
      } catch (_) {
        throw const CcsopFailure('CART_DRAFT_STORAGE_UNAVAILABLE');
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<List<CartDraft>> _read() async {
    final raw = await _storage.read(storageKey);
    if (raw == null) return [];
    if (raw.length > 1000000) throw const FormatException();
    final data = jsonDecode(raw);
    if (data is! Map ||
        data.length != 2 ||
        data['version'] != 1 ||
        data['entries'] is! List ||
        (data['entries'] as List).length > 100) {
      throw const FormatException();
    }
    final entries = (data['entries'] as List).map(CartDraft.decode).toList();
    if (entries.map((e) => e.slot).toSet().length != entries.length) {
      throw const FormatException();
    }
    return entries;
  }

  Future<void> _write(List<CartDraft> entries) async {
    final raw = jsonEncode({
      'version': 1,
      'entries': entries.map((e) => e.encode()).toList(),
    });
    if (entries.length > 100 || raw.length > 1000000) {
      throw const CcsopFailure('CART_DRAFT_STORAGE_FULL');
    }
    await _storage.write(storageKey, raw);
    if (await _storage.read(storageKey) != raw) {
      throw const CcsopFailure('CART_DRAFT_STORAGE_UNAVAILABLE');
    }
  }

  Future<List<CartDraft>> load(StaffSession identity) => _serial(
    () async =>
        List.unmodifiable((await _read()).where((e) => e.belongsTo(identity))),
  );

  /// Explicit compare-and-swap: null means the caller observed an empty slot.
  /// A delayed edit cannot overwrite a newer draft, even when content is equal.
  Future<void> save(
    CartDraft draft,
    StaffSession identity, {
    required CartDraft? previous,
  }) => _serial(() async {
    if (!draft.belongsTo(identity) ||
        (previous != null &&
            (!previous.belongsTo(identity) || previous.slot != draft.slot))) {
      throw const CcsopFailure('CART_DRAFT_CONTEXT_CHANGED');
    }
    final entries = await _read();
    final matches = entries.where((e) => e.slot == draft.slot).toList();
    final current = matches.isEmpty ? null : matches.single;
    if (current?.signature != previous?.signature) {
      throw const CcsopFailure('CART_DRAFT_EDIT_CONFLICT');
    }
    await _write([...entries.where((e) => e.slot != draft.slot), draft]);
  });

  /// For explicit discard or a durable handoff to OrderJournal, never a receipt.
  /// A caller must not send an order while its reusable draft remains on disk.
  Future<void> remove(CartDraft draft, StaffSession identity) =>
      _serial(() async {
        if (!draft.belongsTo(identity)) {
          throw const CcsopFailure('CART_DRAFT_CONTEXT_CHANGED');
        }
        final entries = await _read();
        final matches = entries.where((e) => e.slot == draft.slot).toList();
        if (matches.isEmpty) return;
        if (matches.single.signature != draft.signature) {
          throw const CcsopFailure('CART_DRAFT_EDIT_CONFLICT');
        }
        await _write(entries.where((e) => e.slot != draft.slot).toList());
      });
}
