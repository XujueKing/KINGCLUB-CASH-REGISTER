import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import '../strings.dart';

Map<String, dynamic> _object(Object? raw, List<String> keys) {
  if (raw is! Map<String, dynamic> ||
      raw.length != keys.length ||
      !raw.keys.toSet().containsAll(keys)) {
    throw const FormatException();
  }
  return raw;
}

int _number(Object? raw, {int min = 0, int max = 100000000}) {
  if (raw is! int || raw < min || raw > max) throw const FormatException();
  return raw;
}

String _ref(Object? raw) {
  if (raw is! String || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(raw)) {
    throw const FormatException();
  }
  return raw;
}

DateTime _date(Object? raw) {
  if (raw is! String ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$').hasMatch(raw)) {
    throw const FormatException();
  }
  final date = DateTime.parse(raw);
  if (date.toIso8601String() != raw) throw const FormatException();
  return date;
}

List<String> _languages(Object? raw) {
  const keys = ['zh-CN', 'en', 'zh-TW', 'th'];
  final map = _object(raw, keys);
  return List.unmodifiable(
    keys.map((key) {
      final value = map[key];
      if (value is! String ||
          value.trim().isEmpty ||
          value.length > 128 ||
          RegExp(r'[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]')
              .hasMatch(value)) {
        throw const FormatException();
      }
      return value;
    }),
  );
}

class ReceiptLine {
  ReceiptLine._(Map<String, dynamic> row)
    : productRef = _ref(row['productRef']),
      quantity = _number(row['quantity'], min: 1, max: 1000),
      priceCents = _number(row['priceCents'], min: 1),
      subtotalCents = _number(row['subtotalCents'], min: 1),
      revision = _number(row['revision'], min: 1, max: 9007199254740991),
      names = _languages(row['names']),
      specifications = _languages(row['specifications']) {
    if (quantity * priceCents != subtotalCents) throw const FormatException();
  }
  final String productRef;
  final int quantity, priceCents, subtotalCents, revision;
  final List<String> names, specifications;
  String name(UiLanguage language) => names[language.index];
  String specification(UiLanguage language) => specifications[language.index];
}

/// One collection's tender, never copied onto its child order allocations.
class ReceiptTender {
  ReceiptTender._(
    this.channel,
    this.accountType,
    this.principalCents,
    this.giftCents,
    this.receivedCents,
    this.changeCents,
  );
  final String channel;
  final String? accountType;
  final int? principalCents, giftCents, receivedCents, changeCents;

  static ReceiptTender _parse(Object? raw, int total) {
    if (raw is! Map<String, dynamic>) throw const FormatException();
    final channel = raw['channel'];
    String? account;
    int? principal, gift, received, change;
    if (channel == 'cash') {
      _object(raw, ['channel', 'receivedCents', 'changeCents']);
      received = _number(raw['receivedCents'], min: 1);
      change = _number(raw['changeCents']);
      if (received - change != total) throw const FormatException();
    } else if (channel == 'member_balance') {
      _object(raw, ['channel', 'accountType', 'principalCents', 'giftCents']);
      if (!['platform_cash', 'store_balance'].contains(raw['accountType'])) {
        throw const FormatException();
      }
      account = raw['accountType'] as String;
      principal = _number(raw['principalCents']);
      gift = _number(raw['giftCents']);
      if (principal + gift != total ||
          (account == 'platform_cash' && gift != 0)) {
        throw const FormatException();
      }
    } else if (channel == 'wechat' || channel == 'alipay') {
      _object(raw, ['channel']);
    } else {
      throw const FormatException();
    }
    return ReceiptTender._(
      channel as String,
      account,
      principal,
      gift,
      received,
      change,
    );
  }
}

class TableReceiptOrder {
  TableReceiptOrder._(this.orderRef, this.allocatedCents, this.items);
  final String orderRef;
  final int allocatedCents;
  final List<ReceiptLine> items;
}

