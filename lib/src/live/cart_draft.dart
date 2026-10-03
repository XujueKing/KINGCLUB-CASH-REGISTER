import 'dart:convert';
import 'dart:math';

import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import '../network/ccsop_crypto.dart';
import 'catalog_snapshot.dart';
import 'order_command.dart';
import 'order_context_snapshot.dart';

bool _ref(Object? v) =>
    v is String && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(v);
bool _int(Object? v, int max) => v is int && v > 0 && v <= max;

class RestoredCart {
  RestoredCart(this.draft, this.context, this.items);
  final CartDraft draft;
  final OrderContextSnapshot context;
  final List<OrderSelection> items;
}

/// Unsubmitted selection only. No business request ID, receipt or credentials.
class CartDraft {
  CartDraft._(this._value);
  final Map<String, dynamic> _value;
  String get storeRef => _value['storeRef'] as String;
  String get tableRef => _value['tableRef'] as String;
  String get sessionRef => _value['sessionRef'] as String;
  String? get memberRef => _value['memberRef'] as String?;
  DateTime get savedAt => DateTime.parse(_value['savedAt'] as String);
  List<Map<String, dynamic>> get lines =>
      _value['lines'] as List<Map<String, dynamic>>;
  Map<String, dynamic> encode() => _value;
  String get signature => jsonEncode(_value);
  String get slot => jsonEncode([
    _value['base'],
    _value['employeeRef'],
    _value['deviceId'],
    storeRef,
    tableRef,
    sessionRef,
    memberRef,
  ]);
  bool belongsTo(StaffSession identity) =>
      _value['base'] == identity.base.toString() &&
      _value['employeeRef'] == identity.employeeRef &&
      _value['deviceId'] == identity.deviceId &&
      storeRef == identity.storeRef;

  factory CartDraft.capture({
    required StaffSession identity,
    required OrderContextSnapshot context,
    required String? memberRef,
    required List<OrderSelection> items,
    required DateTime now,
  }) {
    _checkContext(identity, context, memberRef, now);
    // Local edit version only, never sent as a business request ID.
    final random = Random.secure();
    final version = List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return CartDraft.decode({
      'base': identity.base.toString(),
      'employeeRef': identity.employeeRef,
      'deviceId': identity.deviceId,
      'storeRef': context.storeRef,
      'tableRef': context.tableRef,
      'sessionRef': context.sessionRef,
      'memberRef': memberRef,
      'paymentTiming': context.paymentTiming,
      'currency': context.currency,
      'savedAt': now.toUtc().toIso8601String(),
      'editVersion': version,
      'lines': items
          .map(
            (i) => {
              'productRef': i.product.reference,
              'quantity': i.quantity,
              'revision': i.product.revision,
              'priceCents': i.product.priceCents,
              if (i.specialPrice) 'unitPriceCents': i.unitPriceCents,
              if (i.specialPrice) 'selectionRef': i.selectionRef,
              if (i.expenseOwnerUserAccount != null)
                'expenseOwnerUserAccount': i.expenseOwnerUserAccount,
            },
          )
          .toList(),
    });
  }

