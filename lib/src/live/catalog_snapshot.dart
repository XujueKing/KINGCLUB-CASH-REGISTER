import 'product_thumbnail.dart';
import '../strings.dart';

Map<String, dynamic> _map(Object? v) {
  if (v is! Map<String, dynamic>) throw const FormatException();
  return v;
}

String _ref(Object? v) {
  if (v is! String || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(v)) {
    throw const FormatException();
  }
  return v;
}

int _number(Object? v, int min, int max) {
  if (v is! int || v < min || v > max) throw const FormatException();
  return v;
}

List<String> _words(Object? v) {
  final map = _map(v);
  return List.unmodifiable(
    ['zh-CN', 'en', 'zh-TW', 'th'].map((key) {
      final text = map[key];
      if (text is! String ||
          text.trim().isEmpty ||
          text.length > 128 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(text)) {
        throw const FormatException();
      }
      return text;
    }),
  );
}

class CatalogCategory {
  CatalogCategory(Map<String, dynamic> v)
    : reference = _ref(v['categoryRef']),
      names = _words(v['names']),
      sortOrder = _number(v['sortOrder'], 0, 1000000) {
    if (!{'liquor', 'drinks', 'snacks'}.contains(v['majorCategory'])) {
      throw const FormatException();
    }
  }
  final String reference;
  final List<String> names;
  final int sortOrder;
  String name(UiLanguage language) => names[language.index];
}

class CatalogProduct {
  CatalogProduct(Map<String, dynamic> v, {String? storeRef})
    : thumbnailPath = productThumbnail(v['bottleMaterial'], storeRef ?? ''),
      reference = _ref(v['productRef']),
      productGroupRef = v['productGroupRef'] == null
          ? null
          : _ref(v['productGroupRef']),
      categoryRef = _ref(v['categoryRef']),
      names = _words(v['names']),
      specifications = _words(v['specifications']),
      priceCents = _number(v['priceCents'], 1, 100000000),
      revision = _number(v['revision'], 1, 4294967295),
      sortOrder = _number(v['sortOrder'], 0, 1000000),
      available = _number(v['available'], 0, 9007199254740991),
      inventoryKnown = v['inventoryKnown'] == true {
    if (v['inventoryKnown'] is! bool ||
        v['soldOut'] is! bool ||
        v['soldOut'] != (available == 0) ||
        (!inventoryKnown && available != 0)) {
      throw const FormatException();
    }
  }
  final String reference, categoryRef;
  final String? productGroupRef;
  final String? thumbnailPath;
  final List<String> names, specifications;
  final int priceCents, revision, sortOrder, available;
  final bool inventoryKnown;
  String name(UiLanguage language) => names[language.index];
  String specification(UiLanguage language) => specifications[language.index];
}

/// A page is an observation, not a price lock or inventory reservation.
class CatalogSnapshot {
  CatalogSnapshot._(
    this.categories,
    this.products,
    this.currency,
    this.observedAt,
    this.nextAfterProduct,
  );
  final List<CatalogCategory> categories;
  final List<CatalogProduct> products;
  final String currency;
  final DateTime observedAt;
  final String? nextAfterProduct;

  factory CatalogSnapshot.parse(
    Object? raw, {
    required String storeRef,
    String? categoryRef,
    String? afterProduct,
  }) {
    final v = _map(_map(raw)['result']);
    if (v['storeRef'] != storeRef ||
        v['currency'] is! String ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(v['currency'] as String)) {
      throw const FormatException();
    }
    final categories = List<CatalogCategory>.unmodifiable(
      (v['categories'] as List).map((e) => CatalogCategory(_map(e))),
    );
    final refs = categories.map((e) => e.reference).toSet();
    final products = List<CatalogProduct>.unmodifiable(
      (v['products'] as List).map(
        (e) => CatalogProduct(_map(e), storeRef: storeRef),
      ),
    );
    if (categories.length > 100 ||
        refs.length != categories.length ||
        products.length > 50 ||
        (categoryRef != null && !refs.contains(categoryRef))) {
      throw const FormatException();
    }
    var previous = afterProduct ?? '';
    for (final product in products) {
      if (product.reference.compareTo(previous) <= 0 ||
          !refs.contains(product.categoryRef) ||
          (categoryRef != null && product.categoryRef != categoryRef)) {
        throw const FormatException();
      }
      previous = product.reference;
    }
    if (!v.containsKey('nextAfterProduct')) throw const FormatException();
    final next = v['nextAfterProduct'] == null
        ? null
        : _ref(v['nextAfterProduct']);
    if (next != null &&
        (products.length != 50 || next != products.last.reference)) {
      throw const FormatException();
    }
    final time = v['observedAt'];
    if (time is! String ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')
            .hasMatch(time)) {
      throw const FormatException();
    }
    final observed = DateTime.parse(time);
    if (observed.toIso8601String() != time) throw const FormatException();
    return CatalogSnapshot._(
      categories,
      products,
      v['currency'] as String,
      observed,
      next,
    );
  }
}
