import 'package:flutter_test/flutter_test.dart';
import 'package:kingclub_cash_register/src/live/recharge_context.dart';

const original='00000000-0000-4000-8000-000000000001';
Map<String,dynamic> fixture()=>{'result':{'version':1,'rechargeRef':original,'storeRef':'TEST_STORE','memberRef':'TEST_MEMBER',
  'channel':'wechat','currency':'CNY','principalCents':'10000','giftCents':'2000','campaignRef':'TEST_CAMPAIGN','campaignRevision':1,
  'rulesSnapshot':<String,dynamic>{'version':1,'description':'TEST ONLY terms','deductionOrder':'principal_first','maxGiftBasisPoints':2000,'eligibleProductRefs':['TEST_PRODUCT']},
  'giftExpiresAt':'2026-10-01T00:00:00.000Z','createdAt':'2026-09-30T00:00:00.000Z','snapshotAt':'2026-09-30T00:01:00.000Z',
  'paymentStatus':'prepared','creditStatus':'awaiting_payment'}};
RechargeContext parse(Object? value)=>RechargeContext.parse(value,storeRef:'TEST_STORE',rechargeRef:original);
void main(){
  test('keeps original account, split amounts and immutable product rules',(){
    final raw=fixture(),value=parse(raw);
    expect(value.unsent,isTrue);expect(value.memberRef,'TEST_MEMBER');
    expect(value.principalCents,10000);expect(value.giftCents,2000);
    (raw['result']['rulesSnapshot']['eligibleProductRefs'] as List).add('OTHER_PRODUCT');
    expect(value.eligibleProductRefs,['TEST_PRODUCT']);
    expect(()=>value.eligibleProductRefs!.add('OTHER'),throwsUnsupportedError);
  });
  test('rejects wrong scope, amount format, inconsistent states and noncanonical dates',(){
    for(final entry in {'storeRef':'OTHER_STORE','rechargeRef':'00000000-0000-4000-8000-000000000002',
      'principalCents':10000,'giftCents':'-1','creditStatus':'credited','snapshotAt':'2026-02-30T00:00:00.000Z','extra':'TEST'}.entries){
      final raw=fixture();raw['result'][entry.key]=entry.value;expect(()=>parse(raw),throwsA(anything));
    }
  });
  test('rejects duplicate products and display-control characters in terms',(){
    final raw=fixture();raw['result']['rulesSnapshot']['eligibleProductRefs']=['TEST_PRODUCT','TEST_PRODUCT'];
    expect(()=>parse(raw),throwsA(anything));
    final second=fixture();second['result']['rulesSnapshot']['description']='TEST\u202e';
    expect(()=>parse(second),throwsA(anything));
  });
  test('paid but pending credit never becomes an unsent request',(){
    final raw=fixture();raw['result']['paymentStatus']='confirmed';raw['result']['creditStatus']='pending';
    expect(parse(raw).unsent,isFalse);
  });
}
