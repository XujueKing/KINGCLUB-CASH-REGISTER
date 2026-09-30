import '../network/ccsop_client.dart';
import 'recharge_result.dart';

Map<String,dynamic> _object(Object? raw,List<String> keys) {
  if(raw is! Map<String,dynamic>||raw.length!=keys.length||!raw.keys.toSet().containsAll(keys))throw const FormatException();
  return raw;
}
String _ref(Object? raw) {
  if(raw is! String||!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(raw))throw const FormatException();
  return raw;
}
int _cents(Object? raw,{bool positive=false}) {
  if(raw is! String||!RegExp(r'^(0|[1-9][0-9]{0,8})$').hasMatch(raw))throw const FormatException();
  final value=int.parse(raw);
  if(value>100000000||(positive&&value==0))throw const FormatException();
  return value;
}
DateTime _time(Object? raw) {
  if(raw is! String||!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$').hasMatch(raw))throw const FormatException();
  final value=DateTime.parse(raw);
  if(value.toIso8601String()!=raw)throw const FormatException();
  return value;
}

/// In-memory original terms only. UI must clear on session/lifecycle invalidation;
/// preview is not proof of payment or authority to change the recipient/offer.
class RechargeContext {
  RechargeContext._(Map<String,dynamic> row)
    : rechargeRef=_ref(row['rechargeRef']),storeRef=_ref(row['storeRef']),memberRef=_ref(row['memberRef']),
      channel=row['channel'] as String,principalCents=_cents(row['principalCents'],positive:true),giftCents=_cents(row['giftCents']),
      campaignRef=_ref(row['campaignRef']),campaignRevision=row['campaignRevision'] as int,
      createdAt=_time(row['createdAt']),snapshotAt=_time(row['snapshotAt']),
      giftExpiresAt=row['giftExpiresAt']==null?null:_time(row['giftExpiresAt']),
      paymentStatus=row['paymentStatus'] as String,creditStatus=row['creditStatus'] as String,
      description=(row['rulesSnapshot'] as Map)['description'] as String,
      deductionOrder=(row['rulesSnapshot'] as Map)['deductionOrder'] as String,
      maxGiftBasisPoints=(row['rulesSnapshot'] as Map)['maxGiftBasisPoints'] as int,
      eligibleProductRefs=(row['rulesSnapshot'] as Map)['eligibleProductRefs']==null?null:
        List<String>.unmodifiable(((row['rulesSnapshot'] as Map)['eligibleProductRefs'] as List).cast<String>());
  final String rechargeRef,storeRef,memberRef,channel,campaignRef,paymentStatus,creditStatus,description,deductionOrder;
  final int principalCents,giftCents,campaignRevision,maxGiftBasisPoints;
  final DateTime createdAt,snapshotAt;
  final DateTime? giftExpiresAt;
  final List<String>? eligibleProductRefs;
  bool get unsent=>paymentStatus=='prepared'&&creditStatus=='awaiting_payment';

  factory RechargeContext.parse(Object? raw,{required String storeRef,required String rechargeRef}) {
    try {
      final row=_object(_object(raw,['result'])['result'],['version','rechargeRef','storeRef','memberRef','channel','currency',
        'principalCents','giftCents','campaignRef','campaignRevision','rulesSnapshot','giftExpiresAt','createdAt','snapshotAt','paymentStatus','creditStatus']);
      if(!validRechargeRef(rechargeRef)||row['rechargeRef']!=rechargeRef||row['storeRef']!=storeRef||row['version']!=1||
        row['currency']!='CNY'||!['wechat','alipay'].contains(row['channel'])||row['campaignRevision'] is! int||
        (row['campaignRevision'] as int)<1||(row['campaignRevision'] as int)>9007199254740991||
        !['prepared','pending','unknown','confirmed','closed'].contains(row['paymentStatus'])||
        !['awaiting_payment','pending','credited'].contains(row['creditStatus'])||
        (row['paymentStatus']=='confirmed')==(row['creditStatus']=='awaiting_payment')) {
        throw const FormatException();
      }
      final rules=_object(row['rulesSnapshot'],['version','description','deductionOrder','maxGiftBasisPoints','eligibleProductRefs']);
      if(rules['version']!=1||rules['description'] is! String||(rules['description'] as String).trim().isEmpty||
        (rules['description'] as String).length>4000||
        RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]').hasMatch(rules['description'] as String)||
        !['principal_first','gift_first'].contains(rules['deductionOrder'])||rules['maxGiftBasisPoints'] is! int||
        (rules['maxGiftBasisPoints'] as int)<0||(rules['maxGiftBasisPoints'] as int)>10000) {
        throw const FormatException();
      }
      final products=rules['eligibleProductRefs'];
      if(products!=null) {
        if(products is! List||products.length>1000||products.map(_ref).toSet().length!=products.length)throw const FormatException();
      }
      final result=RechargeContext._(row);
      if(result.snapshotAt.isBefore(result.createdAt)||
        (result.giftExpiresAt!=null&&!result.giftExpiresAt!.isAfter(result.createdAt))) {
        throw const FormatException();
      }
      return result;
    }catch(_){throw const CcsopFailure('RECHARGE_CONTEXT_INVALID');}
  }
}
