import 'bill_product_card.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/staff_auth_controller.dart';
import '../strings.dart';
import 'catalog_snapshot.dart';
import 'cart_draft.dart';
import 'live_catalog_panel.dart';
import 'live_order_recovery_panel.dart';
import 'order_command.dart';
import 'order_context_snapshot.dart';
import 'table_snapshot.dart';
import 'table_bill_panel.dart';

/// Explicit local draft save/restore; submission remains a separately confirmed command.
class LiveCartPanel extends StatefulWidget {
  const LiveCartPanel({
    super.key,
    this.menuVisible,
    this.onMenuChanged,
    required this.auth,
    required this.language,
    required this.orderContext,
    required this.memberRef,
    required this.onBack,
    this.revision = 0,
    this.tablePanel,
    this.menuHeader,
    this.liveTable,
    this.contextVerified = true,
    this.tableActions,
  });
  final bool? menuVisible;
  final ValueChanged<bool>? onMenuChanged;
  final StaffAuthController auth;
  final UiLanguage language;
  final OrderContextSnapshot orderContext;
  final String? memberRef;
  final VoidCallback onBack;
  final int revision;
  final Widget? tablePanel, tableActions, menuHeader;
  final LiveTable? liveTable;
  final bool contextVerified;
  @override
  State<LiveCartPanel> createState() => _LiveCartPanelState();
}

