import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import '../strings.dart';

/// Preparation metadata only. Even paid/settled here is NOT a verified receipt.
class TableCheckoutAdmission {
  TableCheckoutAdmission._(
    this.requestId,
    this.checkoutRef,
    this.paymentStatus,
  );
  final String requestId;
  final String? checkoutRef, paymentStatus;
  bool get observed => checkoutRef != null;
  factory TableCheckoutAdmission.parse(
    Object? raw,
    TableCheckoutCommand command,
  ) {
    try {
      final value = _object(raw, ['result'])['result'];
      if (value is! Map<String, dynamic>) throw const FormatException();
      if (value['state'] == 'not_observed') {
        final row = _object(value, ['state', 'requestId']);
        if (row['requestId'] != command.requestId) {
          throw const FormatException();
        }
        return TableCheckoutAdmission._(command.requestId, null, null);
      }
      final row = _object(value, [
        'state',
        'requestId',
        'checkoutRef',
        'paymentStatus',
        'storeRef',
        'tableRef',
        'sessionRef',
        'channel',
        'accountType',
        'currency',
        'totalCents',
        'orderCount',
        'snapshotFingerprint',
      ]);
      if (row['state'] != 'admission_observed' ||
          row['requestId'] != command.requestId ||
          row['storeRef'] != command.storeRef ||
          row['tableRef'] != command.tableRef ||
          row['sessionRef'] != command.sessionRef ||
          row['channel'] != command.channel ||
          row['accountType'] != command.accountType ||
          row['currency'] != 'CNY' ||
          _integer(row['totalCents'], 100000000) != command.totalCents ||
          _integer(row['orderCount'], 1000) != command.orderCount ||
          row['snapshotFingerprint'] != command.fingerprint ||
          ![
            'prepared',
            'pending',
            'unknown',
            'paid',
            'settled',
            'closed',
          ].contains(row['paymentStatus'])) {
        throw const FormatException();
      }
      return TableCheckoutAdmission._(
        command.requestId,
        _uuid(row['checkoutRef']),
        row['paymentStatus'] as String,
      );
    } catch (_) {
      throw const CcsopFailure('TABLE_CHECKOUT_ADMISSION_INVALID');
    }
  }
}

Map<String, dynamic> _object(Object? raw, List<String> keys) {
  if (raw is! Map<String, dynamic> ||
      raw.length != keys.length ||
      !raw.keys.toSet().containsAll(keys)) {
    throw const FormatException();
  }
  return raw;
}

String _ref(Object? raw) {
  if (raw is! String || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(raw)) {
    throw const FormatException();
  }
  return raw;
}

String _uuid(Object? raw) {
  if (raw is! String ||
      !RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(raw)) {
    throw const FormatException();
  }
  return raw;
}

int _integer(Object? raw, int max) {
  if (raw is! int || raw < 1 || raw > max) throw const FormatException();
  return raw;
}

void _account(Object? channel, Object? account) {
  if (!['wechat', 'alipay', 'cash', 'member_balance'].contains(channel) ||
      (channel == 'member_balance'
          ? !['platform_cash', 'store_balance'].contains(account)
          : account != null)) {
    throw const FormatException();
  }
}

class TableCheckoutAllocation {
  TableCheckoutAllocation._(
    this.orderRef,
    this.totalCents,
    this.inventoryAction,
  );
  final String orderRef, inventoryAction;
  final int totalCents;
}

class TableCheckoutLine {
  TableCheckoutLine._(
    this.orderRef,
    this.productRef,
    this.quantity,
    this.priceCents,
    this.names,
    this.specifications,
    this.revision,
  );
  final String orderRef, productRef;
  final int quantity, priceCents;
  final int revision;
  final List<String> names, specifications;
  String name(UiLanguage language) => names[language.index];
  String specification(UiLanguage language) => specifications[language.index];
}

List<String> _languages(Object? raw) {
  final row = _object(raw, ['zh-CN', 'en', 'zh-TW', 'th']);
  return List.unmodifiable(
    ['zh-CN', 'en', 'zh-TW', 'th'].map((key) {
      final value = row[key];
      if (value is! String ||
          value.isEmpty ||
          value.length > 128 ||
          RegExp(r'[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]')
              .hasMatch(value)) {
        throw const FormatException();
      }
      return value;
    }),
  );
}

