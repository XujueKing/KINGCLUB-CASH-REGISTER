import 'dart:async';
import 'package:flutter/material.dart';
import 'payment_code_field.dart';
import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'provider_payment.dart';
import 'payment_admission.dart';

/// One payment UI, channel is a choice, not a separate transaction workflow.
class ProviderPaymentPanel extends StatefulWidget {
  const ProviderPaymentPanel({super.key,required this.auth,required this.orderRef,required this.totalCents,required this.language,this.recoveryOnly=false,this.onResolved});
  final StaffAuthController auth;
  final String orderRef;
  final int totalCents;
  final UiLanguage language;
  final bool recoveryOnly;
  final VoidCallback? onResolved;
  @override State<ProviderPaymentPanel> createState()=>_ProviderPaymentPanelState();
}
class _ProviderPaymentPanelState extends State<ProviderPaymentPanel> with WidgetsBindingObserver {
  final code=TextEditingController();
  String channel=const bool.fromEnvironment('CASHIER_PROVIDER',defaultValue:false)?'wechat':'member_balance',status='';
  String? accountType;
  bool get balanceEntry=>pending.any((entry)=>entry.requestId==retryRequest)
    ?pending.firstWhere((entry)=>entry.requestId==retryRequest).query.channel=='member_balance':channel=='member_balance';
  List<ProviderPayment> pending=[];
  String? retryRequest;
  bool busy=false,ready=false,foreground=true,paid=false;
  int epoch=0;
  int loadGeneration=0;
  bool loadingOriginals=false;
  Timer? queryTimer;
  int queryAttempts=0;
  String t(String key)=>tr(widget.language,key);
  @override void initState(){super.initState();foreground=WidgetsBinding.instance.lifecycleState==null||WidgetsBinding.instance.lifecycleState==AppLifecycleState.resumed;WidgetsBinding.instance.addObserver(this);widget.auth.addListener(invalidate);if(foreground)unawaited(load());}
  void invalidate(){epoch++;loadGeneration++;queryTimer?.cancel();queryAttempts=0;code.clear();if(mounted)setState((){ready=false;loadingOriginals=false;pending=[];status='';retryRequest=null;paid=false;accountType=null;});if(foreground&&!busy)unawaited(load());}
  @override void didChangeAppLifecycleState(AppLifecycleState state){foreground=state==AppLifecycleState.resumed;invalidate();}
  @override void didUpdateWidget(covariant ProviderPaymentPanel old) {
    super.didUpdateWidget(old);
    if(old.auth!=widget.auth||old.orderRef!=widget.orderRef||old.totalCents!=widget.totalCents) {
      old.auth.removeListener(invalidate);widget.auth.addListener(invalidate);invalidate();
    }
  }
  @override void dispose(){epoch++;queryTimer?.cancel();widget.auth.removeListener(invalidate);WidgetsBinding.instance.removeObserver(this);code.dispose();super.dispose();}
  bool current(int e)=>mounted&&foreground&&epoch==e;
  Future<void> load({bool clearMessage=false}) async {
    if(!mounted||!foreground)return;
    final e=epoch,generation=++loadGeneration,auth=widget.auth,identity=widget.auth.session,order=widget.orderRef;
    bool valid()=>current(e)&&generation==loadGeneration&&identical(auth,widget.auth)&&identical(identity,auth.session);
    setState((){ready=false;loadingOriginals=true;if(clearMessage)status='';});
    try {
      if(identity==null)throw StateError('SESSION_REQUIRED');
      final entries=<ProviderPayment>[];
      for(final c in ['wechat','alipay','member_balance']) {
        if(!valid())return;
        if(identity.permissions.contains(paymentPermissions[c]))entries.addAll(await auth.pendingProviderPayments(c));
        if(!valid())return;
      }
      if(valid())setState((){pending=entries.where((v)=>v.params['orderRef']==order).toList();ready=true;});
    } catch(_){if(valid())setState((){ready=false;pending=[];status=t('provider_review');});}
    finally{if(valid())setState(()=>loadingOriginals=false);}
  }
  Future<void> run({ProviderPayment? original,bool retry=false,bool automatic=false}) async {
    if(busy||!ready||!foreground||(original==null&&widget.recoveryOnly))return;
    queryTimer?.cancel();if(!automatic)queryAttempts=0;
    final e=epoch,payerCode=code.text;code.clear();setState(()=>busy=true);
    bool unresolved=false;
    try {
      final result=original==null?await widget.auth.collectProvider(orderRef:widget.orderRef,channel:channel,totalCents:widget.totalCents,
        authCode:payerCode,accountType:channel=='member_balance'?accountType:null,stillCurrent:()=>current(e)):retry?await widget.auth.retryOriginalProvider(original,authCode:payerCode,stillCurrent:()=>current(e)):await widget.auth.queryProvider(original);
      if(current(e)) {
        setState((){paid=result.resolved;status=t(result.refunded?'provider_balance_refunded':'provider_${result.state}');
        retryRequest=original!=null&&['not_sent','not_observed'].contains(result.state)?original.requestId:null;});
      }
      if(current(e)&&result.resolved)widget.onResolved?.call();
      unresolved=['pending','unknown'].contains(result.state);
    } catch(_){unresolved=true;if(current(e))setState(()=>status=t('provider_review'));}
    finally {
      if(mounted)setState(()=>busy=false);if(mounted&&foreground)await load();
      if(current(e)&&ready&&unresolved&&pending.length==1&&queryAttempts<6) {
        final saved=pending.single;queryAttempts++;
        queryTimer=Timer(const Duration(seconds:10),(){if(current(e)&&ready&&!busy)unawaited(run(original:saved,automatic:true));});
      }
    }
  }
  @override Widget build(BuildContext context)=>Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    Text(t('provider_title')),
    if(busy||loadingOriginals)const LinearProgressIndicator(),
    if(!ready&&!busy&&!loadingOriginals&&foreground)
      OutlinedButton(onPressed:()=>unawaited(load(clearMessage:true)),child:Text(t('ordersRefresh'))),
    if(pending.isEmpty&&!paid&&!widget.recoveryOnly)...[
      Wrap(spacing:12,children:[for(final c in [if(const bool.fromEnvironment('CASHIER_PROVIDER',defaultValue:false))...['wechat','alipay'],if(const bool.fromEnvironment('CASHIER_BALANCE',defaultValue:false))'member_balance'])ChoiceChip(label:Text(t('provider_$c')),selected:channel==c,
        onSelected:busy||!ready||!foreground||widget.auth.session?.permissions.contains(paymentPermissions[c])!=true?null:(_)=>setState((){channel=c;accountType=null;code.clear();}))]),
      if(channel=='member_balance')...[
        Text(t('balance_account_notice')),
        Wrap(spacing:12,children:[for(final account in ['store_balance','platform_cash'])ChoiceChip(label:Text(t('balance_$account')),selected:accountType==account,
          onSelected:busy||!ready||!foreground?null:(_)=>setState((){accountType=account;code.clear();}))]),
      ],
      PaymentCodeField(controller:code,enabled:ready&&!busy&&foreground,label:t('provider_code')),
      FilledButton(onPressed:ready&&!busy&&foreground&&(channel!='member_balance'||accountType!=null)&&widget.auth.session?.permissions.contains(paymentPermissions[channel])==true?()=>unawaited(run()):null,child:Text(t('provider_collect'))),
    ] else ...[for(final original in pending)OutlinedButton(onPressed:busy||!ready||!foreground?null:()=>unawaited(run(original:original)),
      child:Text('${t('provider_query')} · ${original.requestId}'))],
    if(pending.any((e)=>e.requestId==retryRequest))...[
      if(balanceEntry)Text(t('balance_${pending.firstWhere((e)=>e.requestId==retryRequest).accountType}')),
      PaymentCodeField(controller:code,enabled:ready&&!busy&&foreground,label:t('provider_code')),
      OutlinedButton(onPressed:ready&&!busy&&foreground?()=>unawaited(run(original:pending.firstWhere((e)=>e.requestId==retryRequest),retry:true)):null,
        child:Text(t('provider_retry'))),
    ],
    if(status.isNotEmpty)Text(status),
  ]));
}
