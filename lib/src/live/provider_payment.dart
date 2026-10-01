import 'dart:convert';
import 'dart:math';
import '../auth/session_vault.dart';
import '../auth/staff_session.dart';
import '../network/ccsop_client.dart';
import 'payment_admission.dart';

bool validProviderCode(String channel,String value)=>switch(channel){
  'wechat'=>RegExp(r'^1[0-5][0-9]{16}$').hasMatch(value),
  'alipay'=>RegExp(r'^(?:2[5-9]|30)[0-9]{14,22}$').hasMatch(value),
  'member_balance'=>RegExp(r'^KCPAY1:[A-Za-z0-9_-]{43}$').hasMatch(value),
  _=>false,
};

/// Same command for both channels. Payer code is deliberately not a field.
class ProviderPayment {
  ProviderPayment(this.query,{this.accountType}) {
    if(query.channel=='member_balance'?!['platform_cash','store_balance'].contains(accountType):accountType!=null) {
      throw const CcsopFailure('PAYMENT_ACCOUNT_INVALID');
    }
  }
  final PaymentAdmissionQuery query;
  final String? accountType;
  Map<String,dynamic> get params => {...query.params,if(accountType!=null)'accountType':accountType};
  String get requestId => query.requestId;
  factory ProviderPayment.create(StaffSession identity,String order,String channel,int cents,{String? accountType}) {
    final random=Random.secure();
    final bytes=List.generate(16,(_)=>random.nextInt(256));
    bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;
    final hex=bytes.map((v)=>v.toRadixString(16).padLeft(2,'0')).join();
    return ProviderPayment(PaymentAdmissionQuery.original(identity:identity,orderRef:order,
      requestId:'${hex.substring(0,8)}-${hex.substring(8,12)}-${hex.substring(12,16)}-${hex.substring(16,20)}-${hex.substring(20)}',
      channel:channel,expectedTotalCents:cents,currency:'CNY'),accountType:accountType);
  }
}

