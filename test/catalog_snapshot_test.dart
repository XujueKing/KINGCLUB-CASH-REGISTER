import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/auth/session_vault.dart';
import 'package:kingclub_cash_register/src/auth/staff_auth_controller.dart';
import 'package:kingclub_cash_register/src/live/catalog_snapshot.dart';
import 'package:kingclub_cash_register/src/live/live_catalog_panel.dart';
import 'package:kingclub_cash_register/src/network/ccsop_client.dart';
import 'package:kingclub_cash_register/src/strings.dart';

import 'staff_session_test.dart' as a;

Map<String, String> words(String value) => {
  'zh-CN': value,
  'en': value,
  'zh-TW': value,
  'th': value,
};
Map<String, dynamic> product([String ref = 'p001']) => {
  'productRef': ref,
  'categoryRef': 'c1',
  'names': words('TEST product'),
  'specifications': words('TEST size'),
  'priceCents': 1234,
  'revision': 1,
  'sortOrder': 0,
  'inventoryKnown': false,
  'available': 0,
  'soldOut': true,
};
Map<String, dynamic> catalog() => {
  'storeRef': 'test-store',
  'currency': 'CNY',
  'observedAt': '2026-09-29T00:00:00.000Z',
  'categories': [
    {
      'categoryRef': 'c1',
      'majorCategory': 'drinks',
      'names': words('TEST category'),
      'sortOrder': 0,
    },
  ],
  'products': [product()],
  'nextAfterProduct': null,
};
CatalogSnapshot parse(
  Map<String, dynamic> value, {
  String? categoryRef,
  String? afterProduct,
}) => CatalogSnapshot.parse(
  {'result': value},
  storeRef: 'test-store',
  categoryRef: categoryRef,
  afterProduct: afterProduct,
);

class Api extends a.TestApi {
  String? id;
  @override
  Future<Object?> call(String id, Map<String, dynamic> params) {
    this.id = id;
    return super.call(id, params);
  }
}

a.TestAuth loginChannel() => a.TestAuth()
  ..result = {
    ...a.response(),
    'permissions': ['workbench.read', 'orders.create'],
  };

class ViewAuth extends StaffAuthController {
  String? filter, cursor;
  bool fail = false;
  Map<String, dynamic>? reply;
  @override
  Future<CatalogSnapshot> readCatalog({
    String? categoryRef,
    String? afterProduct,
  }) async {
    filter = categoryRef;
    cursor = afterProduct;
    if (fail) throw const CcsopFailure('TEST_FAILURE');
    return parse(
      reply ?? catalog(),
      categoryRef: categoryRef,
      afterProduct: afterProduct,
    );
  }
}

