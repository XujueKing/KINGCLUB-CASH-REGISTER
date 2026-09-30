import 'dart:convert';
import '../auth/session_vault.dart';
import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import 'recharge_result.dart';

/// Frozen command scope only. Neither payer code nor member credentials belong here.
class RechargeCommand {
  RechargeCommand({required this.base, required this.employeeRef, required this.deviceId,
    required this.storeRef, required this.rechargeRef, required this.channel, required this.principalCents}) {
    final uri = Uri.tryParse(base);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty ||
        uri.hasQuery || uri.hasFragment || !RegExp(r'^E[0-9]{11}$').hasMatch(employeeRef) ||
        !uuidPattern.hasMatch(deviceId) || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(storeRef) ||
        !validRechargeRef(rechargeRef) || !['wechat','alipay'].contains(channel) ||
        principalCents < 1 || principalCents > 100000000) {
      throw const CcsopFailure('RECHARGE_COMMAND_INVALID');
    }
  }
  factory RechargeCommand.forSession(StaffSession session, {required String rechargeRef,
    required String channel, required int principalCents}) => RechargeCommand(
      base: session.base.toString(), employeeRef: session.employeeRef, deviceId: session.deviceId,
      storeRef: session.storeRef, rechargeRef: rechargeRef, channel: channel, principalCents: principalCents);
  final String base, employeeRef, deviceId, storeRef, rechargeRef, channel;
  final int principalCents;
  String get permission => 'payment.$channel';
  bool belongsTo(StaffSession session) => base == session.base.toString() && employeeRef == session.employeeRef &&
    deviceId == session.deviceId && storeRef == session.storeRef;
  Map<String,dynamic> get params => {'storeRef': storeRef, 'rechargeRef': rechargeRef,
    'channel': channel, 'expectedPrincipalCents': principalCents};
  Map<String,dynamic> get encoded => {'base': base, 'employeeRef': employeeRef,
    'deviceId': deviceId, ...params};
  String get identity => jsonEncode([base,storeRef,rechargeRef]);
  factory RechargeCommand.decode(Object? value) {
    if (value is! Map<String,dynamic> || value.length != 7 || !value.keys.toSet().containsAll(
      ['base','employeeRef','deviceId','storeRef','rechargeRef','channel','expectedPrincipalCents']) ||
      value['expectedPrincipalCents'] is! int ||
      ['base','employeeRef','deviceId','storeRef','rechargeRef','channel'].any((k) => value[k] is! String)) {
      throw const CcsopFailure('RECHARGE_COMMAND_INVALID');
    }
    return RechargeCommand(base:value['base'],employeeRef:value['employeeRef'],deviceId:value['deviceId'],
      storeRef:value['storeRef'],rechargeRef:value['rechargeRef'],channel:value['channel'],principalCents:value['expectedPrincipalCents']);
  }
}

/// Durable before first send; serialized across controller instances. No logout
/// clear operation. Ambiguous/paid-pending/review rows stay until verified credit.
class RechargeJournal {
  RechargeJournal({SecretStorage? storage}) : _storage = storage ?? PlatformSecretStorage();
  final SecretStorage _storage;
  static const key = 'pending_staff_recharge_v1';
  static Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _tail.then((_) async {
      try { return await work(); } on CcsopFailure { rethrow; }
      catch (_) { throw const CcsopFailure('RECHARGE_JOURNAL_UNAVAILABLE'); }
    });
    _tail = next.then<void>((_) {}, onError: (Object _,StackTrace _) {});
    return next;
  }
  Future<List<RechargeCommand>> _read() async {
    final text = await _storage.read(key);
    if (text == null) return [];
    if (text.length > 1000000) throw const CcsopFailure('RECHARGE_JOURNAL_INVALID');
    final raw = jsonDecode(text);
    if (raw is! List || raw.length > 100) throw const CcsopFailure('RECHARGE_JOURNAL_INVALID');
    final rows = raw.map(RechargeCommand.decode).toList();
    if (rows.map((e) => e.identity).toSet().length != rows.length) throw const CcsopFailure('RECHARGE_JOURNAL_INVALID');
    return rows;
  }
  Future<void> _write(List<RechargeCommand> entries) async {
    final encoded = jsonEncode(entries.map((e) => e.encoded).toList());
    if (encoded.length > 1000000) throw const CcsopFailure('RECHARGE_JOURNAL_FULL');
    await _storage.write(key,encoded);
    if (await _storage.read(key) != encoded) throw const CcsopFailure('RECHARGE_JOURNAL_UNAVAILABLE');
  }
  Future<List<RechargeCommand>> load(StaffSession session) => _serial(() async =>
    List.unmodifiable((await _read()).where((row) => row.belongsTo(session))));
  Future<void> save(StaffSession session,RechargeCommand command) => _serial(() async {
    if (!command.belongsTo(session)) throw const CcsopFailure('RECHARGE_SCOPE_CHANGED');
    final entries = await _read();
    if (entries.any((e) => e.identity == command.identity)) throw const CcsopFailure('RECHARGE_ORIGINAL_REQUEST_REQUIRED');
    if (entries.length >= 100) throw const CcsopFailure('RECHARGE_JOURNAL_FULL');
    entries.add(command); await _write(entries);
  });
  Future<void> acknowledge(StaffSession session,RechargeCommand command,RechargeResult result) => _serial(() async {
    if (!command.belongsTo(session) || !result.credited || result.storeRef != command.storeRef || result.rechargeRef != command.rechargeRef ||
        result.principalCents != command.principalCents) {
      throw const CcsopFailure('RECHARGE_RECEIPT_REQUIRED');
    }
    final entries = await _read(), matches = entries.where((e) => e.identity == command.identity).toList();
    if (matches.length != 1 || jsonEncode(matches.single.encoded) != jsonEncode(command.encoded)) {
      throw const CcsopFailure('RECHARGE_JOURNAL_CHANGED');
    }
    entries.remove(matches.single); await _write(entries);
  });
}
