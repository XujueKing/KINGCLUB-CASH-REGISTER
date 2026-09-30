/// Server-computed full-range summary, never totals of a paginated detail page.
class VoucherReport {
  VoucherReport._(this.amounts, this.counts, this.details, this.nextAfter);
  final Map<String, BigInt> amounts;
  final Map<String, int> counts;
  final List<VoucherReportDetail> details;
  final String? nextAfter;
  static const amountKeys = [
    'assessedGrossCents',
    'feeCents',
    'adjustmentCents',
    'assessedNetCents',
    'openingReceivableCents',
    'reversedReceivableCents',
    'receivedCents',
    'returnedCents',
    'cashNetCents',
    'closingReceivableCents',
    'repayableCents',
    'overdueCents',
  ];
  static const countKeys = [
    'verifiedCount',
    'unvaluedCount',
    'unscheduledCount',
    'unconfirmedDateCount',
  ];
  factory VoucherReport.parse(
    Object? raw, {
    required String storeRef,
    required String from,
    required String to,
    required String provider,
    String? afterVoucher,
  }) {
    if (raw is! Map || raw['result'] is! Map) {
      throw const FormatException('Invalid voucher response envelope');
    }
    raw = raw['result'];
    if (raw is! Map ||
        raw['storeRef'] != storeRef ||
        raw['from'] != from ||
        raw['to'] != to ||
        raw['provider'] != provider ||
        raw['currency'] != 'CNY') {
      throw const FormatException('Voucher report scope mismatch');
    }
    final amounts = <String, BigInt>{};
    for (final key in amountKeys) {
      final value = raw[key];
      if (value is! String ||
          value.length > 40 ||
          !RegExp(r'^-?(0|[1-9][0-9]*)$').hasMatch(value)) {
        throw const FormatException('Invalid voucher amount');
      }
      final cents = BigInt.parse(value);
      if (cents.isNegative &&
          key != 'adjustmentCents' &&
          key != 'cashNetCents') {
        throw const FormatException('Negative voucher amount');
      }
      amounts[key] = cents;
    }
    if (amounts['cashNetCents'] !=
        amounts['receivedCents']! - amounts['returnedCents']!) {
      throw const FormatException('Inconsistent voucher cash total');
    }
    final counts = <String, int>{};
    for (final key in countKeys) {
      final value = raw[key];
      if (value is! int || value < 0 || value > 100000) {
        throw const FormatException('Invalid voucher count');
      }
      counts[key] = value;
    }
    final rows = raw['details'];
    if (rows is! List ||
        rows.length > 50 ||
        !raw.containsKey('nextAfterVoucher')) {
      throw const FormatException('Invalid voucher page');
    }
    final details = rows.map(VoucherReportDetail.parse).toList();
    String? previous = afterVoucher;
    for (final detail in details) {
      if ((previous != null && detail.reference.compareTo(previous) <= 0) ||
          (provider != 'all' && detail.provider != provider)) {
        throw const FormatException('Voucher page scope mismatch');
      }
      previous = detail.reference;
    }
    final next = raw['nextAfterVoucher'];
    if (next != null &&
        (next is! String ||
            details.length != 50 ||
            next != details.last.reference)) {
      throw const FormatException('Invalid voucher cursor');
    }
    return VoucherReport._(
      Map.unmodifiable(amounts),
      Map.unmodifiable(counts),
      List.unmodifiable(details),
      next as String?,
    );
  }
  String money(String key) {
    final value = amounts[key]!,
        absolute = value.abs(),
        hundred = BigInt.from(100);
    return '${value.isNegative ? '-' : ''}${absolute ~/ hundred}.${(absolute % hundred).toString().padLeft(2, '0')}';
  }
}

class VoucherReportDetail {
  VoucherReportDetail._(
    this.reference,
    this.provider,
    this.certificateId,
    this.reversed,
    this.redemptionDay,
    this.expectedDay,
    this.amounts,
  );
  final String reference, provider, certificateId;
  final bool reversed;
  final String? redemptionDay, expectedDay;
  final Map<String, BigInt?> amounts;
  static const amountKeys = [
    'netReceivableCents',
    'outstandingCents',
    'receivedCents',
    'returnedCents',
    'repayableCents',
  ];
  static VoucherReportDetail parse(Object? raw) {
    if (raw is! Map ||
        raw['voucherRef'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(raw['voucherRef'] as String) ||
        !['douyin', 'meituan'].contains(raw['provider']) ||
        raw['certificateId'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$')
            .hasMatch(raw['certificateId'] as String) ||
        raw['reversed'] is! bool ||
        !['confirmed', 'unvalued'].contains(raw['valuationStatus'])) {
      throw const FormatException('Invalid voucher detail');
    }
    String? date(String key) {
      final value = raw[key];
      if (value == null && raw.containsKey(key)) return null;
      if (value is! String ||
          !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
          DateTime.tryParse(value)?.toIso8601String().substring(0, 10) !=
              value) {
        throw const FormatException('Invalid voucher date');
      }
      return value;
    }

    final amounts = <String, BigInt?>{};
    for (final key in amountKeys) {
      final value = raw[key];
      final unknown =
          raw['valuationStatus'] == 'unvalued' &&
          ['netReceivableCents', 'outstandingCents'].contains(key);
      if (unknown) {
        if (!raw.containsKey(key) || value != null) {
          throw const FormatException('Unvalued voucher amount');
        }
        amounts[key] = null;
      } else {
        if (value is! String ||
            value.length > 40 ||
            !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) {
          throw const FormatException('Invalid voucher detail amount');
        }
        amounts[key] = BigInt.parse(value);
      }
    }
    return VoucherReportDetail._(
      raw['voucherRef'] as String,
      raw['provider'] as String,
      raw['certificateId'] as String,
      raw['reversed'] as bool,
      date('redemptionDay'),
      date('expectedDay'),
      Map.unmodifiable(amounts),
    );
  }

  String? money(String key) {
    final cents = amounts[key];
    if (cents == null) return null;
    final hundred = BigInt.from(100);
    return '${cents ~/ hundred}.${(cents % hundred).toString().padLeft(2, '0')}';
  }
}
