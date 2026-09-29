import 'dart:convert';
import 'dart:io';

Uri? readinessUri(String raw) {
  final u = Uri.tryParse(raw.trim());
  if (u == null ||
      u.scheme != 'https' ||
      u.host.isEmpty ||
      u.userInfo.isNotEmpty ||
      u.hasQuery ||
      u.hasFragment) {
    return null;
  }
  return u.replace(path: '${u.path.replaceFirst(RegExp(r'/+$'), '')}/ready');
}

Future<bool> probeService(Uri uri) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  try {
    return await (() async {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode != 200) return false;
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 32768) return false;
        bytes.addAll(chunk);
      }
      final body = jsonDecode(utf8.decode(bytes));
      return body is Map &&
          body['status'] == 1 &&
          body['data'] is Map &&
          body['data']['ready'] == true;
    })().timeout(const Duration(seconds: 8));
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}
