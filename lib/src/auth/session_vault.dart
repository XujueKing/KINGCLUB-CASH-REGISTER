import 'dart:async';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../network/ccsop_client.dart';
import 'staff_session.dart';

abstract interface class SecretStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PlatformSecretStorage implements SecretStorage {
  static const options = AndroidOptions(
    storageNamespace: 'kingclub_cashier_auth_v1',
    resetOnError: false,
    migrateOnAlgorithmChange: false,
    migrateWithBackup: false,
  );
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: options,
  );
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Serializes storage operations so a late login save cannot overtake logout deletion.
class SessionVault {
  SessionVault({SecretStorage? storage})
    : _storage = storage ?? PlatformSecretStorage();
  final SecretStorage _storage;
  Future<void> _tail = Future.value();
  static const sessionKey = 'employee_session_v1',
      deviceKey = 'installation_id_v1';

  Future<T> _serial<T>(Future<T> Function() operation) {
    final next = _tail.then((_) async {
      try {
        return await operation();
      } on CcsopFailure {
        rethrow;
      } catch (_) {
        throw const CcsopFailure('SECURE_STORAGE_FAILED');
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<String> deviceId() => _serial(() async {
    final existing = await _storage.read(deviceKey);
    if (existing != null) {
      if (!uuidPattern.hasMatch(existing)) {
        throw const CcsopFailure('DEVICE_ID_INVALID');
      }
      return existing;
    }
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    // OS-backed randomness; UUID identifies the installation, not hardware trust.
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    await _storage.write(deviceKey, id);
    return id;
  });

  Future<StaffSession?> load({DateTime? now}) => _serial(() async {
    final encoded = await _storage.read(sessionKey);
    if (encoded == null) return null;
    try {
      return StaffSession.fromSecureStorage(encoded, now: now);
    } on CcsopFailure {
      await _storage.delete(sessionKey);
      return null;
    }
  });

  Future<bool> saveIfCurrent(StaffSession session, bool Function() isCurrent) =>
      _serial(() async {
        if (!isCurrent()) return false;
        await _storage.write(sessionKey, session.encodeForSecureStorage());
        if (!isCurrent()) {
          await _storage.delete(sessionKey);
          return false;
        }
        return true;
      });
  Future<void> clear() => _serial(() => _storage.delete(sessionKey));
}
