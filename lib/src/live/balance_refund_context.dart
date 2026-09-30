// A read-only server snapshot, never a refund authorization or default return plan.
class BalanceRefundContext {
  BalanceRefundContext._(
    this.storeRef,
    this.orderRef,
    this.originalIntentRef,
    this.accountType,
    this.totalCents,
    this.principalCents,
    this.giftCents,
    this.lines,
    this.sources,
    this.refundRef,
  );

  factory BalanceRefundContext.parse(
    Object? raw, {
    required String expectedStore,
    required String expectedOrder,
  }) {
    final value = _object(raw);
    final store = _ref(value['storeRef']);
    final order = _pattern(value['orderRef'], r'^D[0-9]{11}$');
    if (store != expectedStore || order != expectedOrder) {
      throw const FormatException('Refund context scope mismatch');
    }
    if (value['state'] == 'already_refunded') {
      _keys(value, {'state', 'storeRef', 'orderRef', 'refundRef'});
      return BalanceRefundContext._(
        store,
        order,
        null,
        null,
        null,
        null,
        null,
        const [],
        const [],
        _uuid(value['refundRef']),
      );
    }
    _keys(value, {
      'state',
      'storeRef',
      'orderRef',
      'originalIntentRef',
      'accountType',
      'currency',
      'totalCents',
      'principalCents',
      'giftCents',
      'lines',
      'sources',
    });
    if (value['state'] != 'ready' ||
        value['currency'] != 'CNY' ||
        !{'platform_cash', 'store_balance'}.contains(value['accountType'])) {
      throw const FormatException('Invalid balance refund context');
    }
    final total = _count(value['totalCents'], 1, 100000000);
    final principal = _count(value['principalCents'], 0, 100000000);
    final gift = _count(value['giftCents'], 0, 100000000);
    if (principal + gift != total ||
        (value['accountType'] == 'platform_cash' && gift != 0)) {
      throw const FormatException('Invalid original account split');
    }
    final lines = _list(value['lines'], 50)
        .map((raw) {
          final line = _object(raw);
          _keys(line, {'productRef', 'quantity', 'servedQuantity'});
          final quantity = _count(line['quantity'], 1, 1000);
          return RefundContextLine(
            _ref(line['productRef']),
            quantity,
            _count(line['servedQuantity'], 0, quantity),
          );
        })
        .toList(growable: false);
    final sources = _list(value['sources'], 50000)
        .map((raw) {
          final source = _object(raw);
          _keys(source, {
            'originalMovementRef',
            'productRef',
            'batchRef',
            'issuedQuantity',
          });
          return RefundContextSource(
            _pattern(source['originalMovementRef'], r'^M[0-9]{11}$'),
            _ref(source['productRef']),
            _ref(source['batchRef']),
            _count(source['issuedQuantity'], 1, 1000),
          );
        })
        .toList(growable: false);
    final quantities = {
      for (final line in lines) line.productRef: line.quantity,
    };
    final movements = <String>{}, batches = <String>{};
    if (quantities.length != lines.length) throw const FormatException();
    for (final source in sources) {
      if (!quantities.containsKey(source.productRef) ||
          !movements.add(source.originalMovementRef) ||
          !batches.add('${source.productRef}:${source.batchRef}')) {
        throw const FormatException('Duplicate or foreign issue');
      }
      quantities[source.productRef] =
          quantities[source.productRef]! - source.issuedQuantity;
    }
    if (quantities.values.any((remaining) => remaining != 0)) {
      throw const FormatException('Incomplete original issues');
    }
    return BalanceRefundContext._(
      store,
      order,
      _uuid(value['originalIntentRef']),
      value['accountType'] as String,
      total,
      principal,
      gift,
      List.unmodifiable(lines),
      List.unmodifiable(sources),
      null,
    );
  }

  final String storeRef, orderRef;
  final String? originalIntentRef, accountType, refundRef;
  final int? totalCents, principalCents, giftCents;
  final List<RefundContextLine> lines;
  final List<RefundContextSource> sources;
  bool get alreadyRefunded => refundRef != null;
}

class RefundContextLine {
  const RefundContextLine(this.productRef, this.quantity, this.servedQuantity);
  final String productRef;
  final int quantity, servedQuantity;
}

class RefundContextSource {
  const RefundContextSource(
    this.originalMovementRef,
    this.productRef,
    this.batchRef,
    this.issuedQuantity,
  );
  final String originalMovementRef, productRef, batchRef;
  final int issuedQuantity;
}

Map<String, dynamic> _object(Object? raw) {
  if (raw is! Map<String, dynamic>) throw const FormatException();
  return raw;
}

void _keys(Map<String, dynamic> value, Set<String> keys) {
  if (value.length != keys.length || !value.keys.every(keys.contains)) {
    throw const FormatException('Unexpected refund fields');
  }
}

String _pattern(Object? value, String pattern) {
  if (value is! String || !RegExp(pattern).hasMatch(value)) {
    throw const FormatException();
  }
  return value;
}

String _ref(Object? value) => _pattern(value, r'^[A-Za-z0-9_-]{1,64}$');
String _uuid(Object? value) => _pattern(
  value,
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
int _count(Object? value, int min, int max) {
  if (value is! int || value < min || value > max) {
    throw const FormatException();
  }
  return value;
}

List<dynamic> _list(Object? value, int max) {
  if (value is! List || value.isEmpty || value.length > max) {
    throw const FormatException();
  }
  return value;
}