/// A validated, immutable preview, never authorization or evidence of payment.
class TableCheckoutQuote {
  TableCheckoutQuote._(
    this.storeRef,
    this.tableRef,
    this.sessionRef,
    this.channel,
    this.accountType,
    this.totalCents,
    this.fingerprint,
    this.quotedAt,
    this.allocations,
    this.lines,
  );
  final String storeRef, tableRef, sessionRef, channel, fingerprint;
  final String? accountType;
  final int totalCents;
  final DateTime quotedAt;
  final List<TableCheckoutAllocation> allocations;
  final List<TableCheckoutLine> lines;
  late final Map<String, List<TableCheckoutLine>> linesByOrder = _groupLines();
  Map<String, List<TableCheckoutLine>> _groupLines() {
    final groups = <String, List<TableCheckoutLine>>{};
    for (final line in lines) {
      (groups[line.orderRef] ??= []).add(line);
    }
    return Map.unmodifiable(
      groups.map(
        (key, value) =>
            MapEntry(key, List<TableCheckoutLine>.unmodifiable(value)),
      ),
    );
  }

  factory TableCheckoutQuote.parse(
    Object? raw, {
    required String storeRef,
    required String tableRef,
    required String sessionRef,
    required String channel,
    required String? accountType,
  }) {
    try {
      _account(channel, accountType);
      final row = _object(_object(raw, ['result'])['result'], [
        'version',
        'state',
        'storeRef',
        'tableRef',
        'sessionRef',
        'channel',
        'accountType',
        'currency',
        'quotedAt',
        'totalCents',
        'orderCount',
        'snapshotFingerprint',
        'allocations',
        'lines',
      ]);
      if (row['version'] is! int ||
          row['version'] != 1 ||
          row['state'] != 'quote' ||
          row['storeRef'] != _ref(storeRef) ||
          row['tableRef'] != _ref(tableRef) ||
          row['sessionRef'] != _ref(sessionRef) ||
          row['channel'] != channel ||
          row['accountType'] != accountType ||
          row['currency'] != 'CNY') {
        throw const FormatException();
      }
      final total = _integer(row['totalCents'], 100000000);
      final count = _integer(row['orderCount'], 1000);
      final hash = row['snapshotFingerprint'];
      if (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
        throw const FormatException();
      }
      final time = row['quotedAt'];
      if (time is! String ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')
              .hasMatch(time)) {
        throw const FormatException();
      }
      final quoted = DateTime.parse(time);
      if (quoted.toIso8601String() != time) throw const FormatException();
      final allocationRows = row['allocations'], lineRows = row['lines'];
      if (allocationRows is! List ||
          allocationRows.length != count ||
          lineRows is! List ||
          lineRows.isEmpty ||
          lineRows.length > 50000) {
        throw const FormatException();
      }
      final amounts = <String, int>{},
          allocations = <TableCheckoutAllocation>[];
      for (final raw in allocationRows) {
        final a = _object(raw, ['orderRef', 'totalCents', 'inventoryAction']);
        final ref = _ref(a['orderRef']);
        if (!RegExp(r'^D[0-9]{11}$').hasMatch(ref) ||
            amounts.containsKey(ref) ||
            ![
              'issue_reserved',
              'already_issued',
            ].contains(a['inventoryAction'])) {
          throw const FormatException();
        }
        final cents = _integer(a['totalCents'], 100000000);
        amounts[ref] = cents;
        allocations.add(
          TableCheckoutAllocation._(ref, cents, a['inventoryAction'] as String),
        );
      }
      final sums = <String, int>{},
          counts = <String, int>{},
          products = <String>{};
      final lines = <TableCheckoutLine>[];
      for (final raw in lineRows) {
        final l = _object(raw, [
          'orderRef',
          'productRef',
          'quantity',
          'priceCents',
          'names',
          'specifications',
          'revision',
        ]);
        final ref = _ref(l['orderRef']), product = _ref(l['productRef']);
        final qty = _integer(l['quantity'], 1000),
            price = _integer(l['priceCents'], 100000000);
        if (!amounts.containsKey(ref) || !products.add('$ref:$product')) {
          throw const FormatException();
        }
        sums[ref] = (sums[ref] ?? 0) + qty * price;
        counts[ref] = (counts[ref] ?? 0) + 1;
        lines.add(
          TableCheckoutLine._(
            ref,
            product,
            qty,
            price,
            _languages(l['names']),
            _languages(l['specifications']),
            _integer(l['revision'], 9007199254740991),
          ),
        );
      }
      if (amounts.values.fold<int>(0, (a, b) => a + b) != total ||
          amounts.entries.any(
            (e) => sums[e.key] != e.value || (counts[e.key] ?? 0) > 50,
          )) {
        throw const FormatException();
      }
      return TableCheckoutQuote._(
        storeRef,
        tableRef,
        sessionRef,
        channel,
        accountType,
        total,
        hash,
        quoted,
        List.unmodifiable(allocations),
        List.unmodifiable(lines),
      );
    } catch (_) {
      throw const CcsopFailure('TABLE_CHECKOUT_QUOTE_INVALID');
    }
  }
}