class ProviderPaymentResult {
  ProviderPaymentResult._(this.state, {this.refunded = false});
  final String state;
  final bool refunded;
  bool get confirmed => state=='confirmed';
  bool get closedUnpaid => state=='closed_unpaid';
  bool get resolved => confirmed || refunded || closedUnpaid;
  factory ProviderPaymentResult.parse(dynamic raw,ProviderPayment command) {
    // Encrypted super-interface payload is {result: ...}, as for other commands.
    raw=raw is Map?raw['result']:null;
    if(raw is! Map || raw['requestId']!=command.requestId ||
      !['confirmed','pending','unknown','closed_or_refunded','closed_unpaid','not_sent','not_observed'].contains(raw['state'])) {
      throw const CcsopFailure('PROVIDER_RECEIPT_INVALID');
    }
    if(raw['state']=='closed_unpaid') {
      final r=raw['receipt'],p=command.params;
      if(raw.length!=3 || !['wechat','alipay','member_balance'].contains(command.query.channel) ||
        r is! Map || r.length!=(command.query.channel=='member_balance'?10:9) ||
        (command.query.channel=='member_balance'&&r['accountType']!=command.accountType) || r['storeRef']!=p['storeRef'] || r['orderRef']!=p['orderRef'] ||
        r['requestId']!=command.requestId || r['channel']!=p['channel'] || r['currency']!='CNY' ||
        r['totalCents'] is! int || r['totalCents']!=p['expectedTotalCents'] ||
        r['closedBy']!=command.query.employeeRef || r['closureStatus']!='closed_unpaid' ||
        r['intentRef'] is! String || !uuidPattern.hasMatch(r['intentRef'])) {
        throw const CcsopFailure('PROVIDER_RECEIPT_INVALID');
      }
      return ProviderPaymentResult._('closed_unpaid');
    }
    if(raw['state']=='closed_or_refunded' && command.query.channel=='member_balance') {
      if(raw.length!=4 || raw['intentRef'] is! String || !uuidPattern.hasMatch(raw['intentRef']) ||
        raw['refundRef'] is! String || !uuidPattern.hasMatch(raw['refundRef'])) {
        throw const CcsopFailure('PROVIDER_RECEIPT_INVALID');
      }
      return ProviderPaymentResult._('closed_or_refunded',refunded:true);
    }
    if(raw['state']=='confirmed') {
      final r=raw['receipt'],p=command.params;
      if(command.query.channel=='member_balance') {
        if(r is! Map||r.length!=14||r['storeRef']!=p['storeRef']||r['orderRef']!=p['orderRef']||r['channel']!='member_balance'||
          r['accountType']!=command.accountType||r['totalCents'] is! int||r['totalCents']!=p['expectedTotalCents']||r['currency']!='CNY'||
          r['userAccount'] is! String||!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(r['userAccount'])||
          r['confirmedBy']!=command.query.employeeRef||r['confirmationStatus']!='confirmed'||
          r['intentRef'] is! String||!uuidPattern.hasMatch(r['intentRef'])||r['grantRef'] is! String||!uuidPattern.hasMatch(r['grantRef'])||
          r['paymentRef']!='balance:${r['intentRef']}'||r['principalCents'] is! int||r['giftCents'] is! int||
          r['principalCents']<0||r['giftCents']<0||r['principalCents']+r['giftCents']!=p['expectedTotalCents']||
          (command.accountType=='platform_cash'&&r['giftCents']!=0)) {
          throw const CcsopFailure('PROVIDER_RECEIPT_INVALID');
        }
        return ProviderPaymentResult._('confirmed');
      }
      if(r is! Map || r.length!=11 || r['storeRef']!=p['storeRef'] || r['orderRef']!=p['orderRef'] ||
        r['channel']!=p['channel'] || r['totalCents'] is! int || r['totalCents']!=p['expectedTotalCents'] || r['currency']!='CNY' ||
        r['confirmedBy']!=command.query.employeeRef || r['confirmationStatus']!='confirmed' ||
        r['intentRef'] is! String || !uuidPattern.hasMatch(r['intentRef']) ||
        r['outTradeNo'] is! String || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(r['outTradeNo']) ||
        r['transactionId'] is! String || !RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(r['transactionId']) ||
        r['paymentRef']!='${p['channel']}:${r['transactionId']}') {
        throw const CcsopFailure('PROVIDER_RECEIPT_INVALID');
      }
    }
    return ProviderPaymentResult._(raw['state'] as String);
  }
}

