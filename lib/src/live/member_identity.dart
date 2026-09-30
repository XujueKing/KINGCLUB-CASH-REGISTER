/// Short-lived identity observation, never permission to seat or charge a member.
class MemberIdentity {
  MemberIdentity._(this.memberRef, this.nickname, this.validFor);
  final String memberRef;
  final String? nickname;
  final Duration validFor;
  static final codePattern = RegExp(r'^KC:M:[0-9A-F]{32}$');

  factory MemberIdentity.parse(
    Object? raw, {
    required String storeRef,
    Duration elapsed = Duration.zero,
  }) {
    if (raw is! Map<String, dynamic> ||
        raw['result'] is! Map<String, dynamic>) {
      throw const FormatException();
    }
    final result = raw['result'] as Map<String, dynamic>;
    if (result['storeRef'] != storeRef ||
        result['purpose'] != 'member_identity' ||
        result['member'] is! Map<String, dynamic>) {
      throw const FormatException();
    }
    final member = result['member'] as Map<String, dynamic>;
    final reference = member['memberRef'], nickname = member['nickname'];
    if (reference is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(reference) ||
        !member.containsKey('nickname') ||
        (nickname != null &&
            (nickname is! String ||
                nickname.trim().isEmpty ||
                nickname.length > 64 ||
                RegExp(r'[\x00-\x1f\x7f]').hasMatch(nickname)))) {
      throw const FormatException();
    }
    DateTime date(String key) {
      final value = result[key];
      if (value is! String) throw const FormatException();
      final parsed = DateTime.parse(value);
      if (!parsed.isUtc || parsed.toIso8601String() != value) {
        throw const FormatException();
      }
      return parsed;
    }

    final duration = date('expiresAt').difference(date('observedAt'));
    if (duration <= Duration.zero ||
        duration > const Duration(minutes: 1) ||
        elapsed.isNegative) {
      throw const FormatException();
    }
    final remaining = duration - elapsed - const Duration(seconds: 2);
    if (remaining <= Duration.zero) throw const FormatException();
    return MemberIdentity._(reference, nickname as String?, remaining);
  }
}
