import 'product_thumbnail.dart';
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
  OrderItem(Map<String, dynamic> value, {String? storeRef})
    : thumbnailPath = productThumbnail(value['bottleMaterial'], storeRef ?? ''),
      productRef = _ref(value['productRef']),
      quantity = _positive(value['quantity'], 1000),
      priceCents = _positive(value['priceCents'], 100000000),
      subtotalCents = _positive(value['subtotalCents']),
      servedQuantity = _servingCount(value, 'servedQuantity'),
      remainingQuantity = _servingCount(value, 'remainingQuantity'),
      returnableUnservedQuantity = _servingCount(
        value,
        'returnableUnservedQuantity',
      ),
      servingEpoch = value['servingEpoch'] == null
          ? null
          : _epoch(value['servingEpoch']),
      names = _localized(_map(value['snapshot'])['names']),
      specifications = _localized(_map(value['snapshot'])['specifications']) {
    _positive(_map(value['snapshot'])['revision']);
    if (quantity * priceCents != subtotalCents) throw const FormatException();
    if (returnableUnservedQuantity != null &&
        (remainingQuantity == null ||
            returnableUnservedQuantity! > remainingQuantity!)) {
      throw const FormatException();
    }
    if ((servedQuantity == null) != (remainingQuantity == null) ||
        (servedQuantity != null &&
            servedQuantity! + remainingQuantity! != quantity)) {
      throw const FormatException();
    }
  }
  final String productRef;
  final String? thumbnailPath;
  final int quantity, priceCents, subtotalCents;
  // Both absent means an older server did not provide delivery progress, never zero delivered.
  final int? servedQuantity, remainingQuantity;
  // Display hint only; the server revalidates physical stock and original receipts.
  final int? returnableUnservedQuantity;
  final int? servingEpoch;
  bool get servingKnown => servedQuantity != null;
  final List<String> names, specifications;
  String name(UiLanguage language) => names[language.index];
  String specification(UiLanguage language) => specifications[language.index];
}

int _epoch(Object? value) {
  if (value is! int || value < 0 || value > 1000000) {
    throw const FormatException();
  }
  return value;
}

int? _servingCount(Map<String, dynamic> value, String key) {
  if (!value.containsKey(key)) return null;
  final count = value[key];
  if (count is! int || count < 0 || count > 1000) throw const FormatException();
  return count;
}

class LiveOrder {
  LiveOrder(Map<String, dynamic> value, {String? storeRef})
    : reference = _ref(value['orderRef']),
      tableCheckoutRef = _tableCheckoutRef(value['tableCheckoutRef']),
      cashierOrder = value.containsKey('cashierOrder')
          ? _cashierOrigin(value['cashierOrder'])
          : false,
      status = value['status'] as String,
      currency = value['currency'] as String,
      totalCents = _positive(value['totalCents']),
      refund = value['refund'] == null
          ? null
          : OrderRefund(_map(value['refund'])),
      createdAt = _time(value['createdAt']),
      items = List.unmodifiable(
        (value['items'] as List).map(
          (item) => OrderItem(_map(item), storeRef: storeRef),
        ),
      ) {
    if ((tableCheckoutRef != null && status != 'paid') ||
        (refund != null &&
            (status != 'paid' ||
                !cashierOrder ||
                refund!.totalCents != totalCents)) ||
        !{'pending', 'paid', 'expired'}.contains(status) ||
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
  // Read-only navigation, never a payment or refund authorization.
  final String? tableCheckoutRef;
  final bool cashierOrder;
  final int totalCents;
  final OrderRefund? refund;
  final DateTime createdAt;
  final List<OrderItem> items;
}

String? _tableCheckoutRef(Object? value) {
  if (value == null) return null;
  if (value is! String ||
      !RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(value)) {
    throw const FormatException();
  }
  return value;
}

class OrderRefund {
  OrderRefund(Map<String, dynamic> value)
    : reference = value['refundRef'] as String,
      accountType = value['accountType'] as String,
      totalCents = _positive(value['totalCents'], 100000000),
      principalCents = _refundAmount(value['principalCents']),
      giftCents = _refundAmount(value['giftCents']),
      refundedAt = _time(value['refundedAt']) {
    if (value.length != 6 ||
        !RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ).hasMatch(reference) ||
        !{'platform_cash', 'store_balance'}.contains(accountType) ||
        principalCents + giftCents != totalCents ||
        (accountType == 'platform_cash' && giftCents != 0)) {
      throw const FormatException();
    }
  }
  final String reference, accountType;
  final int totalCents, principalCents, giftCents;
  final DateTime refundedAt;
}

int _refundAmount(Object? value) {
  if (value is! int || value < 0 || value > 100000000) {
    throw const FormatException();
  }
  return value;
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
    this.paymentTiming,
    this.sessionSummary,
  );
  final List<LiveOrder> orders;
  final DateTime observedAt;
  final String? nextAfterOrder;
  final String sessionStatus;
  final String paymentTiming;
  final SessionOrderSummary? sessionSummary;
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
      (data['orders'] as List).map(
        (value) => LiveOrder(_map(value), storeRef: storeRef),
      ),
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
      session['paymentTiming'] as String,
      data.containsKey('sessionSummary')
          ? SessionOrderSummary.parse(data['sessionSummary'], orders)
          : null,
    );
  }
}

