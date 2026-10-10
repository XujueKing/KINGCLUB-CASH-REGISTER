import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Display-only supplier pages, isolated by store, employee and permission scope.
class SupplierCatalogPageCache {
  static final _memory = <String, Map<String, dynamic>>{};
  static const _storage = FlutterSecureStorage();
  static String key(String scope, int offset, String category, String search) =>
      'supplier-page-v1:${jsonEncode([scope, offset, category, search])}';
  static Map<String, dynamic>? peek(String key) => _memory[key];
  static Future<Map<String, dynamic>?> read(String key) async {
    if (_memory[key] != null) return _memory[key];
    try {
      final raw = await _storage.read(key: key);
      if (raw == null || raw.length > 128 * 1024) return null;
      final page = jsonDecode(raw);
      if (page is! Map<String, dynamic> || page['catalog'] is! Map) return null;
      _remember(key, page);
      return page;
    } catch (_) {
      return null;
    }
  }

  static void _remember(String key, Map<String, dynamic> page) {
    _memory.remove(key);
    _memory[key] = page;
    while (_memory.length > 64) {
      _memory.remove(_memory.keys.first);
    }
  }

  static Future<void> write(String key, Map<String, dynamic> page) async {
    _remember(key, page);
    final raw = jsonEncode(page);
    if (raw.length > 128 * 1024) return;
    try {
      await _storage.write(key: key, value: raw);
    } catch (_) {}
  }
}
