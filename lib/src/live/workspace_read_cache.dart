/// Short-lived display snapshots, never mutation or payment authorization.
/// Weak identity keys prevent sharing data between staff sessions or stores.
class WorkspaceReadCache {
  static final _sessions =
      Expando<Map<String, ({DateTime at, Object value})>>();
  static final _reads = Expando<Map<String, Future<Object?>>>();

  /// Share concurrent read-only requests. Completed calls are not reused as authority.
  static Future<T> readOnce<T>(
    Object identity,
    String key,
    Future<T> Function() read,
  ) {
    final pending = _reads[identity] ??= {};
    final existing = pending[key];
    if (existing != null) return existing.then((value) => value as T);
    late final Future<T> request;
    request = Future<T>.sync(read).whenComplete(() {
      if (identical(pending[key], request)) pending.remove(key);
    });
    pending[key] = request;
    return request;
  }

  static T? read<T>(
    Object? identity,
    String key, {
    Duration maxAge = const Duration(seconds: 30),
  }) {
    if (identity == null) return null;
    final entry = _sessions[identity]?[key];
    if (entry == null || DateTime.now().difference(entry.at) > maxAge) {
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
