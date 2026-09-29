import 'package:flutter/foundation.dart';

enum TableStage { free, ordering, unpaid, cleaning }

class Desk {
  const Desk(
    this.id,
    this.area,
    this.stage,
    this.guests,
    this.minutes,
    this.cents,
  );
  final String id, area;
  final TableStage stage;
  final int guests, minutes, cents;
}

class Variant {
  const Variant(this.id, this.label, this.cents);
  final String id, label;
  final int cents;
}

class Product {
  const Product(
    this.id,
    this.label,
    this.category,
    this.variants, {
    this.available = true,
  });
  final String id, label, category;
  final List<Variant> variants;
  final bool available;
}

class CartLine {
  CartLine(this.product, this.variant, this.quantity);
  final Product product;
  final Variant variant;
  int quantity;
  String get key => '${product.id}:${variant.id}';
  int get cents => variant.cents * quantity;
}

// Fictional UI fixtures, never sent to a backend.
const previewDesks = [
  Desk('T01', 'hall', TableStage.ordering, 4, 18, 0),
  Desk('T02', 'hall', TableStage.unpaid, 2, 42, 14800),
  Desk('T03', 'hall', TableStage.free, 0, 0, 0),
  Desk('T04', 'hall', TableStage.ordering, 6, 25, 0),
  Desk('T05', 'hall', TableStage.free, 0, 0, 0),
  Desk('T06', 'hall', TableStage.cleaning, 0, 0, 0),
  Desk('T07', 'hall', TableStage.free, 0, 0, 0),
  Desk('T08', 'hall', TableStage.unpaid, 4, 65, 23600),
  Desk('B01', 'booth', TableStage.free, 0, 0, 0),
  Desk('B02', 'booth', TableStage.ordering, 5, 12, 0),
  Desk('B03', 'booth', TableStage.free, 0, 0, 0),
  Desk('B04', 'booth', TableStage.free, 0, 0, 0),
];
const previewProducts = [
  Product('p1', 'lager', 'beer', [
    Variant('one', 'bottle', 2200),
    Variant('six', 'six', 11800),
  ]),
  Product('p2', 'wheat', 'beer', [
    Variant('one', 'bottle', 2800),
    Variant('six', 'six', 14800),
  ]),
  Product('p3', 'ipa', 'beer', [Variant('one', 'bottle', 3600)]),
  Product('p4', 'whisky', 'spirits', [
    Variant('glass', 'glass', 5800),
    Variant('bottle', 'bottle', 39800),
  ]),
  Product('p5', 'gin', 'spirits', [Variant('glass', 'glass', 4800)]),
  Product('p6', 'soda', 'soft', [Variant('one', 'bottle', 1600)]),
  Product('p7', 'juice', 'soft', [Variant('one', 'glass', 2600)]),
  Product('p8', 'water', 'soft', [Variant('one', 'bottle', 1000)]),
  Product('p9', 'fries', 'snacks', [Variant('one', 'plate', 2800)]),
  Product('p10', 'nuts', 'snacks', [Variant('one', 'plate', 1800)]),
  Product('p11', 'fruit', 'snacks', [
    Variant('one', 'plate', 5800),
  ], available: false),
  Product('p12', 'sharing', 'sets', [Variant('one', 'set', 16800)]),
];
String money(int cents) => '¥${(cents / 100).toStringAsFixed(2)}';

class Workbench extends ChangeNotifier {
  Workbench({bool preview = false}) {
    _preview = preview;
  }
  late bool _preview;
  bool get preview => _preview;
  String? selectedDesk;
  final Map<String, List<CartLine>> _carts = {};
  final Map<String, String> _notes = {};
  List<Desk> get desks => preview ? previewDesks : const [];
  List<Product> get products => preview ? previewProducts : const [];
  List<CartLine> get cart =>
      List.unmodifiable(_carts[selectedDesk] ?? const []);
  String get note => _notes[selectedDesk] ?? '';
  int get total => cart.fold(0, (sum, line) => sum + line.cents);
  int get count => cart.fold(0, (sum, line) => sum + line.quantity);
  void setPreview(bool value) {
    _preview = value;
    selectedDesk = null;
    _carts.clear();
    _notes.clear();
    notifyListeners();
  }

  void select(String id) {
    if (!desks.any((d) => d.id == id)) return;
    selectedDesk = id;
    notifyListeners();
  }

  bool get canDraft =>
      preview &&
      selectedDesk != null &&
      desks.firstWhere((d) => d.id == selectedDesk).stage !=
          TableStage.cleaning;
  void add(Product product, Variant variant) {
    if (!canDraft ||
        !products.contains(product) ||
        !product.available ||
        !product.variants.contains(variant)) {
      return;
    }
    final lines = _carts.putIfAbsent(selectedDesk!, () => []);
    final index = lines.indexWhere(
      (l) => l.key == '${product.id}:${variant.id}',
    );
    if (index < 0) {
      lines.add(CartLine(product, variant, 1));
    } else if (lines[index].quantity < 99) {
      lines[index].quantity++;
    }
    notifyListeners();
  }

  void change(String key, int delta) {
    if (!canDraft || (delta != 1 && delta != -1)) return;
    final lines = _carts[selectedDesk];
    if (lines == null) return;
    final index = lines.indexWhere((l) => l.key == key);
    if (index < 0) return;
    final next = lines[index].quantity + delta;
    if (next < 1) {
      lines.removeAt(index);
    } else if (next <= 99) {
      lines[index].quantity = next;
    }
    notifyListeners();
  }

  void saveNote(String value) {
    if (!canDraft) return;
    _notes[selectedDesk!] = value;
    notifyListeners();
  }

  void clear() {
    _carts.remove(selectedDesk);
    _notes.remove(selectedDesk);
    notifyListeners();
  }
}