/// Memory-only verified server display contract. Not authority to charge or
/// evidence of physical printing. Refund documents require a separate contract;
/// unknown/refunded states fail closed instead of showing stale net amounts.
class TableReceiptDocument {
  TableReceiptDocument._({
    required this.checkoutRef,
    required this.storeRef,
    required this.tableRef,
    required this.sessionRef,
    required this.totalCents,
    required this.createdAt,
    required this.confirmedAt,
    required this.settledAt,
    required this.observedAt,
    required this.tender,
    required this.orders,
  });
  final String checkoutRef, storeRef, tableRef, sessionRef;
  final int totalCents;
  final DateTime createdAt, confirmedAt, settledAt, observedAt;
  final ReceiptTender tender;
  final List<TableReceiptOrder> orders;

  factory TableReceiptDocument.parse(
    Object? raw, {
    required String storeRef,
    required String checkoutRef,
  }) {
    try {
      final root = _object(raw, ['result']);
      final row = _object(root['result'], [
        'version',
        'documentType',
        'checkoutRef',
        'storeRef',
        'tableRef',
        'sessionRef',
        'currency',
        'status',
        'totalCents',
        'refundedCents',
        'netPaidCents',
        'createdAt',
        'confirmedAt',
        'settledAt',
        'observedAt',
        'orderCount',
        'tender',
        'orders',
      ]);
      if (!uuidPattern.hasMatch(checkoutRef) ||
          checkoutRef != checkoutRef.toLowerCase() ||
          row['checkoutRef'] != checkoutRef ||
          row['storeRef'] != storeRef ||
          row['version'] is! int ||
          row['version'] != 1 ||
          row['documentType'] != 'cashier_table_receipt' ||
          row['currency'] != 'CNY' ||
          row['status'] != 'paid') {
        throw const FormatException();
      }
      final total = _number(row['totalCents'], min: 1);
      if (_number(row['refundedCents']) != 0 ||
          _number(row['netPaidCents']) != total) {
        throw const FormatException();
      }
      final created = _date(row['createdAt']),
          confirmed = _date(row['confirmedAt']),
          settled = _date(row['settledAt']),
          observed = _date(row['observedAt']);
      if (confirmed.isBefore(created) ||
          settled.isBefore(confirmed) ||
          observed.isBefore(settled)) {
        throw const FormatException();
      }
      final count = _number(row['orderCount'], min: 1, max: 1000),
          rawOrders = row['orders'];
      if (rawOrders is! List || rawOrders.length != count) {
        throw const FormatException();
      }
      final orders = <TableReceiptOrder>[], seen = <String>{};
      var sum = 0;
      for (final rawOrder in rawOrders) {
        final order = _object(rawOrder, [
          'orderRef',
          'allocatedCents',
          'items',
        ]);
        final orderRef = _ref(order['orderRef']);
        if (!RegExp(r'^D[0-9]{11}$').hasMatch(orderRef) ||
            !seen.add(orderRef)) {
          throw const FormatException();
        }
        final allocated = _number(order['allocatedCents'], min: 1),
            rawItems = order['items'];
        if (rawItems is! List || rawItems.isEmpty || rawItems.length > 50) {
          throw const FormatException();
        }
        final items = rawItems
            .map(
              (item) => ReceiptLine._(
                _object(item, [
                  'productRef',
                  'quantity',
                  'priceCents',
                  'subtotalCents',
                  'names',
                  'specifications',
                  'revision',
                ]),
              ),
            )
            .toList();
        if (items.map((item) => item.productRef).toSet().length !=
                items.length ||
            items.fold<int>(0, (sum, item) => sum + item.subtotalCents) !=
                allocated) {
          throw const FormatException();
        }
        sum += allocated;
        if (sum > total) throw const FormatException();
        orders.add(
          TableReceiptOrder._(orderRef, allocated, List.unmodifiable(items)),
        );
      }
      if (sum != total) throw const FormatException();
      return TableReceiptDocument._(
        checkoutRef: checkoutRef,
        storeRef: _ref(row['storeRef']),
        tableRef: _ref(row['tableRef']),
        sessionRef: _ref(row['sessionRef']),
        totalCents: total,
        createdAt: created,
        confirmedAt: confirmed,
        settledAt: settled,
        observedAt: observed,
        tender: ReceiptTender._parse(row['tender'], total),
        orders: List.unmodifiable(orders),
      );
    } catch (_) {
      throw const CcsopFailure('TABLE_RECEIPT_DOCUMENT_INVALID');
    }
  }
}

