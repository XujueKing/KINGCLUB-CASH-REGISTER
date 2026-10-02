/// Short-lived display snapshots, never mutation or payment authorization.
/// Weak identity keys prevent sharing data between staff sessions or stores.
class WorkspaceReadCache {
  static final _sessions =
      Expando<Map<String, ({DateTime at, Object value})>>();
  static T? read<T>(Object? identity, String key) {
    if (identity == null) return null;
    final entry = _sessions[identity]?[key];
    if (entry == null ||
        DateTime.now().difference(entry.at) > const Duration(seconds: 30)) {
      return null;
    }
    return entry.value is T ? entry.value as T : null;
  }

  static void put(Object? identity, String key, Object value) {
    if (identity == null) return;
    final entries = _sessions[identity] ??= {};
    entries.remove(key);
    if (entries.length >= 24) entries.remove(entries.keys.first);
    entries[key] = (at: DateTime.now(), value: value);
  }
}
