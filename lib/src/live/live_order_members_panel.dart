import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'order_context_snapshot.dart';
import 'live_cart_panel.dart';

class LiveOrderMembersPanel extends StatefulWidget {
  const LiveOrderMembersPanel({
    super.key,
    required this.auth,
    required this.language,
    required this.tableRef,
    required this.sessionRef,
    required this.onBack,
    this.revision = 0,
  });
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef, sessionRef;
  final VoidCallback onBack;
  final int revision;
  @override
  State<LiveOrderMembersPanel> createState() => _LiveOrderMembersPanelState();
}

class _LiveOrderMembersPanelState extends State<LiveOrderMembersPanel>
    with WidgetsBindingObserver {
  OrderContextSnapshot? data;
  SeatedOrderMember? selected;
  bool cart = false;
  final cursors = <String?>[null];
  int page = 0, epoch = 0;
  bool loading = false, failed = false, foreground = true;
  String t(String key) => tr(widget.language, key);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.auth.addListener(identityChanged);
    unawaited(load());
  }

  void identityChanged() {
    ++epoch;
    setState(() {
      data = null;
      selected = null;
      cart = false;
      loading = false;
      failed = false;
    });
  }

  @override
  void didUpdateWidget(covariant LiveOrderMembersPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.auth != widget.auth) {
      oldWidget.auth.removeListener(identityChanged);
      widget.auth.addListener(identityChanged);
    }
    if (oldWidget.auth != widget.auth ||
        oldWidget.tableRef != widget.tableRef ||
        oldWidget.sessionRef != widget.sessionRef ||
        oldWidget.revision != widget.revision) {
      if (foreground) {
        unawaited(load(reset: true));
      } else {
        identityChanged();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      unawaited(load(reset: true));
    } else {
      identityChanged();
    }
  }

  Future<void> load({bool reset = false, int? target}) async {
    final generation = ++epoch, identity = widget.auth.session;
    if (reset) {
      cursors
        ..clear()
        ..add(null);
      page = 0;
    }
    final requestedPage = target ?? page;
    setState(() {
      data = null;
      selected = null;
      loading = true;
      cart = false;
      failed = false;
    });
    try {
      final value = await widget.auth.readOrderContext(
        tableRef: widget.tableRef,
        sessionRef: widget.sessionRef,
        afterMember: cursors[requestedPage],
      );
      if (!mounted ||
          generation != epoch ||
          !identical(identity, widget.auth.session)) {
        return;
      }
      if (value.nextAfterMember != null &&
          cursors.take(requestedPage + 1).contains(value.nextAfterMember)) {
        throw const FormatException();
      }
      setState(() {
        data = value;
        page = requestedPage;
        loading = false;
      });
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() {
          data = null;
          selected = null;
          loading = false;
          failed = true;
        });
      }
    }
  }

  @override
  void dispose() {
    ++epoch;
    widget.auth.removeListener(identityChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (cart && data != null && selected != null) {
      return LiveCartPanel(
        auth: widget.auth,
        language: widget.language,
        orderContext: data!,
        memberRef: selected!.reference,
        revision: widget.revision,
        onBack: () => unawaited(load(reset: true)),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                onPressed: widget.onBack,
                child: Text(t('ordersBack')),
              ),
              Text(
                t('orderMembersTitle'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              OutlinedButton(
                key: const ValueKey('order-members-refresh'),
                onPressed: loading ? null : () => unawaited(load(reset: true)),
                child: Text(t('liveRefresh')),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(t('orderMembersNotice')),
        ),
        if (data != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                Text(data!.tableName),
                Text(data!.sessionRef),
                Text(
                  t(
                    data!.paymentTiming == 'prepay'
                        ? 'livePrepay'
                        : 'livePostpay',
                  ),
                ),
                Text('${t('guests')}: ${data!.partySize ?? '—'}'),
                Text('${t('liveObserved')}: ${data!.observedAt.toLocal()}'),
              ],
            ),
          ),
        if (loading) const LinearProgressIndicator(),
        Expanded(
          child: failed
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(t('orderMembersFailed')),
                  ),
                )
              : data == null
              ? const SizedBox()
              : data!.members.isEmpty
              ? Center(child: Text(t('orderMembersEmpty')))
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: data!.members.length,
                  itemBuilder: (context, index) {
                    final member = data!.members[index];
                    return Card(
                      child: ListTile(
                        key: ValueKey('order-member-${member.reference}'),
                        enabled: member.eligible,
                        selected: selected?.reference == member.reference,
                        title: Text(member.nickname ?? t('orderMemberUnnamed')),
                        subtitle: Text(
                          '${member.reference}${member.eligible ? '' : ' · ${t('orderMemberIneligible')}'}',
                        ),
                        trailing: Icon(
                          selected?.reference == member.reference
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                        ),
                        onTap: member.eligible
                            ? () => setState(() {
                                selected =
                                    selected?.reference == member.reference
                                    ? null
                                    : member;
                              })
                            : null,
                      ),
                    );
                  },
                ),
        ),
        if (selected != null)
          FilledButton(
            key: const ValueKey('order-member-cart'),
            onPressed: loading || !foreground
                ? null
                : () => setState(() {
                    cart = true;
                  }),
            child: Text(t('cartTitle')),
          ),
        if (selected != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '${t('orderMemberSelected')}: ${selected!.nickname ?? t('orderMemberUnnamed')} (${selected!.reference})',
              key: const ValueKey('order-member-selection'),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Wrap(
            spacing: 20,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(
                key: const ValueKey('order-members-previous'),
                onPressed: loading || page == 0
                    ? null
                    : () => unawaited(load(target: page - 1)),
                child: Text(t('livePrevious')),
              ),
              Text('${t('livePage')} ${page + 1}'),
              OutlinedButton(
                key: const ValueKey('order-members-next'),
                onPressed: loading || data?.nextAfterMember == null
                    ? null
                    : () {
                        cursors.removeRange(page + 1, cursors.length);
                        cursors.add(data!.nextAfterMember);
                        unawaited(load(target: page + 1));
                      },
                child: Text(t('liveNext')),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