class ReceiptItemRefund {
  ReceiptItemRefund._(Map<String, dynamic> row)
    : reference = row['refundRef'] as String,
      productRef = _ref(row['productRef']),
      quantity = _number(row['quantity'], min: 1, max: 1000),
      totalCents = _number(row['totalCents'], min: 1),
      principalCents = _number(row['principalCents']),
      giftCents = _number(row['giftCents']),
      refundedAt = _date(row['refundedAt']);
  final String reference, productRef;
  final int quantity, totalCents, principalCents, giftCents;
  final DateTime refundedAt;
}

/// Memory-only server projection. Never payment authority, a retry instruction,
/// or proof of physical printing. No raw envelope/customer identity is retained.
class ReceiptDocument {
  ReceiptDocument._({
    required this.storeRef,
    required this.orderRef,
    required this.tableRef,
    required this.sessionRef,
    required this.createdAt,
    required this.confirmedAt,
    required this.observedAt,
    required this.totalCents,
    required this.refundedCents,
    required this.netPaidCents,
    required this.channel,
    required this.accountType,
    required this.principalCents,
    required this.giftCents,
    required this.receivedCents,
    required this.changeCents,
    required this.refunds,
    required this.refundRef,
    required this.refundedAt,
    required this.items,
  });
  final String storeRef, orderRef, tableRef, sessionRef, channel;
  final String? accountType, refundRef;
  final DateTime createdAt, confirmedAt, observedAt;
  final DateTime? refundedAt;
  final int totalCents, refundedCents, netPaidCents;
  final int? principalCents, giftCents, receivedCents, changeCents;
  final List<ReceiptLine> items;
  final List<ReceiptItemRefund> refunds;
  bool get refunded => refundedCents == totalCents;
  bool get partiallyRefunded => refundedCents > 0 && !refunded;

