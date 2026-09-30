import 'dart:async';
import 'package:flutter/material.dart';
import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'recharge_journal.dart';
import 'recharge_result.dart';
import 'recharge_resume_dialog.dart';
import 'table_snapshot.dart';

/// Explicit query-only recovery. No payer input, pay call or automatic polling.
class RechargeRecoveryPanel extends StatefulWidget {
  const RechargeRecoveryPanel({super.key,required this.auth,required this.language,required this.onBack});
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  @override State<RechargeRecoveryPanel> createState()=>_RechargeRecoveryPanelState();
}
class _RechargeRecoveryPanelState extends State<RechargeRecoveryPanel> with WidgetsBindingObserver {
  List<RechargeCommand> entries=[];
  final results=<String,RechargeResult>{};
  bool loading=false,failed=false,foreground=true,querying=false,opening=false;
  int epoch=0;
  Timer? expiry;
  String t(String key)=>tr(widget.language,key);
  @override void initState(){
    super.initState();widget.auth.addListener(invalidate);WidgetsBinding.instance.addObserver(this);
    foreground=WidgetsBinding.instance.lifecycleState==null||WidgetsBinding.instance.lifecycleState==AppLifecycleState.resumed;
    if(foreground)unawaited(load());
  }
  void invalidate(){
    epoch++;expiry?.cancel();
    if(!mounted)return;
    setState((){entries=[];results.clear();loading=false;querying=false;failed=false;});
    if(foreground)unawaited(load());
  }
  @override void didUpdateWidget(covariant RechargeRecoveryPanel old){
    super.didUpdateWidget(old);
    if(old.auth!=widget.auth){old.auth.removeListener(invalidate);widget.auth.addListener(invalidate);invalidate();}
  }
  @override void didChangeAppLifecycleState(AppLifecycleState state){foreground=state==AppLifecycleState.resumed;invalidate();}
  @override void dispose(){epoch++;expiry?.cancel();widget.auth.removeListener(invalidate);WidgetsBinding.instance.removeObserver(this);super.dispose();}
  Future<void> load() async {
    if(!mounted||!foreground)return;
    final ticket=++epoch;expiry?.cancel();
    setState((){loading=true;failed=false;entries=[];results.clear();});
    try {
      final session=widget.auth.session;
      if(session==null||!session.expiresAt.isAfter(DateTime.now()))throw StateError('SESSION_REQUIRED');
      expiry=Timer(session.expiresAt.difference(DateTime.now()),(){
        epoch++;
        if(mounted)setState((){entries=[];results.clear();failed=true;loading=false;querying=false;});
      });
      final items=<RechargeCommand>[];
      for(final channel in ['wechat','alipay']) {
        if(session.permissions.contains('payment.$channel'))items.addAll(await widget.auth.pendingRecharges(channel));
      }
      if(mounted&&foreground&&epoch==ticket)setState(()=>entries=items);
    }catch(_){if(mounted&&epoch==ticket)setState(()=>failed=true);}
    finally{if(mounted&&epoch==ticket)setState(()=>loading=false);}
  }
  Future<void> query(RechargeCommand command) async {
    if(loading||querying||!foreground||!entries.contains(command))return;
    final ticket=epoch;
    setState((){querying=true;failed=false;results.remove(command.identity);});
    try {
      final result=await widget.auth.recoverRecharge(command);
      if(mounted&&foreground&&epoch==ticket)setState(()=>results[command.identity]=result);
    }catch(_){if(mounted&&epoch==ticket)setState(()=>failed=true);}
    finally{if(mounted&&epoch==ticket)setState(()=>querying=false);}
  }
  Future<void> resume(RechargeCommand command) async {
    if(opening||querying||loading||!foreground||results[command.identity]?.state!='not_sent')return;
    setState(()=>opening=true);
    try {
      await showDialog<RechargeResult>(context:context,barrierDismissible:false,builder:(_)=>
        RechargeResumeDialog(auth:widget.auth,command:command,language:widget.language));
    }finally{if(mounted){setState(()=>opening=false);if(foreground)await load();}}
  }
  @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    Padding(padding:const EdgeInsets.all(16),child:Wrap(spacing:12,runSpacing:8,crossAxisAlignment:WrapCrossAlignment.center,children:[
      OutlinedButton(onPressed:opening?null:widget.onBack,child:Text(t('ordersBack'))),Text(t('rechargeRecoveryTitle')),
      OutlinedButton(onPressed:loading||querying||opening||!foreground?null:load,child:Text(t('rechargeReload'))),
    ])),
    Padding(padding:const EdgeInsets.symmetric(horizontal:20),child:Text(t('rechargeRecoveryNotice'))),
    if(loading||querying)const LinearProgressIndicator(),
    if(failed)Padding(padding:const EdgeInsets.all(12),child:Text(t('rechargeUnavailable'))),
    Expanded(child:!foreground||loading?const SizedBox.shrink():entries.isEmpty?
      Center(child:Text(failed?t('rechargeUnavailable'):t('rechargeRecoveryEmpty'))):ListView.builder(
        itemCount:entries.length,itemBuilder:(context,index){
          final entry=entries[index],result=results[entry.identity];
          return Card(key:ValueKey(entry.identity),margin:const EdgeInsets.all(12),child:Padding(
            padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text('${entry.rechargeRef} · ${entry.channel == 'wechat' ? t('rechargeWechat') : t('rechargeAlipay')}'),
              Text('${t('rechargePrincipal')}: CNY ${formatCents(entry.principalCents)}'),
              if(result!=null)Text(t('rechargeState_${result.state}')),
              if(result?.credited==true)Text('${t('rechargeGift')}: CNY ${formatCents(result!.giftCents!)}'),
              OutlinedButton(onPressed:querying||result?.credited==true?null:()=>query(entry),child:Text(t('rechargeQuery'))),
              if(result?.state=='not_sent')OutlinedButton(onPressed:opening||querying?null:()=>resume(entry),child:Text(t('rechargeResumeTitle'))),
            ])));
        })),
  ]);
}
