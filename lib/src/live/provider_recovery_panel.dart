import 'dart:async';
import 'package:flutter/material.dart';
import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'provider_payment.dart';
import 'provider_payment_panel.dart';
import 'payment_admission.dart';
import 'table_snapshot.dart';

/// Recovery is independent of order pagination and the current table session.
/// Entries belong to the authenticated employee/device/store, not screenshot data.
class ProviderRecoveryPanel extends StatefulWidget {
  const ProviderRecoveryPanel({super.key,required this.auth,required this.language,required this.onBack});
  final StaffAuthController auth;
  final UiLanguage language;
  final VoidCallback onBack;
  @override State<ProviderRecoveryPanel> createState()=>_ProviderRecoveryPanelState();
}
class _ProviderRecoveryPanelState extends State<ProviderRecoveryPanel> with WidgetsBindingObserver {
  List<ProviderPayment> entries=[];
  bool foreground=true,loading=false,failed=false;
  int epoch=0;
  String t(String key)=>tr(widget.language,key);
  @override void initState(){super.initState();foreground=WidgetsBinding.instance.lifecycleState==null||WidgetsBinding.instance.lifecycleState==AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);widget.auth.addListener(invalidate);if(foreground)unawaited(load());}
  void invalidate(){epoch++;if(mounted)setState((){entries=[];failed=false;});if(foreground)unawaited(load());}
  @override void didChangeAppLifecycleState(AppLifecycleState state){foreground=state==AppLifecycleState.resumed;invalidate();}
  @override void didUpdateWidget(covariant ProviderRecoveryPanel old){super.didUpdateWidget(old);if(old.auth!=widget.auth){old.auth.removeListener(invalidate);widget.auth.addListener(invalidate);invalidate();}}
  @override void dispose(){epoch++;widget.auth.removeListener(invalidate);WidgetsBinding.instance.removeObserver(this);super.dispose();}
  Future<void> load() async {
    if(!mounted||!foreground)return;
    final e=++epoch;setState(()=>loading=true);
    try {
      final result=<ProviderPayment>[];
      for(final channel in ['wechat','alipay','member_balance']) {
        if(widget.auth.session?.permissions.contains(paymentPermissions[channel])==true)result.addAll(await widget.auth.pendingProviderPayments(channel));
      }
      if(mounted&&foreground&&e==epoch)setState((){entries=result;failed=false;});
    }catch(_){if(mounted&&e==epoch)setState((){entries=[];failed=true;});}
    finally{if(mounted&&e==epoch)setState(()=>loading=false);}
  }
  @override Widget build(BuildContext context)=>Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
    Padding(padding:const EdgeInsets.all(16),child:Wrap(spacing:16,crossAxisAlignment:WrapCrossAlignment.center,children:[
      OutlinedButton(onPressed:widget.onBack,child:Text(t('ordersBack'))),Text(t('provider_recovery')),
      OutlinedButton(onPressed:loading||!foreground?null:()=>unawaited(load()),child:Text(t('ordersRefresh'))),
    ])),
    Padding(padding:const EdgeInsets.symmetric(horizontal:20),child:Text(t('provider_recovery_notice'))),
    if(loading)const LinearProgressIndicator(),
    Expanded(child:!foreground?const SizedBox():failed?Center(child:Text(t('provider_review'))):
      entries.isEmpty?Center(child:Text(t('provider_empty'))):ListView(children:[for(final entry in entries)
        Card(key:ValueKey(entry.requestId),margin:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Padding(padding:const EdgeInsets.all(12),child:Text('${entry.params['orderRef']} · ${t('provider_${entry.query.channel}')} · CNY ${formatCents(entry.params['expectedTotalCents'] as int)}')),
          if(entry.accountType!=null)Padding(padding:const EdgeInsets.symmetric(horizontal:12),child:Text(t('balance_${entry.accountType}'))),
          ProviderPaymentPanel(auth:widget.auth,orderRef:entry.params['orderRef'] as String,totalCents:entry.params['expectedTotalCents'] as int,
            language:widget.language,recoveryOnly:true,onResolved:()=>unawaited(load())),
        ])),
      ])),
  ]);
}
