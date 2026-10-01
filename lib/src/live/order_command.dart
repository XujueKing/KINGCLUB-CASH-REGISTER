import 'dart:convert';
import 'dart:math';

import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import 'catalog_snapshot.dart';
import 'cart_draft.dart';
import 'order_context_snapshot.dart';

bool _ref(Object? v) =>
    v is String && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(v);
bool _integer(Object? v, int min, int max) => v is int && v >= min && v <= max;
Map<String, dynamic> _map(Object? v) {
  if (v is! Map<String, dynamic>) throw const FormatException();
  return v;
}

/// Only a catalogue observation; the server rechecks price, inventory and membership.
class OrderSelection {
  OrderSelection(
    this.product,
    this.quantity, {
    String paymentTiming = 'postpay',
  }) {
    if (!{'prepay', 'postpay'}.contains(paymentTiming) ||
        quantity < 1 ||
        quantity > 1000 ||
        (paymentTiming == 'postpay' &&
            (!product.inventoryKnown || quantity > product.available))) {
      throw const CcsopFailure('ORDERING_OUT_OF_STOCK');
    }
  }
  final CatalogProduct product;
  final int quantity;
}

/// Original immutable command, not an order receipt. Never contains authentication secrets.
class PendingOrder {
  PendingOrder._(
    this.base,
    this.employeeRef,
    this.deviceId,
    this._params,
    this.totalCents,
    this.cartDraft,
  );
  final String base, employeeRef, deviceId;
  final Map<String, dynamic> _params;
  final int totalCents;
  final CartDraft? cartDraft;
  String get storeRef => _params['storeRef'] as String;
  String get tableRef => _params['tableRef'] as String;
  String get sessionRef => _params['sessionRef'] as String;
  String? get memberRef => _params['memberRef'] as String?;
  String get requestId => _params['requestId'] as String;
  String get paymentTiming => _params['expectedPaymentTiming'] as String;
  Map<String, dynamic> get params => _params;
  Map<String, dynamic> get lookup => Map.unmodifiable({
    'storeRef': storeRef,
    'tableRef': tableRef,
    'sessionRef': sessionRef,
    'requestId': requestId,
  });
  bool belongsTo(StaffSession identity) =>
      base == identity.base.toString() &&
      employeeRef == identity.employeeRef &&
      deviceId == identity.deviceId &&
      storeRef == identity.storeRef;
  Map<String, dynamic> encode() => {
    'base': base,
    'employeeRef': employeeRef,
    'deviceId': deviceId,
    'params': params,
    if (cartDraft != null) 'cartDraft': cartDraft!.encode(),
  };
  String get signature => jsonEncode(encode());

  factory PendingOrder.prepare({
    required StaffSession identity,
    required OrderContextSnapshot context,
    required String? memberRef,
    required List<OrderSelection> items,
    required DateTime now,
    CartDraft? cartDraft,
  }) {
    if (!identity.expiresAt.isAfter(now) ||
        !identity.permissions.contains('orders.create') ||
        identity.storeRef != context.storeRef ||
        context.currency != 'CNY' ||
        (memberRef == null
            ? !context.tableOrderAllowed
            : !context.members.any(
                (m) => m.reference == memberRef && m.eligible,
              ))) {
      throw const CcsopFailure('ORDERING_CONTEXT_CHANGED');
    }
    final random = Random.secure(), bytes = List.generate(16, (_) => 0);
    for (var i = 0; i < 16; i++) {
      bytes[i] = random.nextInt(256);
    }
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final requestId =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    return PendingOrder.decode({
      'base': identity.base.toString(),
      'employeeRef': identity.employeeRef,
      'deviceId': identity.deviceId,
      if (cartDraft != null) 'cartDraft': cartDraft.encode(),
      'params': {
        'storeRef': identity.storeRef,
        'tableRef': context.tableRef,
        'sessionRef': context.sessionRef,
        'memberRef': memberRef,
        'requestId': requestId,
        'expectedPaymentTiming': context.paymentTiming,
        'items': items
            .map(
              (line) => {
                'productRef': line.product.reference,
                'quantity': line.quantity,
                'expectedRevision': line.product.revision,
                'expectedPriceCents': line.product.priceCents,
              },
            )
            .toList(),
      },
    });
  }

