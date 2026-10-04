import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/product_thumbnail.dart';

void main() {
  test('rotating signatures reuse the image cache but different assets stay separate', () {
    final first = ProductNetworkImage(
      'https://service.invalid/attachments/a?token=first',
    );
    final second = ProductNetworkImage(
      'https://service.invalid/attachments/a?token=second',
    );
    expect(first, second);
    expect(first.hashCode, second.hashCode);
    expect(
      first,
      isNot(
        ProductNetworkImage(
          'https://service.invalid/attachments/b?token=second',
        ),
      ),
    );
    expect(
      first,
      isNot(
        ProductNetworkImage('https://other.invalid/attachments/a?token=second'),
      ),
    );
  });
  test('thumbnail retains the business gateway prefix', () {
    expect(
      productThumbnailUri(
        Uri.parse('https://service.invalid'),
        '/attachments/id?token=test',
      ).path,
      '/kingclub-v2/attachments/id',
    );
    expect(
      productThumbnailUri(
        Uri.parse('https://service.invalid/custom/'),
        '/attachments/id?token=test',
      ).toString(),
      'https://service.invalid/custom/attachments/id?token=test',
    );
  });
  const path = '/attachments/00000000-0000-4000-8000-000000000001?token=test';
  Map<String, Object> material(String store, String link) => {
    'storeRef': store,
    'version': 'png-contour-v1',
    'files': {'thumbnail': link},
  };
  test('uses the APP thumbnail only for the current store and service', () {
    expect(productThumbnail({...material('store', path), 'files': {
      'thumbnail': path,
      'image': '/attachments/00000000-0000-4000-8000-000000000002?token=original',
    }}, 'store'), path);
    expect(productThumbnail(material('store', path), 'store'), path);
    expect(productThumbnail(material('other', path), 'store'), isNull);
    expect(
      productThumbnail(
        material('store', 'https://other.invalid$path'),
        'store',
      ),
      isNull,
    );
    expect(
      productThumbnail(material('store', '//other.invalid$path'), 'store'),
      isNull,
    );
    expect(
      productThumbnail(material('store', '$path&token=second'), 'store'),
      isNull,
    );
    expect(productThumbnail(null, 'store'), isNull);
  });
}
