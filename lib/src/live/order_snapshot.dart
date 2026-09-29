import '../strings.dart';

Map<String, dynamic> _map(Object? value) {
  if (value is! Map<String, dynamic>) throw const FormatException();
  return value;
}

String _ref(Object? value) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(value)) {
    throw const FormatException();
  }
  return value;
}

int _positive(Object? value, [int max = 9007199254740991]) {
  if (value is! int || value < 1 || value > max) throw const FormatException();
  return value;
}

DateTime _time(Object? value) {
  if (value is! String ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$')
          .hasMatch(value)) {
    throw const FormatException();
  }
  final result = DateTime.parse(value);
  if (result.toIso8601String().substring(0, 19) != value.substring(0, 19)) {
    throw const FormatException();
  }
  return result;
}

List<String> _localized(Object? value) {
  final map = _map(value);
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

class OrderItem {
  OrderItem(Map<String, dynamic> value)
    : productRef = _ref(value['productRef']),
      quantity = _positive(value['quantity'], 1000),
      priceCents = _positive(value['priceCents'], 100000000),
      subtotalCents = _positive(value['subtotalCents']),
      names = _localized(_map(value['snapshot'])['names']),
      specifications = _localized(_map(value['snapshot'])['specifications']) {
    _positive(_map(value['snapshot'])['revision']);
    if (quantity * priceCents != subtotalCents) throw const FormatException();
  }
  final String productRef;
  final int quantity, priceCents, subtotalCents;
  final List<String> names, specifications;
  String name(UiLanguage language) => names[language.index];
  String specification(UiLanguage language) => specifications[language.index];
}

class LiveOrder {
  LiveOrder(Map<String, dynamic> value)
    : reference = _ref(value['orderRef']),
      cashierOrder = value.containsKey('cashierOrder')
          ? _cashierOrigin(value['cashierOrder'])
          : false,
      status = value['status'] as String,
      currency = value['currency'] as String,
      totalCents = _positive(value['totalCents']),
      createdAt = _time(value['createdAt']),
      items = List.unmodifiable(
        (value['items'] as List).map((item) => OrderItem(_map(item))),
      ) {
    if (!{'pending', 'paid', 'expired'}.contains(status) ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(currency) ||
        items.isEmpty ||
        items.length > 50 ||
        items.map((item) => item.productRef).toSet().length != items.length ||
        items.fold<int>(0, (sum, item) => sum + item.subtotalCents) !=
            totalCents) {
      throw const FormatException();
    }
  }
  final String reference, status, currency;
  final bool cashierOrder;
  final int totalCents;
  final DateTime createdAt;
  final List<OrderItem> items;
}

bool _cashierOrigin(Object? value) {
  if (value is! bool) throw const FormatException();
  return value;
}

class OrderSnapshot {
  OrderSnapshot._(
    this.orders,
    this.observedAt,
    this.nextAfterOrder,
    this.sessionStatus,
  );
  final List<LiveOrder> orders;
  final DateTime observedAt;
  final String? nextAfterOrder;
  final String sessionStatus;
  factory OrderSnapshot.parse(
    Object? raw, {
    required String storeRef,
    required String tableRef,
    required String sessionRef,
    String? afterOrder,
  }) {
    final data = _map(_map(raw)['result']),
        session = _map(_map(_map(raw)['result'])['session']);
    if (data['storeRef'] != storeRef ||
        data['tableRef'] != tableRef ||
        session['sessionRef'] != sessionRef ||
        !{'open', 'clearing', 'closed'}.contains(session['status']) ||
        !{'prepay', 'postpay'}.contains(session['paymentTiming'])) {
      throw const FormatException();
    }
    final orders = List<LiveOrder>.unmodifiable(
      (data['orders'] as List).map((value) => LiveOrder(_map(value))),
    );
    if (orders.length > 20 ||
        orders.map((order) => order.reference).toSet().length !=
            orders.length) {
      throw const FormatException();
    }
    var previous = afterOrder ?? '';
    for (final order in orders) {
      if (order.reference.compareTo(previous) <= 0) {
        throw const FormatException();
      }
      previous = order.reference;
    }
    if (!data.containsKey('nextAfterOrder')) throw const FormatException();
    final next = data['nextAfterOrder'] == null
        ? null
        : _ref(data['nextAfterOrder']);
    if (next != null &&
        (orders.length != 20 || next != orders.last.reference)) {
      throw const FormatException();
    }
    return OrderSnapshot._(
      orders,
      _time(data['observedAt']),
      next,
      session['status'] as String,
    );
  }
}
