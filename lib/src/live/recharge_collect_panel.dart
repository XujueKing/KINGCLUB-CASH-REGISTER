import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'provider_payment.dart';
import 'payment_code_field.dart';
import 'recharge_context.dart';
import 'recharge_result.dart';
import 'recharge_terms_view.dart';
import 'table_snapshot.dart';

/// Original UUID is a locator only. Money/recipient/terms always come from 1935.
class RechargeCollectPanel extends StatefulWidget {
  const RechargeCollectPanel({super.key,required this.auth,required this.language,required this.onBack});
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  @override State<RechargeCollectPanel> createState()=>_RechargeCollectPanelState();
}
class _RechargeCollectPanelState extends State<RechargeCollectPanel> with WidgetsBindingObserver {
  final original=TextEditingController(),payer=TextEditingController();
  RechargeContext? snapshot;
  RechargeResult? result;
  bool busy=false,failed=false,consent=false,attempted=false,foreground=true;
  int epoch=0;
  Timer? expiry;
  String t(String key)=>tr(widget.language,key);
  @override void initState(){
    super.initState();widget.auth.addListener(invalidate);WidgetsBinding.instance.addObserver(this);
    foreground=WidgetsBinding.instance.lifecycleState==null||WidgetsBinding.instance.lifecycleState==AppLifecycleState.resumed;
  }
  void invalidate(){
    epoch++;expiry?.cancel();payer.clear();original.clear();
    if(mounted)setState((){snapshot=null;result=null;consent=false;failed=false;});
  }
  @override void didUpdateWidget(covariant RechargeCollectPanel old){super.didUpdateWidget(old);if(old.auth!=widget.auth){old.auth.removeListener(invalidate);widget.auth.addListener(invalidate);invalidate();}}
  @override void didChangeAppLifecycleState(AppLifecycleState state){foreground=state==AppLifecycleState.resumed;invalidate();}
  @override void dispose(){epoch++;expiry?.cancel();widget.auth.removeListener(invalidate);WidgetsBinding.instance.removeObserver(this);original.dispose();payer.dispose();super.dispose();}
  Future<void> load() async {
    if(busy||!foreground||!validRechargeRef(original.text.trim()))return;
    final ref=original.text.trim(),ticket=++epoch,started=DateTime.now();
    expiry?.cancel();payer.clear();
    setState((){busy=true;failed=false;consent=false;snapshot=null;result=null;attempted=false;});
    try {
      final value=await widget.auth.readRechargeContext(ref);
      final session=widget.auth.session;
      if(!mounted||!foreground||epoch!=ticket||session==null)return;
      final limit=started.add(const Duration(seconds:30));
      final deadline=session.expiresAt.isBefore(limit)?session.expiresAt:limit;
      if(!deadline.isAfter(DateTime.now()))throw StateError('STALE_CONTEXT');
      setState(()=>snapshot=value);
      expiry=Timer(deadline.difference(DateTime.now()),(){
        epoch++;payer.clear();
        if(mounted)setState((){snapshot=null;consent=false;result=null;});
      });
    }catch(_){if(mounted&&epoch==ticket)setState(()=>failed=true);}
    finally{if(mounted)setState(()=>busy=false);}
  }
  Future<void> send() async {
    final value=snapshot;
    if(busy||attempted||!foreground||value==null||!value.unsent||!consent||!validProviderCode(value.channel,payer.text))return;
    final code=payer.text,ticket=epoch;payer.clear();
    setState((){busy=true;attempted=true;failed=false;});
    try {
      final response=await widget.auth.collectRecharge(rechargeRef:value.rechargeRef,channel:value.channel,
        principalCents:value.principalCents,authCode:code,stillCurrent:()=>mounted&&foreground&&epoch==ticket&&identical(snapshot,value));
      if(mounted&&foreground&&epoch==ticket)setState(()=>result=response);
    }catch(_){if(mounted&&epoch==ticket)setState(()=>failed=true);}
    finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context){
    final value=snapshot;
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Padding(padding:const EdgeInsets.all(16),child:Wrap(spacing:16,crossAxisAlignment:WrapCrossAlignment.center,children:[
        OutlinedButton(onPressed:widget.onBack,child:Text(t('ordersBack'))),Text(t('rechargeCollectTitle')),
      ])),
      if(busy)const LinearProgressIndicator(),
      Expanded(child:SingleChildScrollView(padding:const EdgeInsets.all(20),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(t('rechargeLocatorNotice')),
        TextField(controller:original,enabled:foreground&&!busy,enableSuggestions:false,autocorrect:false,
          enableIMEPersonalizedLearning:false,inputFormatters:[LengthLimitingTextInputFormatter(36)],
          onChanged:(_){epoch++;expiry?.cancel();payer.clear();setState((){snapshot=null;result=null;consent=false;});},
          onSubmitted:(_)=>load(),decoration:InputDecoration(labelText:t('rechargeOriginalRef'))),
        OutlinedButton(onPressed:busy||!foreground?null:load,child:Text(t('rechargeReadOriginal'))),
        if(failed)Text(t('rechargeUnavailable')),
        if(value!=null&&foreground)...[
          Text('${t('rechargeMemberRef')}: ${value.memberRef}'),
          Text(value.channel=='wechat'?t('rechargeWechat'):t('rechargeAlipay')),
          Text('${t('rechargePrincipal')}: CNY ${formatCents(value.principalCents)}'),
          Text('${t('rechargeGift')}: CNY ${formatCents(value.giftCents)}'),
          RechargeTermsView(value:value,language:widget.language),
          Text(t('rechargeResumeNotice')),
          if(!value.unsent)Text(t('rechargeUseRecovery')),
          if(value.unsent&&!attempted)...[
            CheckboxListTile(contentPadding:EdgeInsets.zero,value:consent,onChanged:busy?null:(v)=>setState(()=>consent=v==true),title:Text(t('rechargeResumeConsent'))),
            PaymentCodeField(controller:payer,enabled:!busy,label:t('provider_code'),
              onChanged:(_)=>setState((){})),
            FilledButton(onPressed:busy||!consent||!validProviderCode(value.channel,payer.text)?null:send,child:Text(t('rechargeResumeSubmit'))),
          ],
          if(attempted)Text(t('rechargeUseRecovery')),
          if(result!=null)Text(t('rechargeState_${result!.state}')),
        ],
      ]))),
    ]);
  }
}
