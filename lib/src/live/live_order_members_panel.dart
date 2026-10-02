import 'table_snapshot.dart';
import 'table_bill_panel.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'order_context_snapshot.dart';
import 'live_cart_panel.dart';
import 'member_seating_panel.dart';

class LiveOrderMembersPanel extends StatefulWidget {
  const LiveOrderMembersPanel({
    super.key,
    this.menuVisible,
    this.onMenuChanged,
    required this.auth,
    required this.language,
    required this.tableRef,
    required this.sessionRef,
    required this.onBack,
    this.revision = 0,
    this.tablePanel,
    this.menuHeader,
    this.liveTable,
    this.tableActions,
  });
  final bool? menuVisible;
  final ValueChanged<bool>? onMenuChanged;
  final StaffAuthController auth;
  final UiLanguage language;
  final String tableRef, sessionRef;
  final VoidCallback onBack;
  final int revision;
  final Widget? tablePanel, tableActions, menuHeader;
  final LiveTable? liveTable;
  @override
  State<LiveOrderMembersPanel> createState() => _LiveOrderMembersPanelState();
}

class _LiveOrderMembersPanelState extends State<LiveOrderMembersPanel>
    with WidgetsBindingObserver {
  OrderContextSnapshot? data;
  SeatedOrderMember? selected;
  bool cart = false;
  bool seating = false;
  bool selectingMember = false;
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
      seating = false;
      loading = false;
      failed = false;
    });
  }

  @override
  void didUpdateWidget(covariant LiveOrderMembersPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.auth == widget.auth &&
        oldWidget.tableRef == widget.tableRef &&
        oldWidget.sessionRef == widget.sessionRef &&
        (cart || data?.tableOrderAllowed == true) &&
        foreground) {
      // The cart handles refresh hints and owns any submitted request's receipt.
      return;
    }
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

  Future<void> load({
    bool reset = false,
    int? target,
    String? seatedMember,
  }) async {
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
        if (seatedMember != null) {
          final matches = value.members.where(
            (m) => m.reference == seatedMember && m.eligible,
          );
          if (matches.length == 1) {
            selected = matches.single;
            cart = true;
          }
        }
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
    if (seating && data != null) {
      return MemberSeatingPanel(
        auth: widget.auth,
        language: widget.language,
        orderContext: data,
        onBack: () {
          setState(() => seating = false);
          unawaited(load(reset: true));
        },
        onSeated: (memberRef) {
          setState(() => seating = false);
          unawaited(load(reset: true, seatedMember: memberRef));
        },
      );
    }
    if (data != null &&
        (data!.tableOrderAllowed || (cart && selected != null))) {
      return LiveCartPanel(
        auth: widget.auth,
        language: widget.language,
        orderContext: data!,
        menuVisible: widget.menuVisible,
        onMenuChanged: widget.onMenuChanged,
        tablePanel: widget.tablePanel,
        menuHeader: widget.menuHeader,
        liveTable: widget.liveTable,
        tableActions: widget.tableActions,
        memberRef: selected?.reference,
        revision: widget.revision,
        onBack: data!.tableOrderAllowed
            ? widget.onBack
            : () => unawaited(load(reset: true)),
      );
    }
    final selector = memberSelector();
    if (widget.tablePanel != null) {
      return Row(
        children: [
          Expanded(
            flex: 2,
            child: selectingMember ? selector : widget.tablePanel!,
          ),
          const VerticalDivider(width: 1),
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: TableBillPanel(
                auth: widget.auth,
                language: widget.language,
                tableRef: widget.tableRef,
                sessionRef: widget.sessionRef,
                revision: widget.revision,
                fillHeight: true,
                leading: Row(
                  children: [
                    Expanded(
                      child: Text(data?.tableName ?? t('ordersDetails')),
                    ),
                    TextButton(
                      onPressed: data == null
                          ? null
                          : () => setState(
                              () => selectingMember = !selectingMember,
                            ),
                      child: Text(
                        t(selectingMember ? 'tables' : 'tableOrderStart'),
                      ),
                    ),
                    ?widget.tableActions,
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }
    return selector;
  }

  Widget memberSelector() => Column(
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            TextButton.icon(
              onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back, size: 18),
              label: Text(t('ordersBack')),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${data?.tableName ?? ''} · ${t('orderMembersTitle')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Tooltip(
              message: t('orderMembersNotice'),
              child: const Padding(
                padding: EdgeInsets.all(12),
                child: Icon(Icons.info_outline, size: 20),
              ),
            ),
            if (widget.auth.session?.permissions.contains('table.open') == true)
              TextButton.icon(
                key: const ValueKey('order-members-seat'),
                onPressed: data == null || loading
                    ? null
                    : () => setState(() => seating = true),
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                label: Text(t('seatingTitle')),
              ),
            IconButton(
              key: const ValueKey('order-members-refresh'),
              tooltip: t('liveRefresh'),
              onPressed: loading ? null : () => unawaited(load(reset: true)),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
      ),
      if (data != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Text(
                t(
                  data!.paymentTiming == 'prepay'
                      ? 'livePrepay'
                      : 'livePostpay',
                ),
              ),
              const SizedBox(width: 16),
              Text('${t('guests')}: ${data!.partySize ?? '—'}'),
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
                      subtitle: member.eligible
                          ? null
                          : Text(t('orderMemberIneligible')),
                      trailing: member.eligible
                          ? const Icon(Icons.chevron_right)
                          : null,
                      onTap: member.eligible
                          ? () => setState(() {
                              selected = member;
                              cart = true;
                            })
                          : null,
                    ),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
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