class OrderSummaryBucket {
  const OrderSummaryBucket(this.orderCount, this.totalCents);
  final int orderCount, totalCents;
}

/// Whole-session counts from the server transaction, never a collection authorization.
class SessionOrderSummary {
  SessionOrderSummary._(this.currency, this.buckets);
  final String currency;
  final Map<String, OrderSummaryBucket> buckets;
  factory SessionOrderSummary.parse(Object? raw, List<LiveOrder> orders) {
    final data = _map(raw), currency = data['currency'];
    final refundKnown =
        data.containsKey('refunded') && data.containsKey('netPaid');
    final hasFullCount = data.containsKey('fullyRefundedOrderCount');
    if (data.length != (refundKnown ? (hasFullCount ? 7 : 6) : 4) ||
        (hasFullCount && !refundKnown) ||
        data.containsKey('refunded') != data.containsKey('netPaid') ||
        currency is! String ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      throw const FormatException();
    }
    var total = 0, count = 0;
    final buckets = <String, OrderSummaryBucket>{};
    for (final status in ['paid', 'pending', 'expired']) {
      final bucket = _map(data[status]);
      final n = bucket['orderCount'], cents = bucket['totalCents'];
      if (bucket.length != 2 ||
          n is! int ||
          cents is! int ||
          n < 0 ||
          cents < 0 ||
          n > 9007199254740991 ||
          cents > 9007199254740991 ||
          (n == 0 ? cents != 0 : cents < n)) {
        throw const FormatException();
      }
      total += cents;
      count += n;
      if (total > 9007199254740991 || count > 9007199254740991) {
        throw const FormatException();
      }
      final page = orders.where((order) => order.status == status);
      if (page.length > n ||
          page.fold<int>(0, (sum, order) => sum + order.totalCents) > cents) {
        throw const FormatException();
      }
      buckets[status] = OrderSummaryBucket(n, cents);
    }
    if (orders.any((order) => order.currency != currency)) {
      throw const FormatException();
    }
    if (refundKnown) {
      for (final key in ['refunded', 'netPaid']) {
        final bucket = _map(data[key]),
            n = bucket['orderCount'],
            amount = bucket['totalCents'];
        if (bucket.length != 2 ||
            n is! int ||
            amount is! int ||
            n < 0 ||
            amount < 0 ||
            n > 9007199254740991 ||
            amount > 9007199254740991 ||
            (n == 0 ? amount != 0 : amount < n)) {
          throw const FormatException();
        }
        buckets[key] = OrderSummaryBucket(n, amount);
      }
      final paid = buckets['paid']!,
          refund = buckets['refunded']!,
          net = buckets['netPaid']!;
      final fully = hasFullCount
          ? data['fullyRefundedOrderCount']
          : refund.orderCount;
      if (fully is! int ||
          fully < 0 ||
          fully > refund.orderCount ||
          refund.orderCount > paid.orderCount ||
          fully + net.orderCount != paid.orderCount ||
          refund.totalCents + net.totalCents != paid.totalCents) {
        throw const FormatException();
      }
      final page = orders.where((order) => order.refund != null);
      if (page.length > refund.orderCount ||
          page.fold<int>(0, (sum, order) => sum + order.refund!.totalCents) >
              refund.totalCents) {
        throw const FormatException();
      }
    } else if (orders.any((order) => order.refund != null)) {
      throw const FormatException();
    }
    return SessionOrderSummary._(currency, Map.unmodifiable(buckets));
  }
}