class _LiveCartPanelState extends State<LiveCartPanel>
    with WidgetsBindingObserver {
  final items = <String, OrderSelection>{};
  CartDraft? savedDraft;
  OrderContextSnapshot? restoredContext;
  bool draftLoaded = false, dirty = false;
  bool showMenu = false;
  bool get menuOpen => widget.menuVisible ?? showMenu;
  void setMenu(bool value) {
    if (widget.onMenuChanged != null) {
      widget.onMenuChanged!(value);
    } else {
      setState(() => showMenu = value);
    }
  }

  BuildContext? activeDialog;
  OrderContextSnapshot get currentContext =>
      restoredContext ?? widget.orderContext;
  bool ready = false,
      busy = false,
      stale = false,
      attempted = false,
      recovery = false;
  int epoch = 0;
  int billRevision = 0;
  bool confirming = false;
  bool refreshingSelection = false;
  bool refreshAgain = false;
  String? message;
  String t(String key) => tr(widget.language, key);
  String get memberName {
    if (widget.memberRef == null) return t('cartTitle');
    for (final member in currentContext.members) {
      if (member.reference == widget.memberRef) {
        return member.nickname ?? t('orderMemberUnnamed');
      }
    }
    return t('orderMemberUnnamed');
  }

  bool get draftAction =>
      widget.contextVerified && ready && !busy && !stale && !attempted;
  bool get editable => draftAction && (savedDraft == null || draftLoaded);
  bool get canSubmit =>
      editable && items.isNotEmpty && (savedDraft == null || !dirty);
  int get total => items.values.fold(
    0,
    (sum, item) => sum + item.quantity * item.product.priceCents,
  );

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(invalidate);
    WidgetsBinding.instance.addObserver(this);
    unawaited(checkPending());
  }

  Future<void> checkPending() async {
    final generation = epoch;
    try {
      final pending = await widget.auth.pendingOrders();
      if (!mounted || generation != epoch) return;
      final drafts = await widget.auth.cartDrafts();
      if (!mounted || generation != epoch) return;
      final matches = drafts
          .where(
            (d) =>
                d.tableRef == widget.orderContext.tableRef &&
                d.sessionRef == widget.orderContext.sessionRef &&
                d.memberRef == widget.memberRef,
          )
          .toList();
      setState(() {
        savedDraft = matches.isEmpty ? null : matches.single;
        ready = !pending.any((p) => p.tableRef == widget.orderContext.tableRef);
        if (!ready) message = 'cartPending';
        if (ready && savedDraft != null) message = 'cartDraftFound';
      });
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() {
          message = 'orderRecoveryFailed';
        });
      }
    }
  }

  void invalidate() {
    ++epoch;
    if (!mounted) return;
    final dialog = activeDialog;
    if (dialog != null &&
        dialog.mounted &&
        ModalRoute.of(dialog)?.isCurrent == true) {
      Navigator.of(dialog).pop();
    }
    setState(() {
      stale = true;
      ready = false;
      items.clear();
      savedDraft = null;
      restoredContext = null;
      message = 'cartStale';
    });
  }

  Future<void> draftOperation(String action) async {
    if (!draftAction) return;
    if (action == 'save' && (!editable || items.isEmpty)) return;
    if (action != 'save' && savedDraft == null) return;
    final generation = epoch, identity = widget.auth.session;
    final original = savedDraft;
    bool current() =>
        mounted &&
        generation == epoch &&
        identical(identity, widget.auth.session);
    setState(() => busy = true);
    try {
      if (action == 'discard') {
        confirming = true;
        final accepted = await showDialog<bool>(
          context: context,
          builder: (ctx) {
            activeDialog = ctx;
            return AlertDialog(
              title: Text(t('cartDraftDiscard')),
              content: Text(t('cartDraftDiscardNotice')),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t('cancel')),
                ),
                FilledButton(
                  key: const ValueKey('cart-draft-discard-confirm'),
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t('confirm')),
                ),
              ],
            );
          },
        );
        activeDialog = null;
        if (!current() || accepted != true) return;
        await widget.auth.discardCartDraft(original!, confirmed: true);
        if (!current()) return;
        setState(() {
          savedDraft = null;
          draftLoaded = false;
          dirty = false;
          items.clear();
          message = 'cartDraftDiscarded';
        });
      } else if (action == 'restore') {
        final result = await widget.auth.restoreCartDraft(original!);
        if (!current()) return;
        setState(() {
          restoredContext = result.context;
          items
            ..clear()
            ..addEntries(
              result.items.map((i) => MapEntry(i.product.reference, i)),
            );
          draftLoaded = true;
          dirty = false;
          message = 'cartDraftRestored';
        });
      } else {
        final result = await widget.auth.saveCartDraft(
          context: currentContext,
          memberRef: widget.memberRef,
          items: List.unmodifiable(items.values),
          previous: original,
        );
        if (!current()) return;
        setState(() {
          savedDraft = result;
          draftLoaded = true;
          dirty = false;
          message = 'cartDraftSaved';
        });
      }
    } catch (_) {
      if (current()) {
        setState(() {
          // A write may have reached encrypted storage. Reopen to read its actual version.
          if (action != 'restore') ready = false;
          if (action == 'restore') {
            draftLoaded = false;
            items.clear();
            restoredContext = null;
            dirty = false;
          }
          message = 'cartDraftFailed';
        });
      }
    } finally {
      activeDialog = null;
      if (mounted) {
        setState(() {
          busy = false;
          confirming = false;
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant LiveCartPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.auth, widget.auth)) {
      oldWidget.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
    }
    if (!identical(oldWidget.auth, widget.auth) ||
        !identical(oldWidget.orderContext, widget.orderContext) ||
        oldWidget.memberRef != widget.memberRef) {
      invalidate();
    } else if (oldWidget.revision != widget.revision && !attempted) {
      // Once sent, wait for the original response/recovery even if its own
      // notification arrives first. Auth/scope/lifecycle changes still invalidate.
      if (refreshingSelection) {
        refreshAgain = true;
      } else if (items.isNotEmpty && (!busy || confirming)) {
        unawaited(refreshSelection());
      } else if (items.isNotEmpty) {
        invalidate();
      }
      // An empty cart has no selected prices to refresh. Keep it usable while
      // the catalog and table bill refresh themselves from the same revision.
    }
  }

  Future<void> refreshSelection() async {
    refreshAgain = false;
    final generation = ++epoch, identity = widget.auth.session;
    final original = List<OrderSelection>.unmodifiable(items.values);
    final dialog = activeDialog;
    if (dialog != null &&
        dialog.mounted &&
        ModalRoute.of(dialog)?.isCurrent == true) {
      Navigator.of(dialog).pop();
    }
    setState(() {
      stale = true;
      busy = true;
      refreshingSelection = true;
      message = 'cartRefreshing';
    });
    try {
      final result = await widget.auth.refreshCartSelection(
        context: currentContext,
        memberRef: widget.memberRef,
        items: original,
      );
      if (!mounted ||
          generation != epoch ||
          !identical(identity, widget.auth.session) ||
          refreshAgain) {
        return;
      }
      setState(() {
        restoredContext = result.context;
        items
          ..clear()
          ..addEntries(
            result.items.map((i) => MapEntry(i.product.reference, i)),
          );
        stale = false;
        ready = true;
        message = null;
      });
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() => message = 'cartRefreshFailed');
      }
    } finally {
      if (mounted && generation == epoch) {
        setState(() {
          busy = false;
          refreshingSelection = false;
        });
        if (refreshAgain) unawaited(refreshSelection());
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) invalidate();
  }

  void change(CatalogProduct product, int delta) {
    if (!editable) return;
    final old = items[product.reference];
    final quantity = (old?.quantity ?? 0) + delta;
    if (quantity <= 0) {
      setState(() {
        items.remove(product.reference);
        dirty = true;
        message = null;
      });
      return;
    }
    try {
      if ((old != null &&
              (old.product.revision != product.revision ||
                  old.product.priceCents != product.priceCents)) ||
          (old == null && items.length >= 50)) {
        throw const FormatException();
      }
      final next = OrderSelection(
        product,
        quantity,
        paymentTiming: currentContext.paymentTiming,
      );
      final nextTotal =
          total -
          (old == null ? 0 : old.quantity * old.product.priceCents) +
          next.quantity * product.priceCents;
      if (nextTotal > 100000000) throw const FormatException();
      setState(() {
        items[product.reference] = next;
        dirty = true;
        message = null;
      });
    } catch (_) {
      setState(() {
        message = 'cartLimit';
      });
    }
  }

  Future<void> submit() async {
    if (!canSubmit) return;
    final generation = epoch, identity = widget.auth.session;
    final original = List<OrderSelection>.unmodifiable(items.values);
    final orderContext = currentContext, memberRef = widget.memberRef;
    final draft = savedDraft;
    setState(() {
      busy = true;
      confirming = true;
    });
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          activeDialog = dialogContext;
          return AlertDialog(
            title: Text(t('cartSubmit')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${orderContext.tableName}\n$memberName'),
                  Text(
                    t(
                      orderContext.paymentTiming == 'prepay'
                          ? 'livePrepay'
                          : 'livePostpay',
                    ),
                  ),
                  for (final item in original)
                    Text(
                      '${item.product.name(widget.language)} · ${item.product.specification(widget.language)} × ${item.quantity} · CNY ${formatCents(item.quantity * item.product.priceCents)}',
                    ),
                  Text('CNY ${formatCents(total)}'),
                  Text(t('cartConfirmNotice')),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(t('cancel')),
              ),
              FilledButton(
                key: const ValueKey('cart-confirm'),
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(t('confirm')),
              ),
            ],
          );
        },
      );
      activeDialog = null;
      if (accepted != true ||
          !mounted ||
          generation != epoch ||
          !identical(identity, widget.auth.session)) {
        return;
      }
      // Keep the editor locked until a durable terminal receipt is returned.
      // An uncertain delivery remains owned by original-request recovery.
      setState(() {
        attempted = true;
        confirming = false;
        message = null;
      });
      final result = await widget.auth.submitOrder(
        context: orderContext,
        memberRef: memberRef,
        items: original,
        confirmed: true,
        cartDraft: draft,
      );
      if (mounted && generation == epoch) {
        setState(() {
          items.clear();
          billRevision++;
          if (result.state != OrderRequestState.notObserved) {
            // The controller has acknowledged the original durable command.
            // The next round must not reuse its consumed saved draft.
            attempted = false;
            savedDraft = null;
            draftLoaded = false;
            dirty = false;
          }
          message = switch (result.state) {
            OrderRequestState.confirmed => 'orderRecoveryConfirmed',
            OrderRequestState.cancelled => 'orderRecoveryCancelled',
            OrderRequestState.notObserved => 'orderRecoveryUnknown',
          };
        });
      }
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() {
          message = 'orderRecoveryUnconfirmed';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          confirming = false;
        });
      }
    }
  }

  Future<void> editDraftItem(CatalogProduct product) async {
    if (!editable) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, redraw) {
          final quantity = items[product.reference]?.quantity ?? 0;
          return AlertDialog(
            title: Text(product.name(widget.language)),
            content: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: const ValueKey('draft-dialog-minus'),
                  onPressed: editable && quantity > 0
                      ? () {
                          change(product, -1);
                          redraw(() {});
                        }
                      : null,
                  icon: const Icon(Icons.remove),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text('$quantity'),
                ),
                IconButton(
                  key: const ValueKey('draft-dialog-plus'),
                  onPressed: editable
                      ? () {
                          change(product, 1);
                          redraw(() {});
                        }
                      : null,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(t('billDone')),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget billHeader(Widget filter) {
    final table = widget.liveTable;
    final session = table?.session;
    final color = session?.status == 'clearing'
        ? const Color(0xff1d4ed8)
        : session?.temporaryHold == true || (session?.pendingCents ?? 0) > 0
        ? const Color(0xffb45309)
        : const Color(0xff15803d);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              constraints: const BoxConstraints(minWidth: 52, maxWidth: 82),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                widget.orderContext.tableName,
                maxLines: 2,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            InkWell(
              key: const ValueKey('bill-party-size'),
              onTap: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(t('guests')),
                  content: Text(t('billPartyUnavailable')),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(t('staffCancelSelection')),
                    ),
                  ],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '${t('guests')}: ${session?.partySize ?? currentContext.partySize ?? '—'}/${table?.maximumSeats ?? '—'}',
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(width: 6),
        Expanded(
          child: TextButton(
            key: const ValueKey('workspace-toggle-menu'),
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: busy ? null : () => setMenu(!menuOpen),
            child: Text(
              t('ordersDetails'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            minimumSize: const Size(0, 40),
          ),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(t('billOpeningAttribute')),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(t('billRuleUnavailable')),
                  if (widget.tableActions != null) widget.tableActions!,
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(t('staffCancelSelection')),
                ),
              ],
            ),
          ),
          child: Text(t('tableOpen'), style: const TextStyle(fontSize: 11)),
        ),
        filter,
      ],
    );
  }

  @override
  void dispose() {
    ++epoch;
    widget.auth.removeListener(invalidate);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (recovery) {
      return LiveOrderRecoveryPanel(
        auth: widget.auth,
        language: widget.language,
        onBack: widget.onBack,
      );
    }
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: widget.tablePanel != null && !menuOpen
              ? widget.tablePanel!
              : AbsorbPointer(
                  absorbing: !editable,
                  child: LiveCatalogPanel(
                    header: widget.menuHeader,
                    paymentTiming: currentContext.paymentTiming,
                    auth: widget.auth,
                    language: widget.language,
                    revision: widget.revision,
                    onBack: widget.tablePanel == null
                        ? widget.onBack
                        : () => setMenu(false),
                    onSelect: (product) => change(product, 1),
                  ),
                ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 1,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: TableBillPanel(
                    draftCents: total,
                    headerBuilder: widget.tablePanel == null
                        ? null
                        : billHeader,
                    auth: widget.auth,
                    language: widget.language,
                    tableRef: widget.orderContext.tableRef,
                    sessionRef: widget.orderContext.sessionRef,
                    revision: widget.revision + billRevision,
                    checkoutAllowed:
                        widget.contextVerified &&
                        !busy &&
                        items.isEmpty &&
                        (!attempted ||
                            message == 'orderRecoveryConfirmed' ||
                            message == 'orderRecoveryCancelled'),

                    fillHeight: true,
                    leading: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (widget.tablePanel == null)
                          Text(
                            widget.tablePanel == null
                                ? '${widget.orderContext.tableName} · ${t('ordersDetails')}'
                                : t('ordersDetails'),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        if (widget.memberRef != null) Text(memberName),
                        if (widget.tablePanel == null)
                          Text(
                            t(
                              currentContext.paymentTiming == 'prepay'
                                  ? 'livePrepay'
                                  : 'livePostpay',
                            ),
                          ),
                        if (message != null)
                          Text(
                            t(message!),
                            key: const ValueKey('cart-message'),
                          ),
                        if (busy && !confirming)
                          const LinearProgressIndicator(),
                        if (stale && !busy && items.isNotEmpty && !attempted)
                          TextButton(
                            key: const ValueKey('cart-refresh'),
                            onPressed: () => unawaited(refreshSelection()),
                            child: Text(t('cartRefreshRetry')),
                          ),
                        if (widget.tablePanel == null)
                          Text(t('cartDraftNotice')),
                        if (widget.tablePanel == null ||
                            items.isNotEmpty ||
                            savedDraft != null)
                          Wrap(
                            spacing: 8,
                            children: [
                              OutlinedButton(
                                key: const ValueKey('cart-draft-save'),
                                onPressed: editable && items.isNotEmpty && dirty
                                    ? () => unawaited(draftOperation('save'))
                                    : null,
                                child: Text(t('cartDraftSave')),
                              ),
                              OutlinedButton(
                                key: const ValueKey('cart-draft-restore'),
                                onPressed:
                                    draftAction && savedDraft != null && !dirty
                                    ? () => unawaited(draftOperation('restore'))
                                    : null,
                                child: Text(t('cartDraftRestore')),
                              ),
                              TextButton(
                                key: const ValueKey('cart-draft-discard'),
                                onPressed: draftAction && savedDraft != null
                                    ? () => unawaited(draftOperation('discard'))
                                    : null,
                                child: Text(t('cartDraftDiscard')),
                              ),
                            ],
                          ),
                        if (savedDraft != null && dirty)
                          Text(t('cartDraftResave')),
                        if (items.isEmpty && widget.tablePanel == null)
                          Text(t('cartDraftEmpty')),
                        for (final item in items.values)
                          BillProductCard(
                            key: ValueKey(
                              'draft-card-${item.product.reference}',
                            ),
                            onTap: editable
                                ? () => editDraftItem(item.product)
                                : null,
                            language: widget.language,
                            name: item.product.name(widget.language),
                            specification: item.product.specification(
                              widget.language,
                            ),
                            quantity: item.quantity,
                            priceCents: item.product.priceCents,
                            totalCents: item.quantity * item.product.priceCents,
                            base: widget.auth.session?.base,
                            thumbnailPath: item.product.thumbnailPath,
                            footer: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    t('billDraft'),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                IconButton(
                                  key: ValueKey(
                                    'cart-minus-${item.product.reference}',
                                  ),
                                  tooltip: t('cartRemove'),
                                  onPressed: editable
                                      ? () => change(item.product, -1)
                                      : null,
                                  icon: const Icon(Icons.remove, size: 18),
                                ),
                                Text('${item.quantity}'),
                                IconButton(
                                  key: ValueKey(
                                    'cart-plus-${item.product.reference}',
                                  ),
                                  tooltip: t('cartAdd'),
                                  onPressed: editable
                                      ? () => change(item.product, 1)
                                      : null,
                                  icon: const Icon(Icons.add, size: 18),
                                ),
                                IconButton(
                                  key: ValueKey(
                                    'cart-delete-${item.product.reference}',
                                  ),
                                  tooltip: t('cartDelete'),
                                  onPressed: editable
                                      ? () =>
                                            change(item.product, -item.quantity)
                                      : null,
                                  icon: const Icon(Icons.close, size: 18),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (widget.tablePanel == null)
                  Text(
                    'CNY ${formatCents(total)}',
                    key: const ValueKey('cart-total'),
                  ),
                if (widget.tablePanel == null || items.isNotEmpty || busy)
                  FilledButton(
                    key: const ValueKey('cart-submit'),
                    onPressed: canSubmit ? () => unawaited(submit()) : null,
                    child: Text(t('cartSubmit')),
                  ),
                if (widget.tablePanel == null || attempted)
                  OutlinedButton(
                    key: const ValueKey('cart-recovery'),
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            recovery = true;
                          }),
                    child: Text(t('orderRecoveryTitle')),
                  ),
                if (widget.tablePanel == null)
                  TextButton(
                    onPressed: busy ? null : widget.onBack,
                    child: Text(t('ordersBack')),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
