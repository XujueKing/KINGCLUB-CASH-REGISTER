import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

/// Immutable attachment IDs survive rotating download signatures and restarts.
class ProductImageStore {
  ProductImageStore({
    Future<Directory> Function()? directory,
    Future<Uint8List> Function(Uri)? download,
  }) : directory = directory ?? _directory,
       download = download ?? _download;
  static final shared = ProductImageStore();
  final Future<Directory> Function() directory;
  final Future<Uint8List> Function(Uri) download;
  final _pending = <String, Future<Uint8List>>{};
  static String key(Uri uri) => uri.replace(query: '', fragment: '').toString();
  static Future<Directory> _directory() async {
    final path = await const MethodChannel('cn.kingclub.cashier/product-images')
        .invokeMethod<String>('directory');
    if (path == null)
      throw const FileSystemException('Image directory unavailable');
    return Directory(path).create(recursive: true);
  }

  Future<File> _file(Uri uri) async {
    final hash = await Sha256().hash(utf8.encode(key(uri)));
    return File(
      '${(await directory()).path}/${hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}.png',
    );
  }

  Future<Uint8List> read(Uri uri) => _pending.putIfAbsent(key(uri), () async {
    try {
      return await _read(uri);
    } finally {
      _pending.remove(key(uri));
    }
  });
  Future<Uint8List> _read(Uri uri) async {
    File? file;
    try {
      file = await _file(uri);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (_png(bytes)) return bytes;
        await file.delete();
      }
    } on FileSystemException {
      /* Network still works if disk is unavailable. */
    } on MissingPluginException {
      /* Desktop/test hosts without the Android bridge. */
    }
    final bytes = await download(uri);
    if (!_png(bytes)) throw const FormatException('Invalid product image');
    if (file != null) {
      final temp = File('${file.path}.part');
      try {
        await temp.writeAsBytes(bytes, flush: true);
        await temp.rename(file.path);
      } on FileSystemException {
        /* Do not hide a downloaded image on disk failure. */
      }
    }
    return bytes;
  }

  Future<void> remove(Uri uri) async {
    try {
      final file = await _file(uri);
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      /* Already absent. */
    } on MissingPluginException {
      /* No persistent cache on this host. */
    }
  }

  static bool _png(Uint8List b) =>
      b.length > 8 &&
      b[0] == 137 &&
      b[1] == 80 &&
      b[2] == 78 &&
      b[3] == 71 &&
      b[4] == 13 &&
      b[5] == 10 &&
      b[6] == 26 &&
      b[7] == 10;
  static Future<Uint8List> _download(Uri uri) async {
    if (uri.scheme != 'https') throw const FormatException('HTTPS required');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if (response.statusCode != 200)
        throw HttpException('Product image unavailable');
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 20))) {
        bytes.add(chunk);
        if (bytes.length > 12 * 1024 * 1024)
          throw const FormatException('Image too large');
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }
}