  factory CartDraft.decode(Object? raw) {
    try {
      if (raw is! Map<String, dynamic> || raw.length != 12) {
        throw const FormatException();
      }
      if (raw['base'] is! String ||
          serviceBase(raw['base'] as String).toString() != raw['base'] ||
          raw['employeeRef'] is! String ||
          !RegExp(r'^E[0-9]{11}$').hasMatch(raw['employeeRef'] as String) ||
          raw['deviceId'] is! String ||
          !uuidPattern.hasMatch(raw['deviceId'] as String) ||
          ![raw['storeRef'], raw['tableRef']].every(_ref) ||
          (raw['memberRef'] != null && !_ref(raw['memberRef'])) ||
          raw['sessionRef'] is! String ||
          !(RegExp(r'^H[0-9]{11}$').hasMatch(raw['sessionRef'] as String) ||
              uuidPattern.hasMatch(raw['sessionRef'] as String)) ||
          !{'prepay', 'postpay'}.contains(raw['paymentTiming']) ||
          raw['currency'] != 'CNY' ||
          raw['editVersion'] is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(raw['editVersion'] as String) ||
          raw['savedAt'] is! String ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}(\d{3})?Z$')
              .hasMatch(raw['savedAt'] as String) ||
          DateTime.parse(raw['savedAt'] as String).toIso8601String() !=
              raw['savedAt'] ||
          raw['lines'] is! List) {
        throw const FormatException();
      }
      final rows = raw['lines'] as List;
      if (rows.isEmpty || rows.length > 50) throw const FormatException();
      final lines = <Map<String, dynamic>>[];
      var total = 0;
      for (final row in rows) {
        if (row is! Map<String, dynamic> ||
            row.length !=
                (row.containsKey('unitPriceCents') ? 6 : 4) +
                    (row.containsKey('expenseOwnerUserAccount') ? 1 : 0) ||
            (row.containsKey('expenseOwnerUserAccount') &&
                (row['unitPriceCents'] != 0 ||
                    !_ref(row['expenseOwnerUserAccount']))) ||
            (row.containsKey('unitPriceCents') &&
                (row['unitPriceCents'] is! int ||
                    (row['unitPriceCents'] as int) < 0 ||
                    (row['unitPriceCents'] as int) > 100000000 ||
                    !_ref(row['selectionRef']) ||
                    row['selectionRef'] == row['productRef'])) ||
            !_ref(row['productRef']) ||
            !_int(row['quantity'], 1000) ||
            !_int(row['revision'], 4294967295) ||
            !_int(row['priceCents'], 100000000)) {
          throw const FormatException();
        }
        total +=
            (row['quantity'] as int) *
            ((row['unitPriceCents'] ?? row['priceCents']) as int);
        lines.add(
          Map.unmodifiable({
            'productRef': row['productRef'],
            'quantity': row['quantity'],
            'revision': row['revision'],
            'priceCents': row['priceCents'],
            if (row.containsKey('unitPriceCents'))
              'unitPriceCents': row['unitPriceCents'],
            if (row.containsKey('unitPriceCents'))
              'selectionRef': row['selectionRef'],
            if (row.containsKey('expenseOwnerUserAccount'))
              'expenseOwnerUserAccount': row['expenseOwnerUserAccount'],
          }),
        );
      }
      if (total > 100000000 ||
          lines
                  .map((e) => e['selectionRef'] ?? e['productRef'])
                  .toSet()
                  .length !=
              lines.length) {
        throw const FormatException();
      }
      lines.sort(
        (a, b) =>
            (a['productRef'] as String).compareTo(b['productRef'] as String) !=
                0
            ? (a['productRef'] as String).compareTo(b['productRef'] as String)
            : ((a['selectionRef'] ?? a['productRef']) as String).compareTo(
                (b['selectionRef'] ?? b['productRef']) as String,
              ),
      );
      return CartDraft._(
        Map.unmodifiable({
          for (final key in [
            'base',
            'employeeRef',
            'deviceId',
            'storeRef',
            'tableRef',
            'sessionRef',
            'memberRef',
            'paymentTiming',
            'currency',
            'savedAt',
            'editVersion',
          ])
            key: raw[key],
          'lines': List<Map<String, dynamic>>.unmodifiable(lines),
        }),
      );
    } catch (_) {
      throw const CcsopFailure('CART_DRAFT_INVALID');
    }
  }

  /// Caller must fetch a fresh authorized context and catalogue, not disk caches.
  /// Any changed/missing item rejects the entire restore; never silently reprice.
  List<OrderSelection> restore({
    required StaffSession identity,
    required OrderContextSnapshot context,
    required List<CatalogProduct> products,
    required DateTime now,
  }) {
    _checkContext(identity, context, memberRef, now);
    if (!belongsTo(identity) ||
        context.tableRef != tableRef ||
        context.sessionRef != sessionRef ||
        context.paymentTiming != _value['paymentTiming'] ||
        products.map((p) => p.reference).toSet().length != products.length) {
      throw const CcsopFailure('CART_DRAFT_CONTEXT_CHANGED');
    }
    final byRef = {for (final p in products) p.reference: p};
    final result = <OrderSelection>[];
    final quantities = <String, int>{};
    for (final line in lines) {
      final p = byRef[line['productRef']];
      final ref = line['productRef'] as String;
      quantities[ref] = (quantities[ref] ?? 0) + (line['quantity'] as int);
      if (p == null ||
          p.revision != line['revision'] ||
          p.priceCents != line['priceCents'] ||
          (context.paymentTiming == 'postpay' &&
              (!p.inventoryKnown || p.available < quantities[ref]!))) {
        throw const CcsopFailure('CART_DRAFT_CATALOG_CHANGED');
      }
      result.add(
        OrderSelection(
          p,
          line['quantity'] as int,
          paymentTiming: context.paymentTiming,
          unitPriceCents: line['unitPriceCents'] as int?,
          selectionRef: line['selectionRef'] as String?,
          expenseOwnerUserAccount: line['expenseOwnerUserAccount'] as String?,
        ),
      );
    }
    return List.unmodifiable(result);
  }
}

void _checkContext(
  StaffSession identity,
  OrderContextSnapshot context,
  String? memberRef,
  DateTime now,
) {
  if (!identity.expiresAt.isAfter(now) ||
      !identity.permissions.contains('orders.create') ||
      identity.storeRef != context.storeRef ||
      context.currency != 'CNY' ||
      (memberRef == null
          ? !context.tableOrderAllowed
          : !context.members.any(
              (m) => m.reference == memberRef && m.eligible,
            ))) {
    throw const CcsopFailure('CART_DRAFT_CONTEXT_CHANGED');
  }
}
