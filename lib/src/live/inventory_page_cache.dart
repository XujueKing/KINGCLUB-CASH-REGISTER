import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypted, display-only stock data; current server permissions authorize actions.
class InventoryPageCache {
  const InventoryPageCache();
  static const _storage = FlutterSecureStorage();
  String _key(String scope) => 'inventory-display-v1:$scope';
  Future<Map<String, dynamic>?> read(String scope) async {
    try {
      final raw = await _storage.read(key: _key(scope));
      if (raw == null || raw.length > 1024 * 1024) return null;
      final result = jsonDecode(raw);
      return result is Map<String, dynamic> && result['products'] is List
          ? result
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String scope, Map<String, dynamic> page) async {
    final copy = {...page}
      ..remove('procurementProducts')
      ..remove('pendingStatus')
      ..remove('receipt');
    // Only a stock-page content hash is valid after removing procurement data.
    if (page['view'] != 'stock') copy.remove('version');
    copy['view'] = 'stock';
    final raw = jsonEncode(copy);
    if (raw.length > 1024 * 1024) return;
    try {
      await _storage.write(key: _key(scope), value: raw);
    } catch (_) {}
  }
}