/// Persist before preparing; no payer code, balance amount split or session secret.
class TableCheckoutCommand {
  TableCheckoutCommand._(
    this.base,
    this.employeeRef,
    this.deviceId,
    this.storeRef,
    this.tableRef,
    this.sessionRef,
    this.requestId,
    this.channel,
    this.accountType,
    this.totalCents,
    this.fingerprint,
    this.orderCount,
  );
  final String base,
      employeeRef,
      deviceId,
      storeRef,
      tableRef,
      sessionRef,
      requestId,
      channel,
      fingerprint;
  final String? accountType;
  final int totalCents, orderCount;
  factory TableCheckoutCommand.fromQuote(
    StaffSession session,
    TableCheckoutQuote quote, {
    required String requestId,
  }) {
    if (session.storeRef != quote.storeRef) {
      throw const CcsopFailure('TABLE_CHECKOUT_SCOPE_CHANGED');
    }
    return TableCheckoutCommand.decode({
      'base': session.base.toString(),
      'employeeRef': session.employeeRef,
      'deviceId': session.deviceId,
      'storeRef': quote.storeRef,
      'tableRef': quote.tableRef,
      'sessionRef': quote.sessionRef,
      'requestId': requestId,
      'channel': quote.channel,
      'accountType': quote.accountType,
      'currency': 'CNY',
      'expectedTotalCents': quote.totalCents,
      'expectedSnapshotFingerprint': quote.fingerprint,
      'orderCount': quote.allocations.length,
    });
  }
  Map<String, dynamic> get params => {
    'storeRef': storeRef,
    'tableRef': tableRef,
    'sessionRef': sessionRef,
    'requestId': requestId,
    'channel': channel,
    'accountType': accountType,
    'currency': 'CNY',
    'expectedTotalCents': totalCents,
    'expectedSnapshotFingerprint': fingerprint,
  };
  Map<String, dynamic> get encoded => {
    'base': base,
    'employeeRef': employeeRef,
    'deviceId': deviceId,
    ...params,
    'orderCount': orderCount,
  };
  bool belongsTo(StaffSession session) =>
      base == session.base.toString() &&
      employeeRef == session.employeeRef &&
      deviceId == session.deviceId &&
      storeRef == session.storeRef;
  String get permission =>
      channel == 'member_balance' ? 'payment.balance' : 'payment.$channel';
  factory TableCheckoutCommand.decode(Object? raw) {
    try {
      final row = _object(raw, [
        'base',
        'employeeRef',
        'deviceId',
        'storeRef',
        'tableRef',
        'sessionRef',
        'requestId',
        'channel',
        'accountType',
        'currency',
        'expectedTotalCents',
        'expectedSnapshotFingerprint',
        'orderCount',
      ]);
      final base = row['base'];
      if (base is! String) throw const FormatException();
      final uri = Uri.parse(base);
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          row['currency'] != 'CNY') {
        throw const FormatException();
      }
      final employee = _ref(row['employeeRef']),
          hash = row['expectedSnapshotFingerprint'];
      if (!RegExp(r'^E[0-9]{11}$').hasMatch(employee) ||
          hash is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
        throw const FormatException();
      }
      _account(row['channel'], row['accountType']);
      return TableCheckoutCommand._(
        base,
        employee,
        _uuid(row['deviceId']),
        _ref(row['storeRef']),
        _ref(row['tableRef']),
        _ref(row['sessionRef']),
        _uuid(row['requestId']),
        row['channel'] as String,
        row['accountType'] as String?,
        _integer(row['expectedTotalCents'], 100000000),
        hash,
        _integer(row['orderCount'], 1000),
      );
    } catch (_) {
      throw const CcsopFailure('TABLE_CHECKOUT_COMMAND_INVALID');
    }
  }
}