/// Write/read-back before a money request. Keep unresolved requests across restarts;
/// never persist a payer code, never erase another employee's pending collection.
class ProviderPaymentJournal {
  ProviderPaymentJournal({SecretStorage? storage}):_storage=storage??PlatformSecretStorage();
  final SecretStorage _storage;
  static Future<void> _tail=Future.value();
  static const key='pending_staff_provider_v1';
  Future<T> _serial<T>(Future<T> Function() work) {
    final task=_tail.then((_) async {
      try{return await work();}on CcsopFailure{rethrow;}catch(_){throw const CcsopFailure('PROVIDER_JOURNAL_UNAVAILABLE');}
    });
    _tail=task.then<void>((_) {},onError:(Object _,StackTrace _) {});return task;
  }
  Future<List<Map<String,dynamic>>> _read() async {
    final raw=await _storage.read(key);if(raw==null)return [];
    if(raw.length>1000000)throw const CcsopFailure('PROVIDER_JOURNAL_INVALID');
    final v=jsonDecode(raw);
    if(v is! List || v.length>100) {
      throw const CcsopFailure('PROVIDER_JOURNAL_INVALID');
    }
    final requests=<String>{},orders=<String>{};
    for(final e in v) {
      if(e is! Map || e.length!=4 || !e.keys.toSet().containsAll(['base','employeeRef','deviceId','params']) ||
        e['base'] is! String || e['employeeRef'] is! String || !RegExp(r'^E[0-9]{11}$').hasMatch(e['employeeRef']) ||
        e['deviceId'] is! String || !uuidPattern.hasMatch(e['deviceId']) || e['params'] is! Map) {
        throw const CcsopFailure('PROVIDER_JOURNAL_INVALID');
      }
      final base=Uri.tryParse(e['base'] as String),p=e['params'] as Map;
      if(base==null||base.scheme!='https'||base.host.isEmpty||base.userInfo.isNotEmpty||base.hasQuery||base.hasFragment||
        p.length!=(p['channel']=='member_balance'?7:6)||!p.keys.toSet().containsAll(['storeRef','orderRef','requestId','channel','expectedTotalCents','currency'])||
        (p['channel']=='member_balance'&&!['platform_cash','store_balance'].contains(p['accountType']))||
        p['storeRef'] is! String||!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(p['storeRef'])||
        p['orderRef'] is! String||!RegExp(r'^D[0-9]{11}$').hasMatch(p['orderRef'])||
        p['requestId'] is! String||!uuidPattern.hasMatch(p['requestId'])||p['requestId']!=(p['requestId'] as String).toLowerCase()||
        !['wechat','alipay','member_balance'].contains(p['channel'])||p['currency']!='CNY'||p['expectedTotalCents'] is! int||
        (p['expectedTotalCents'] as int)<1||(p['expectedTotalCents'] as int)>100000000||
        !requests.add(jsonEncode([e['base'],e['employeeRef'],p['requestId']]))||
        !orders.add(jsonEncode([e['base'],p['storeRef'],p['orderRef']]))) {
        throw const CcsopFailure('PROVIDER_JOURNAL_INVALID');
      }
    }
    return v.map((e)=>Map<String,dynamic>.from(e as Map)).toList();
  }
  bool _owns(Map<String,dynamic> e,StaffSession s)=>e['base']==s.base.toString()&&e['employeeRef']==s.employeeRef&&e['deviceId']==s.deviceId&&e['params']['storeRef']==s.storeRef;
  Future<void> _write(List<Map<String,dynamic>> entries) async {
    final encoded=jsonEncode(entries);if(encoded.length>1000000)throw const CcsopFailure('PROVIDER_JOURNAL_FULL');await _storage.write(key,encoded);
    if(await _storage.read(key)!=encoded)throw const CcsopFailure('PROVIDER_JOURNAL_UNAVAILABLE');
  }
  Future<List<ProviderPayment>> load(StaffSession s)=>_serial(() async {
    final entries=await _read();return entries.where((e)=>_owns(e,s)).map((e){
      final p=e['params'];return ProviderPayment(PaymentAdmissionQuery.original(identity:s,orderRef:p['orderRef'],
        requestId:p['requestId'],channel:p['channel'],expectedTotalCents:p['expectedTotalCents'],currency:p['currency']),accountType:p['accountType'] as String?);
    }).toList();
  });
  Future<void> save(StaffSession s,ProviderPayment command)=>_serial(() async {
    if(!command.query.belongsTo(s)||!['wechat','alipay','member_balance'].contains(command.query.channel))throw const CcsopFailure('PROVIDER_SCOPE_CHANGED');
    final entries=await _read();
    if(entries.length>=100)throw const CcsopFailure('PROVIDER_JOURNAL_FULL');
    if(entries.any((e)=>e['base']==s.base.toString()&&e['params']['storeRef']==s.storeRef&&e['params']['orderRef']==command.params['orderRef'])) {
      throw const CcsopFailure('PROVIDER_ORIGINAL_REQUEST_REQUIRED');
    }
    entries.add({'base':s.base.toString(),'employeeRef':s.employeeRef,'deviceId':s.deviceId,'params':command.params});await _write(entries);
  });
  Future<void> acknowledge(StaffSession s,ProviderPayment command)=>_serial(() async {
    if(!command.query.belongsTo(s))throw const CcsopFailure('PROVIDER_SCOPE_CHANGED');
    final entries=await _read();
    final matches=entries.where((e)=>_owns(e,s)&&e['params']['requestId']==command.requestId).toList();
    if(matches.length!=1||jsonEncode(matches.single['params'])!=jsonEncode(command.params))throw const CcsopFailure('PROVIDER_JOURNAL_CHANGED');
    entries.remove(matches.single);await _write(entries);
  });
}
