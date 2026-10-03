class TogetherAdmission {
  TogetherAdmission._(this.bookingRef, this.usedAt, this.replayed);
  final String bookingRef;
  final DateTime usedAt;
  final bool replayed;
  static final codePattern = RegExp(r'^KCTICKET1:[A-Za-z0-9_-]{43}$');

  factory TogetherAdmission.parse(Object? raw, {required String storeRef}) {
    if (raw is! Map<String, dynamic> ||
        raw['result'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid admission receipt');
    }
    final r = raw['result'] as Map<String, dynamic>;
    final ref = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
    for (final key in ['bookingRef', 'partyRef', 'employeeRef']) {
      if (r[key] is! String || !ref.hasMatch(r[key] as String)) {
        throw const FormatException('Invalid admission reference');
      }
    }
    final used = r['usedAt'] is String ? DateTime.tryParse(r['usedAt']) : null;
    if (r['storeRef'] != storeRef ||
        r['replayed'] is! bool ||
        used == null ||
        !used.isUtc ||
        r['releasedCents'] is! String ||
        !RegExp(r'^(0|[1-9][0-9]{0,17})$').hasMatch(r['releasedCents'])) {
      throw const FormatException('Invalid admission scope');
    }
    return TogetherAdmission._(r['bookingRef'], used, r['replayed']);
  }
}