  factory PendingOrder.decode(Object? raw) {
    try {
      final v = _map(raw), p = _map(v['params']);
      final uri = v['base'] is String
          ? Uri.tryParse(v['base'] as String)
          : null;
      if (v.length != (v.containsKey('cartDraft') ? 5 : 4) ||
          p.length != 7 ||
          uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          v['employeeRef'] is! String ||
          !RegExp(r'^E[0-9]{11}$').hasMatch(v['employeeRef'] as String) ||
          v['deviceId'] is! String ||
          !uuidPattern.hasMatch(v['deviceId'] as String) ||
          ![p['storeRef'], p['tableRef']].every(_ref) ||
          (p['memberRef'] != null && !_ref(p['memberRef'])) ||
          p['sessionRef'] is! String ||
          !(RegExp(r'^H[0-9]{11}$').hasMatch(p['sessionRef'] as String) ||
              uuidPattern.hasMatch(p['sessionRef'] as String)) ||
          p['requestId'] is! String ||
          !uuidPattern.hasMatch(p['requestId'] as String) ||
          !{'prepay', 'postpay'}.contains(p['expectedPaymentTiming']) ||
          p['items'] is! List) {
        throw const FormatException();
      }
      final rows = p['items'] as List;
      if (rows.isEmpty || rows.length > 50) throw const FormatException();
      final items = <Map<String, dynamic>>[];
      var total = 0;
      for (final row in rows) {
        final item = _map(row);
        if (item.length != 4 ||
            !_ref(item['productRef']) ||
            !_integer(item['quantity'], 1, 1000) ||
            !_integer(item['expectedRevision'], 1, 4294967295) ||
            !_integer(item['expectedPriceCents'], 1, 100000000)) {
          throw const FormatException();
        }
        total +=
            (item['quantity'] as int) * (item['expectedPriceCents'] as int);
        items.add(
          Map.unmodifiable({
            'productRef': item['productRef'],
            'quantity': item['quantity'],
            'expectedRevision': item['expectedRevision'],
            'expectedPriceCents': item['expectedPriceCents'],
          }),
        );
      }
      if (total > 100000000 ||
          items.map((i) => i['productRef']).toSet().length != items.length) {
        throw const FormatException();
      }
      items.sort(
        (a, b) =>
            (a['productRef'] as String).compareTo(b['productRef'] as String),
      );
      final draft = v.containsKey('cartDraft')
          ? CartDraft.decode(v['cartDraft'])
          : null;
      if (draft != null) {
        final d = draft.encode();
        if (d['base'] != v['base'] ||
            d['employeeRef'] != v['employeeRef'] ||
            d['deviceId'] != v['deviceId'] ||
            draft.storeRef != p['storeRef'] ||
            draft.tableRef != p['tableRef'] ||
            draft.sessionRef != p['sessionRef'] ||
            draft.memberRef != p['memberRef'] ||
            d['paymentTiming'] != p['expectedPaymentTiming'] ||
            draft.lines.length != items.length) {
          throw const FormatException();
        }
        for (var i = 0; i < items.length; i++) {
          final line = items[i], saved = draft.lines[i];
          if (saved['productRef'] != line['productRef'] ||
              saved['quantity'] != line['quantity'] ||
              saved['priceCents'] != line['expectedPriceCents'] ||
              saved['revision'] != line['expectedRevision']) {
            throw const FormatException();
          }
        }
      }
      return PendingOrder._(
        v['base'] as String,
        v['employeeRef'] as String,
        v['deviceId'] as String,
        Map.unmodifiable({
          'storeRef': p['storeRef'],
          'tableRef': p['tableRef'],
          'sessionRef': p['sessionRef'],
          'memberRef': p['memberRef'],
          'requestId': p['requestId'],
          'expectedPaymentTiming': p['expectedPaymentTiming'],
          'items': List<Map<String, dynamic>>.unmodifiable(items),
        }),
        total,
        draft,
      );
    } catch (_) {
      throw const CcsopFailure('ORDER_COMMAND_INVALID');
    }
  }
}

enum OrderRequestState { confirmed, cancelled, notObserved }

/// Validated against the ENTIRE locally persisted original command, never a generic success flag.
class OrderRequestResult {
  OrderRequestResult._(this.state, this.commandSignature, this.orderRef);
  final OrderRequestState state;
  final String commandSignature;
  final String? orderRef;
  factory OrderRequestResult.parse(
    Object? raw,
    PendingOrder pending, {
    bool submission = false,
  }) {
    try {
      final result = _map(_map(raw)['result']);
      final state = submission ? 'confirmed' : result['state'];
      if (!submission &&
          (result['requestId'] != pending.requestId ||
              result.length != (state == 'confirmed' ? 3 : 2))) {
        throw const FormatException();
      }
      if (state == 'cancelled' || state == 'not_observed') {
        return OrderRequestResult._(
          state == 'cancelled'
              ? OrderRequestState.cancelled
              : OrderRequestState.notObserved,
          pending.signature,
          null,
        );
      }
      if (state != 'confirmed') throw const FormatException();
      final receipt = submission ? result : _map(result['receipt']);
      if (receipt.length != 11 ||
          receipt['requestId'] != pending.requestId ||
          receipt['storeRef'] != pending.storeRef ||
          receipt['tableRef'] != pending.tableRef ||
          receipt['sessionRef'] != pending.sessionRef ||
          receipt['memberRef'] != pending.memberRef ||
          receipt['paymentTiming'] != pending.paymentTiming ||
          receipt['currency'] != 'CNY' ||
          receipt['submissionStatus'] != 'confirmed' ||
          (pending.paymentTiming == 'prepay'
              ? !['unallocated', 'reserved'].contains(receipt['inventoryState'])
              : ![
                  'unallocated',
                  'issued',
                ].contains(receipt['inventoryState'])) ||
          receipt['totalCents'] is! int ||
          receipt['totalCents'] != pending.totalCents ||
          receipt['orderRef'] is! String ||
          !RegExp(r'^D[0-9]{11}$').hasMatch(receipt['orderRef'] as String)) {
        throw const FormatException();
      }
      return OrderRequestResult._(
        OrderRequestState.confirmed,
        pending.signature,
        receipt['orderRef'] as String,
      );
    } catch (_) {
      throw const CcsopFailure('ORDER_RECEIPT_MISMATCH');
    }
  }
}
