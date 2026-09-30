import 'package:flutter/material.dart';
import '../strings.dart';
import 'recharge_context.dart';

/// Shared original terms; null eligibility means all, an empty list means none.
class RechargeTermsView extends StatelessWidget {
  const RechargeTermsView({super.key,required this.value,required this.language});
  final RechargeContext value;
  final UiLanguage language;
  String t(String key)=>tr(language,key);
  @override Widget build(BuildContext context){
    final cap=value.maxGiftBasisPoints,products=value.eligibleProductRefs;
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text('${value.campaignRef} / ${value.campaignRevision}'),
      Text(value.description),
      Text(t('recharge_${value.deductionOrder}')),
      Text('${t('rechargeGiftCap')}: ${cap~/100}.${(cap%100).toString().padLeft(2,'0')}%'),
      Text('${t('rechargeProducts')}: ${products==null?t('rechargeAllProducts'):products.isEmpty?t('rechargeNoProducts'):products.join(', ')}'),
      Text('${t('rechargeGiftExpiry')}: ${value.giftExpiresAt?.toIso8601String()??t('rechargeNoExpiry')}'),
    ]);
  }
}
