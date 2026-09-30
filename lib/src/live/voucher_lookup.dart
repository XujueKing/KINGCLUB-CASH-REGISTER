class VoucherLookup {
  VoucherLookup._(this.state, this.rows);
  final String state;
  final List<VoucherLookupRow> rows;
  factory VoucherLookup.parse(
    Object? raw, {
    required String storeRef,
    required String employeeRef,
    required String provider,
    required String requestId,
  }) {
    if (raw is! Map || raw['result'] is! Map) throw const FormatException();
    final result = raw['result'] as Map;
    if (result['storeRef'] != storeRef ||
        result['employeeRef'] != employeeRef ||
        result['provider'] != provider ||
        result['requestId'] != requestId ||
        !['not_observed', 'unknown', 'recorded'].contains(result['state'])) {
      throw const FormatException();
    }
    final state = result['state'] as String;
    if (state != 'recorded') {
      if (result.containsKey('receipt')) throw const FormatException();
      return VoucherLookup._(state, const []);
    }
    final receipt = result['receipt'];
    if (receipt is! Map || receipt['results'] is! List) {
      throw const FormatException();
    }
    final values = receipt['results'] as List;
    if (values.isEmpty || values.length > 50) throw const FormatException();
    final rows = <VoucherLookupRow>[];
    for (final value in values) {
      if (value is! Map ||
          value['result'] is! int ||
          (value['result'] as int).abs() > 9007199254740991) {
        throw const FormatException();
      }
      String? reference(String key) {
        final field = value[key];
        if (field == null) return null;
        if (field is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(field)) {
          throw const FormatException();
        }
        return field;
      }

      final code = value['result'] as int,
          certificate = reference('certificateId'),
          verification = reference('verifyId');
      if (code == 0 && (certificate == null || verification == null)) {
        throw const FormatException();
      }
      rows.add(VoucherLookupRow(code, certificate, verification));
    }
    return VoucherLookup._(state, List.unmodifiable(rows));
  }
}

class VoucherLookupRow {
  const VoucherLookupRow(this.code, this.certificateId, this.verifyId);
  final int code;
  final String? certificateId, verifyId;
}