void main() {
  testWidgets('prepay allows selection with unknown stock; postpay blocks it', (
    tester,
  ) async {
    final auth = ViewAuth();
    addTearDown(auth.dispose);
    var selections = 0;
    for (final timing in ['postpay', 'prepay']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveCatalogPanel(
              auth: auth,
              language: UiLanguage.values.first,
              onBack: () {},
              paymentTiming: timing,
              onSelect: (_) => selections++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('catalog-add-p001'));
      expect(
        tester.widget<IconButton>(button).onPressed,
        timing == 'prepay' ? isNotNull : isNull,
      );
      final card = find.byKey(const ValueKey('catalog-select-p001'));
      expect(
        tester.widget<InkWell>(card).onTap,
        timing == 'prepay' ? isNotNull : isNull,
      );
      await tester.tap(card);
      if (timing == 'prepay') {
        expect(selections, 1);
        await tester.tap(button);
        expect(
          selections,
          2,
          reason: 'the plus button must not bubble to the card',
        );
      } else {
        expect(selections, 0);
      }
    }
    expect(selections, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'compact catalog fits fifteen products and respects stock in four languages',
    (tester) async {
      tester.view.physicalSize = const Size(1274, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = ViewAuth()
        ..reply = {
          ...catalog(),
          'products': List.generate(
            15,
            (i) => {
              ...product('p${i.toString().padLeft(3, '0')}'),
              'names': words(
                'Long product name for the available catalog item',
              ),
              'inventoryKnown': i != 0,
              'available': i > 1 ? 3 : 0,
              'soldOut': i <= 1,
            },
          ),
        };
      String? selected;
      for (final language in UiLanguage.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LiveCatalogPanel(
                auth: auth,
                language: language,
                onBack: () {},
                onSelect: (p) => selected = p.reference,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final last = tester.getRect(
          find.byKey(const ValueKey('catalog-product-p014')),
        );
        expect(last.bottom, lessThan(670));
        expect(
          tester
              .getRect(find.byKey(const ValueKey('catalog-product-p000')))
              .top,
          lessThanOrEqualTo(120),
        );
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('catalog-add-p000')),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<IconButton>(
                find.byKey(const ValueKey('catalog-add-p001')),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.byKey(const ValueKey('catalog-add-p002')));
        expect(selected, 'p002');
        expect(tester.takeException(), isNull);
      }
      tester.view.physicalSize = const Size(560, 600);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
            child: Scaffold(
              body: LiveCatalogPanel(
                auth: auth,
                language: UiLanguage.th,
                onBack: () {},
                onSelect: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
  test('four languages, unknown inventory and immutable observations', () {
    final value = parse(catalog());
    expect(value.products.single.inventoryKnown, false);
    expect(value.products.single.priceCents, 1234);
    for (final lang in UiLanguage.values) {
      expect(value.products.single.name(lang), 'TEST product');
    }
    expect(() => value.products.clear(), throwsUnsupportedError);
    expect(() => value.products.single.names.clear(), throwsUnsupportedError);
  });
  test('reject malformed scope, timestamps, currency and categories', () {
    for (final patch in <Map<String, dynamic>>[
      {'storeRef': 'wrong'},
      {'currency': 'cny'},
      {'observedAt': '2026-02-30T00:00:00.000Z'},
      {'categories': []},
      {'nextAfterProduct': 'p001'},
      {
        'categories': [
          ...catalog()['categories'] as List,
          ...catalog()['categories'] as List,
        ],
      },
    ]) {
      expect(() => parse({...catalog(), ...patch}), throwsA(anything));
    }
  });
  test(
    'reject invalid inventory, price, revision, translations and category',
    () {
      for (final patch in <Map<String, dynamic>>[
        {'available': -1},
        {'available': 1},
        {'inventoryKnown': 'true'},
        {'soldOut': false},
        {'priceCents': 0},
        {'priceCents': 1.5},
        {'revision': 0},
        {'categoryRef': 'other'},
        {
          'names': {'en': 'Only English'},
        },
        {'names': words('bad\ntext')},
      ]) {
        expect(
          () => parse({
            ...catalog(),
            'products': [
              {...product(), ...patch},
            ],
          }),
          throwsA(anything),
        );
      }
    },
  );
  test(
    'strict advancing cursor, exact full page continuation, filter binding',
    () {
      final products = List.generate(
        50,
        (i) => product('p${i.toString().padLeft(3, '0')}'),
      );
      expect(
        parse({...catalog(), 'products': products, 'nextAfterProduct': 'p049'})
            .nextAfterProduct,
        'p049',
      );
      expect(
        () => parse(catalog(), afterProduct: 'p001'),
        throwsFormatException,
      );
      expect(
        () => parse(catalog(), categoryRef: 'missing'),
        throwsFormatException,
      );
      expect(
        () => parse({
          ...catalog(),
          'products': [product(), product()],
        }),
        throwsFormatException,
      );
      expect(
        () => parse({
          ...catalog(),
          'products': products,
          'nextAfterProduct': 'p050',
        }),
        throwsFormatException,
      );
    },
  );
  test('authorized read binds store, filter and cursor to 1910', () async {
    final api = Api()..pendingRead = Completer<Object?>();
    final controller = a.controller(a.TestStorage(), loginChannel(), api);
    await a.login(controller);
    final pending = controller.readCatalog(
      categoryRef: 'c1',
      afterProduct: 'p000',
    );
    expect(api.id, 'K260929001910');
    expect(api.params, {
      'storeRef': 'test-store',
      'categoryRef': 'c1',
      'afterProduct': 'p000',
    });
    api.pendingRead!.complete({'result': catalog()});
    expect((await pending).products.length, 1);
    controller.dispose();
  });
  test('missing permission makes no call', () async {
    final api = Api();
    final controller = a.controller(a.TestStorage(), a.TestAuth(), api);
    await a.login(controller);
    await expectLater(controller.readCatalog(), throwsA(isA<CcsopFailure>()));
    expect(api.id, isNull);
    controller.dispose();
  });
  test('logout or expiry discards late catalog replies', () async {
    for (final logout in [true, false]) {
      var now = a.now;
      final api = Api()..pendingRead = Completer<Object?>();
      final controller = StaffAuthController(
        vault: SessionVault(storage: a.TestStorage()),
        authFactory: (_) => loginChannel(),
        sessionFactory: (_) => api,
        now: () => now,
      );
      await a.login(controller);
      final pending = controller.readCatalog();
      final rejected = expectLater(pending, throwsA(isA<CcsopFailure>()));
      if (logout) {
        await controller.logout();
      } else {
        now = now.add(const Duration(minutes: 16));
      }
      api.pendingRead!.complete({'result': catalog()});
      await rejected;
      controller.dispose();
    }
  });
  testWidgets(
    'landscape four-language catalog filters, hides stale data on failure',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = ViewAuth();
      for (final language in UiLanguage.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LiveCatalogPanel(
                auth: auth,
                language: language,
                onBack: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(tr(language, 'catalogUnknown')), findsOneWidget);
        expect(find.text('CNY 12.34'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byKey(const ValueKey('catalog-category-c1')));
      await tester.pumpAndSettle();
      expect(auth.filter, 'c1');
      expect(auth.cursor, isNull);
      auth.fail = true;
      await tester.tap(find.byKey(const ValueKey('catalog-refresh')));
      await tester.pumpAndSettle();
      expect(find.text('TEST product'), findsNothing);
      expect(find.text(tr(UiLanguage.th, 'liveReadFailed')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      auth.dispose();
    },
  );
}
