import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/models.dart';
import 'package:kingclub_cash_register/src/service_probe.dart';
import 'package:kingclub_cash_register/src/strings.dart';

void main() {
  test('Live mode contains no fixtures and cannot create drafts', () {
    final model = Workbench();
    model.select('T01');
    model.add(previewProducts.first, previewProducts.first.variants.first);
    expect(model.desks, isEmpty);
    expect(model.products, isEmpty);
    expect(model.cart, isEmpty);
    expect(model.selectedDesk, isNull);
  });
  test('Different variants and tables retain isolated integer totals', () {
    final model = Workbench(preview: true)..select('T01');
    final product = previewProducts.first;
    model.add(product, product.variants.first);
    model.add(product, product.variants.last);
    expect(model.cart.length, 2);
    expect(model.total, 14000);
    model.saveNote('draft one');
    model.select('T02');
    expect(model.total, 0);
    expect(model.note, '');
    model.select('T01');
    expect(model.total, 14000);
    expect(model.note, 'draft one');
    model.change(model.cart.first.key, -1);
    expect(model.total, 11800);
    model.clear();
    expect(model.cart, isEmpty);
    expect(model.note, '');
  });
  test('Quantity capped, sold out/foreign variants/cleaning rejected', () {
    final model = Workbench(preview: true)..select('T01');
    final product = previewProducts.first;
    for (var i = 0; i < 110; i++) {
      model.add(product, product.variants.first);
    }
    expect(model.cart.single.quantity, 99);
    model.change(model.cart.single.key, 1);
    expect(model.cart.single.quantity, 99);
    model.change(model.cart.single.key, -99);
    expect(model.cart.single.quantity, 99);
    final unavailable = previewProducts.firstWhere((p) => !p.available);
    model.add(unavailable, unavailable.variants.first);
    model.add(product, const Variant('fake', 'bottle', 1));
    expect(model.cart.length, 1);
    model.select('T06');
    model.add(product, product.variants.first);
    expect(model.cart, isEmpty);
    expect(model.canDraft, false);
  });
  test('Leaving preview destroys all sample state', () {
    final model = Workbench(preview: true)..select('T01');
    model.add(previewProducts.first, previewProducts.first.variants.first);
    model.saveNote('demo');
    model.setPreview(false);
    expect(model.desks, isEmpty);
    expect(model.cart, isEmpty);
    model.setPreview(true);
    model.select('T01');
    expect(model.cart, isEmpty);
    expect(model.note, '');
  });
  test('Readiness URLs reject unsafe schemes and credential/query leaks', () {
    for (final url in [
      '',
      'http://example.com',
      'https://u:p@example.com',
      'https://example.com?token=secret',
      'https://example.com/#x',
      'file:///tmp',
    ]) {
      expect(readinessUri(url), isNull, reason: url);
    }
    expect(
      readinessUri(' https://example.com/commerce/ ')!.toString(),
      'https://example.com/commerce/ready',
    );
  });
  test('Every string provides four nonempty translations', () {
    for (final entry in copy.entries) {
      expect(entry.value.split('|').length, 4, reason: entry.key);
      for (final language in UiLanguage.values) {
        expect(tr(language, entry.key), isNotEmpty);
      }
    }
  });
}
