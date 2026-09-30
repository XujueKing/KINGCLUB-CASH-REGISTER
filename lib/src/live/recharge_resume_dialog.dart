import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'provider_payment.dart';
import 'recharge_journal.dart';
import 'recharge_result.dart';
import 'recharge_context.dart';
import 'recharge_terms_view.dart';
import 'table_snapshot.dart';

/// Only for a persisted original shown as not_sent. Controller rechecks the
/// original at submission, so this UI observation is never authority to debit.
class RechargeResumeDialog extends StatefulWidget {
  const RechargeResumeDialog({super.key,required this.auth,required this.command,required this.language});
  final StaffAuthController auth;
  final RechargeCommand command;
  final UiLanguage language;
  @override State<RechargeResumeDialog> createState()=>_RechargeResumeDialogState();
}
class _RechargeResumeDialogState extends State<RechargeResumeDialog> with WidgetsBindingObserver {
  final code=TextEditingController();
  bool consent=false,busy=false,valid=true,attempted=false,failed=false;
  int epoch=0;
  Timer? expiry;
  RechargeResult? result;
  RechargeContext? original;
  String t(String key)=>tr(widget.language,key);
  @override void initState(){
    super.initState();widget.auth.addListener(invalidate);WidgetsBinding.instance.addObserver(this);
    final session=widget.auth.session;
    valid=(WidgetsBinding.instance.lifecycleState==null||WidgetsBinding.instance.lifecycleState==AppLifecycleState.resumed)&&
      session!=null&&widget.command.belongsTo(session)&&session.permissions.contains(widget.command.permission)&&session.expiresAt.isAfter(DateTime.now());
    if(valid){
      expiry=Timer(session!.expiresAt.difference(DateTime.now()),invalidate);
      unawaited(loadOriginal());
    }
  }
  Future<void> loadOriginal() async {
    final ticket=epoch,started=DateTime.now();
    setState(()=>busy=true);
    try{
      final value=await widget.auth.readRechargeContext(widget.command.rechargeRef);
      if(!mounted||!valid||epoch!=ticket)return;
      if(!value.unsent||value.storeRef!=widget.command.storeRef||value.channel!=widget.command.channel||
        value.principalCents!=widget.command.principalCents||value.rechargeRef!=widget.command.rechargeRef){
        throw StateError('RECHARGE_ORIGINAL_CHANGED');
      }
      final session=widget.auth.session;
      if(session==null)throw StateError('SESSION_EXPIRED');
      final limit=started.add(const Duration(seconds:30));
      final deadline=session.expiresAt.isBefore(limit)?session.expiresAt:limit;
      if(!deadline.isAfter(DateTime.now()))throw StateError('RECHARGE_CONTEXT_EXPIRED');
      expiry?.cancel();expiry=Timer(deadline.difference(DateTime.now()),invalidate);
      setState(()=>original=value);
    }catch(_){if(mounted&&epoch==ticket)invalidate();}
    finally{if(mounted)setState(()=>busy=false);}
  }
  void invalidate(){
    epoch++;expiry?.cancel();code.clear();
    if(mounted)setState((){valid=false;consent=false;result=null;original=null;});
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state){if(state!=AppLifecycleState.resumed)invalidate();}
  @override void didUpdateWidget(covariant RechargeResumeDialog old){
    super.didUpdateWidget(old);
    if(old.auth!=widget.auth){old.auth.removeListener(invalidate);widget.auth.addListener(invalidate);invalidate();}
    if(old.command!=widget.command)invalidate();
  }
  @override void dispose(){epoch++;expiry?.cancel();widget.auth.removeListener(invalidate);WidgetsBinding.instance.removeObserver(this);code.dispose();super.dispose();}
  Future<void> send() async {
    if(!valid||original==null||busy||attempted||!consent||!validProviderCode(widget.command.channel,code.text))return;
    final ticket=epoch,payer=code.text;code.clear();
    setState((){busy=true;attempted=true;failed=false;});
    try {
      final value=await widget.auth.sendUnsentRecharge(widget.command,authCode:payer,
        stillCurrent:()=>mounted&&valid&&epoch==ticket);
      if(mounted&&valid&&epoch==ticket)setState(()=>result=value);
    }catch(_){if(mounted&&valid&&epoch==ticket)setState(()=>failed=true);}
    finally{if(mounted)setState(()=>busy=false);}
  }
  @override Widget build(BuildContext context)=>AlertDialog(
    title:Text(t('rechargeResumeTitle')),
    content:SizedBox(width:520,child:SingleChildScrollView(child:!valid?Text(t('rechargeUnavailable')):
      Column(mainAxisSize:MainAxisSize.min,crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text(widget.command.rechargeRef),
        Text(widget.command.channel=='wechat'?t('rechargeWechat'):t('rechargeAlipay')),
        Text('${t('rechargePrincipal')}: CNY ${formatCents(widget.command.principalCents)}'),
        if(original!=null)...[
          Text('${t('rechargeMemberRef')}: ${original!.memberRef}'),
          Text('${t('rechargeGift')}: CNY ${formatCents(original!.giftCents)}'),
          RechargeTermsView(value:original!,language:widget.language),
        ],
        Text(t('rechargeResumeNotice')),
        if(!attempted&&original!=null)...[
          CheckboxListTile(value:consent,onChanged:busy?null:(value)=>setState(()=>consent=value==true),
            title:Text(t('rechargeResumeConsent')),contentPadding:EdgeInsets.zero),
          TextField(controller:code,enabled:!busy,obscureText:true,enableSuggestions:false,autocorrect:false,
            enableIMEPersonalizedLearning:false,keyboardType:TextInputType.number,
            inputFormatters:[FilteringTextInputFormatter.digitsOnly,LengthLimitingTextInputFormatter(24)],
            onChanged:(_)=>setState((){}),decoration:InputDecoration(labelText:t('provider_code'))),
        ],
        if(busy)const LinearProgressIndicator(),
        if(failed)Text(t('rechargeUnavailable')),
        if(result!=null)Text(t('rechargeState_${result!.state}')),
      ]))),
    actions:[TextButton(onPressed:()=>Navigator.of(context).pop(result),child:Text(t('rechargeClose'))),
      if(valid&&!attempted)FilledButton(onPressed:original!=null&&consent&&!busy&&validProviderCode(widget.command.channel,code.text)?send:null,
        child:Text(t('rechargeResumeSubmit')))],
  );
}