  factory ReceiptDocument.parse(
    Object? raw, {
    required String storeRef,
    required String orderRef,
  }) {
    try {
      final root = _object(raw, ['result']);
      final row = _object(root['result'], [
        'version',
        'documentType',
        'storeRef',
        'tableRef',
        'sessionRef',
        'orderRef',
        'currency',
        'createdAt',
        'confirmedAt',
        'observedAt',
        'status',
        'totalCents',
        'refundedCents',
        'netPaidCents',
        'tender',
        'items',
        'refund',
        if ((root['result'] as Map).containsKey('refunds')) 'refunds',
      ]);
      if (row['version'] is! int ||
          row['version'] != 1 ||
          row['documentType'] != 'cashier_order_receipt' ||
          row['storeRef'] != storeRef ||
          row['orderRef'] != orderRef ||
          !RegExp(r'^D[0-9]{11}$').hasMatch(orderRef) ||
          row['currency'] != 'CNY' ||
          !['paid', 'refunded', 'partially_refunded'].contains(row['status'])) {
        throw const FormatException();
      }
      final total = _number(row['totalCents'], min: 1),
          refunded = _number(row['refundedCents']),
          net = _number(row['netPaidCents']);
      final created = _date(row['createdAt']),
          confirmed = _date(row['confirmedAt']),
          observed = _date(row['observedAt']);
      if (confirmed.isBefore(created) ||
          observed.isBefore(confirmed) ||
          total != refunded + net) {
        throw const FormatException();
      }
      final rawItems = row['items'];
      if (rawItems is! List || rawItems.isEmpty || rawItems.length > 50) {
        throw const FormatException();
      }
      final items = rawItems
          .map(
            (item) => ReceiptLine._(
              _object(item, [
                'productRef',
                'quantity',
                'priceCents',
                'subtotalCents',
                'names',
                'specifications',
                'revision',
              ]),
            ),
          )
          .toList();
      if (items.map((item) => item.productRef).toSet().length != items.length ||
          items.fold<int>(0, (sum, item) => sum + item.subtotalCents) !=
              total) {
        throw const FormatException();
      }
      final tender = ReceiptTender._parse(row['tender'], total);
      final channel = tender.channel,
          account = tender.accountType,
          principal = tender.principalCents,
          gift = tender.giftCents,
          received = tender.receivedCents,
          change = tender.changeCents;
      String? refundRef;
      DateTime? refundedAt;
      final refunds = <ReceiptItemRefund>[];
      if (row.containsKey('refunds')) {
        final rawRefunds = row['refunds'];
        if (channel != 'member_balance' ||
            row['refund'] != null ||
            rawRefunds is! List ||
            rawRefunds.isEmpty ||
            rawRefunds.length > 50000) {
          throw const FormatException();
        }
        final seen = <String>{}, quantities = <String, int>{};
        var sum = 0, principalReturned = 0, giftReturned = 0;
        for (final value in rawRefunds) {
          final entry = _object(value, [
            'refundRef',
            'refundedAt',
            'accountType',
            'principalCents',
            'giftCents',
            'totalCents',
            'productRef',
            'quantity',
          ]);
          if (entry['accountType'] != account ||
              entry['refundRef'] is! String ||
              !uuidPattern.hasMatch(entry['refundRef'])) {
            throw const FormatException();
          }
          final saved = ReceiptItemRefund._(entry);
          final item = items.singleWhere(
            (item) => item.productRef == saved.productRef,
          );
          final quantity = (quantities[saved.productRef] ?? 0) + saved.quantity;
          if (!seen.add(saved.reference) ||
              quantity > item.quantity ||
              saved.totalCents != saved.quantity * item.priceCents ||
              saved.principalCents + saved.giftCents != saved.totalCents ||
              saved.refundedAt.isBefore(confirmed) ||
              saved.refundedAt.isAfter(observed)) {
            throw const FormatException();
          }
          quantities[saved.productRef] = quantity;
          sum += saved.totalCents;
          principalReturned += saved.principalCents;
          giftReturned += saved.giftCents;
          refunds.add(saved);
        }
        if (sum != refunded ||
            principalReturned > principal! ||
            giftReturned > gift! ||
            row['status'] != (net == 0 ? 'refunded' : 'partially_refunded')) {
          throw const FormatException();
        }
      } else if (row['status'] == 'refunded') {
        final refund = _object(row['refund'], [
          'refundRef',
          'refundedAt',
          'accountType',
          'principalCents',
          'giftCents',
        ]);
        if (channel != 'member_balance' ||
            net != 0 ||
            refunded != total ||
            refund['accountType'] != account ||
            _number(refund['principalCents']) != principal ||
            _number(refund['giftCents']) != gift ||
            refund['refundRef'] is! String ||
            !uuidPattern.hasMatch(refund['refundRef'])) {
          throw const FormatException();
        }
        refundRef = refund['refundRef'] as String;
        refundedAt = _date(refund['refundedAt']);
        if (refundedAt.isBefore(confirmed) || refundedAt.isAfter(observed)) {
          throw const FormatException();
        }
      } else if (row['status'] != 'paid' ||
          row['refund'] != null ||
          refunded != 0 ||
          net != total) {
        throw const FormatException();
      }
      return ReceiptDocument._(
        storeRef: _ref(row['storeRef']),
        orderRef: orderRef,
        tableRef: _ref(row['tableRef']),
        sessionRef: _ref(row['sessionRef']),
        createdAt: created,
        confirmedAt: confirmed,
        observedAt: observed,
        totalCents: total,
        refundedCents: refunded,
        netPaidCents: net,
        channel: channel,
        accountType: account,
        principalCents: principal,
        giftCents: gift,
        receivedCents: received,
        changeCents: change,
        refunds: List.unmodifiable(refunds),
        refundRef: refundRef,
        refundedAt: refundedAt,
        items: List.unmodifiable(items),
      );
    } catch (_) {
      throw const CcsopFailure('RECEIPT_DOCUMENT_INVALID');
    }
  }
}
