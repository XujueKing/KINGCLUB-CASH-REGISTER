import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/product_image_store.dart';

void main() {
  test('disk survives new instance, rotated signatures do not download, changed ID does', () async {
    final dir = await Directory.systemTemp.createTemp(
      'king-product-images-test',
    );
    addTearDown(() => dir.delete(recursive: true));
    var calls = 0;
    final png = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10, 1, 2]);
    ProductImageStore store() => ProductImageStore(
      directory: () async => dir,
      download: (_) async {
        calls++;
        return png;
      },
    );
    final first = store();
    await Future.wait([
      first.read(Uri.parse('https://test.invalid/attachments/one?token=a')),
      first.read(Uri.parse('https://test.invalid/attachments/one?token=b')),
    ]);
    expect(calls, 1);
    expect(
      await store().read(
        Uri.parse('https://test.invalid/attachments/one?token=c'),
      ),
      png,
    );
    expect(calls, 1);
    await store().read(
      Uri.parse('https://test.invalid/attachments/two?token=c'),
    );
    expect(calls, 2);
    await store().read(
      Uri.parse('https://other.invalid/attachments/one?token=c'),
    );
    expect(calls, 3);
    for (final file in await dir.list().toList()) {
      await (file as File).writeAsString('corrupted');
    }
    await store().read(
      Uri.parse('https://test.invalid/attachments/one?token=c'),
    );
    expect(calls, 4);
  });
}
