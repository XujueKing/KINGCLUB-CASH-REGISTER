import 'bar_bill_header.dart';
import 'table_detail_snapshot.dart';
import 'voucher_workspace_panel.dart';
import 'table_members_panel.dart';
import 'item_price_dialog.dart';
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
import 'table_status_color.dart';
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
    this.onMergePayment,
    this.initialProduct,
    this.onInitialProductConsumed,
    this.onDraftChanged,
    this.detailRead,
  });
  final bool? menuVisible;
  final Future<TableDetailSnapshot>? detailRead;
  final ValueChanged<bool>? onMenuChanged;
  final StaffAuthController auth;
  final UiLanguage language;
  final OrderContextSnapshot orderContext;
  final String? memberRef;
  final VoidCallback onBack;
  final VoidCallback? onMergePayment;
  final CatalogProduct? initialProduct;
  final VoidCallback? onInitialProductConsumed;
  final ValueChanged<bool>? onDraftChanged;
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
  bool checkingPending = true;
  late final Future<void> initialRead;
  bool get acceptingAdds =>
      editable || (checkingPending && !busy && !stale && !attempted);
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

  // Selecting quantities is local. A background page read must not disable it;
  // submitting and server-side draft operations still require a fresh context.
  bool get draftAction =>
      widget.contextVerified && ready && !busy && !stale && !attempted;
  bool get editable =>
      ready &&
      (!busy || refreshingSelection) &&
      (!stale || refreshingSelection) &&
      !attempted &&
      (savedDraft == null || draftLoaded);
  bool get canSubmit =>
      draftAction &&
      editable &&
      items.isNotEmpty &&
      (savedDraft == null || !dirty);
  int get total => items.values.fold(
    0,
    (sum, item) => sum + item.quantity * item.priceCents,
  );

  @override
  void initState() {
    super.initState();
    widget.auth.addListener(invalidate);
    WidgetsBinding.instance.addObserver(this);
    initialRead = checkPending();
    unawaited(initialRead);
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
      if (ready &&
          widget.initialProduct != null &&
          items.isEmpty &&
          savedDraft == null) {
        change(widget.initialProduct!, 1);
        widget.onInitialProductConsumed?.call();
      }
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() {
          message = 'orderRecoveryFailed';
        });
      }
    } finally {
      if (mounted) setState(() => checkingPending = false);
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
    if (!draftAction || !widget.contextVerified) return;
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
            ..addEntries(result.items.map((i) => MapEntry(i.selectionRef, i)));
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
    if (oldWidget.initialProduct == null && widget.initialProduct != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            ready &&
            items.isEmpty &&
            savedDraft == null &&
            widget.initialProduct != null) {
          change(widget.initialProduct!, 1);
          widget.onInitialProductConsumed?.call();
        }
      });
    }
    if (!identical(oldWidget.auth, widget.auth)) {
      oldWidget.auth.removeListener(invalidate);
      widget.auth.addListener(invalidate);
    }
    if (!identical(oldWidget.auth, widget.auth) ||
        oldWidget.orderContext.storeRef != widget.orderContext.storeRef ||
        oldWidget.orderContext.tableRef != widget.orderContext.tableRef ||
        oldWidget.orderContext.sessionRef != widget.orderContext.sessionRef ||
        oldWidget.orderContext.paymentTiming !=
            widget.orderContext.paymentTiming ||
        oldWidget.orderContext.currency != widget.orderContext.currency ||
        oldWidget.orderContext.tableOrderAllowed !=
            widget.orderContext.tableOrderAllowed ||
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
    if (ready && items.isEmpty) {
      setState(() {
        stale = false;
        refreshingSelection = false;
        message = null;
      });
      return;
    }
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
          ..addEntries(result.items.map((i) => MapEntry(i.selectionRef, i)));
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

  int selectedQuantity(CatalogProduct product) => items.values
      .where((item) => item.product.reference == product.reference)
      .fold(0, (sum, item) => sum + item.quantity);

  bool canAdd(CatalogProduct product) =>
      product.inventoryKnown &&
      selectedQuantity(product) < product.available &&
      selectedQuantity(product) < 1000;

  void change(
    CatalogProduct product,
    int delta, {
    String? selectionRef,
    int? unitPriceCents,
    String? expenseOwnerUserAccount,
    String? authorizationRef,
  }) {
    if (checkingPending) {
      final generation = epoch;
      unawaited(
        initialRead.then((_) {
          if (!mounted || generation != epoch) return;
          change(
            product,
            delta,
            selectionRef: selectionRef,
            unitPriceCents: unitPriceCents,
            expenseOwnerUserAccount: expenseOwnerUserAccount,
            authorizationRef: authorizationRef,
          );
        }),
      );
      return;
    }
    if (!editable) return;
    if (delta > 0 && !canAdd(product)) return;
    // A read started with an older quantity must never overwrite a later tap.
    // Revalidate the latest selection once that in-flight read completes.
    if (refreshingSelection) refreshAgain = true;
    final key = selectionRef ?? product.reference;
    final old = items[key];
    final quantity = (old?.quantity ?? 0) + delta;
    if (quantity <= 0) {
      setState(() {
        items.remove(key);
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
        selectionRef: key,
        unitPriceCents: old?.unitPriceCents ?? unitPriceCents,
        expenseOwnerUserAccount:
            old?.expenseOwnerUserAccount ?? expenseOwnerUserAccount,
        authorizationRef: old?.authorizationRef ?? authorizationRef,
        paymentTiming: currentContext.paymentTiming,
      );
      final nextTotal =
          total -
          (old == null ? 0 : old.quantity * old.priceCents) +
          next.quantity * next.priceCents;
      if (nextTotal > 100000000) throw const FormatException();
      setState(() {
        items[key] = next;
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
    final generation = epoch;
    final original = List<OrderSelection>.unmodifiable(items.values);
    final orderContext = currentContext, memberRef = widget.memberRef;
    final draft = savedDraft;
    // Submit the selected batch once; the durable request owns retries.
    setState(() {
      busy = true;
      attempted = true;
      confirming = false;
      message = null;
    });
    try {
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
            OrderRequestState.confirmed => null,
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

  Future<void> addExistingProduct(
    String productRef, {
    CatalogProduct? knownProduct,
    bool edit = true,
    String? selectionRef,
    int? unitPriceCents,
    String? expenseOwnerUserAccount,
    String? authorizationRef,
  }) async {
    final initialEpoch = epoch;
    if (checkingPending) await initialRead;
    if (!mounted || initialEpoch != epoch) return;
    if (!editable) return;
    // The aggregate bill already carries this product and its stock. Do not
    // fetch the whole catalog or toggle the cart's global busy state for '+'.
    if (knownProduct != null) {
      if (knownProduct.reference != productRef) return;
      change(
        knownProduct,
        1,
        selectionRef: selectionRef,
        unitPriceCents: unitPriceCents,
        expenseOwnerUserAccount: expenseOwnerUserAccount,
        authorizationRef: authorizationRef,
      );
      return;
    }
    final selected = items[selectionRef ?? productRef];
    if (selected != null && !edit) {
      change(
        selected.product,
        1,
        selectionRef: selectionRef,
        unitPriceCents: unitPriceCents,
        expenseOwnerUserAccount: expenseOwnerUserAccount,
        authorizationRef: authorizationRef,
      );
      return;
    }
    final identity = widget.auth.session, generation = epoch;
    CatalogProduct? product;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      String? cursor;
      final seen = <String>{};
      do {
        final page = await widget.auth.readCatalog(afterProduct: cursor);
        if (!mounted ||
            generation != epoch ||
            !identical(identity, widget.auth.session)) {
          return;
        }
        product = page.products
            .where((p) => p.reference == productRef)
            .firstOrNull;
        if (product != null) break;
        cursor = page.nextAfterProduct;
        if (cursor != null && !seen.add(cursor)) throw const FormatException();
      } while (cursor != null);
      if (product == null) throw const FormatException();
    } catch (_) {
      if (mounted && generation == epoch) {
        setState(() {
          message = 'billAddUnavailable';
        });
      }
      return;
    } finally {
      if (mounted && generation == epoch) {
        setState(() {
          busy = false;
        });
      }
    }
    if (!mounted ||
        !editable ||
        generation != epoch ||
        !identical(identity, widget.auth.session)) {
      return;
    }
    change(
      product,
      1,
      selectionRef: selectionRef,
      unitPriceCents: unitPriceCents,
      expenseOwnerUserAccount: expenseOwnerUserAccount,
      authorizationRef: authorizationRef,
    );
    if (widget.tablePanel == null &&
        edit &&
        items.containsKey(product.reference) &&
        message == null) {
      await editDraftItem(product);
    }
  }

  int priceSequence = 0;
  Future<void> editDraftItem(
    CatalogProduct product, {
    String? selectionRef,
  }) async {
    if (!editable) return;
    final key = selectionRef ?? product.reference;
    final original = items[key];
    if (original == null) return;
    final generation = epoch;
    var expenseOwner = original.expenseOwnerUserAccount;
    String? authorization;
    final price = await showItemPriceDialog(
      context,
      language: widget.language,
      name: product.name(widget.language),
      quantity: original.quantity,
      originalCents: product.priceCents,
      currentCents: original.priceCents,
      auth: widget.auth,
      expenseOwnerUserAccount: expenseOwner,
      onExpenseOwner: (value) => expenseOwner = value,
      authorizationScope: {
        'tableRef': currentContext.tableRef,
        'sessionRef': currentContext.sessionRef,
        'productRef': product.reference,
      },
      onAuthorization: (value) => authorization = value,
    );
    if (price == null ||
        !mounted ||
        generation != epoch ||
        !editable ||
        !identical(items[key], original)) {
      return;
    }
    if (total -
            original.quantity * original.priceCents +
            original.quantity * price >
        100000000) {
      return;
    }
    final nextKey =
        original.specialPrice &&
            original.priceCents == price &&
            original.expenseOwnerUserAccount == expenseOwner
        ? key
        : 'price-${DateTime.now().microsecondsSinceEpoch}-${priceSequence++}';
    setState(() {
      items.remove(key);
      items[nextKey] = OrderSelection(
        product,
        original.quantity,
        paymentTiming: currentContext.paymentTiming,
        selectionRef: nextKey,
        unitPriceCents: price,
        expenseOwnerUserAccount: expenseOwner,
        authorizationRef: authorization,
      );
      dirty = true;
      message = null;
    });
  }

  Widget billHeader(Widget filter) {
    final table = widget.liveTable;
    final session = table?.session;
    final voucher = VoucherScanButton(
      auth: widget.auth,
      language: widget.language,
      tableName: table?.name,
      tableRef: currentContext.tableRef,
      sessionRef: currentContext.sessionRef,
    );
    final color = table?.isBarSeat == true && items.isNotEmpty && !attempted
        ? const Color(0xFFDC2626)
        : table == null
        ? const Color(0xff1d4ed8)
        : tableStatusColor(table);
    if (table?.isBarSeat == true) {
      return BarBillHeader(
        number: table!.barSeatNumber!,
        color: color,
        language: widget.language,
        filter: filter,
        voucherAction: voucher,
        member: TableMembersButton(
          detailRead: widget.detailRead,
          auth: widget.auth,
          language: widget.language,
          tableRef: currentContext.tableRef,
          sessionRef: currentContext.sessionRef,
          revision: widget.revision,
        ),
        mergeAction: widget.onMergePayment == null
            ? null
            : TextButton.icon(
                key: const ValueKey('bar-merge-payment'),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(0, 28),
                ),
                onPressed: items.isEmpty || attempted
                    ? widget.onMergePayment
                    : null,
                icon: const Icon(Icons.merge_type, size: 16),
                label: Text(
                  ['合并支付', 'Combine', '合併支付', 'รวมจ่าย'][widget.language.index],
                  style: const TextStyle(fontSize: 12),
                ),
              ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          key: const ValueKey('bill-table-badge'),
          constraints: const BoxConstraints(
            minWidth: 52,
            maxWidth: 82,
            minHeight: 48,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            gradient: tableStatusGradient(color),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            table?.isBarSeat == true
                ? 'B${table!.barSeatNumber}'
                : widget.orderContext.tableName,
            textAlign: TextAlign.center,
            maxLines: 2,
            style: TextStyle(
              color: color == Colors.white
                  ? const Color(0xff263c30)
                  : Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      key: const ValueKey('bill-heading'),
                      t('ordersDetails'),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (table?.isBarSeat != true) const SizedBox(width: 6),
                  if (table?.isBarSeat != true)
                    TextButton(
                      key: const ValueKey('bill-opening-tag'),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        minimumSize: const Size(0, 20),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor: color.withValues(alpha: 0.10),
                        foregroundColor: color,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                          side: BorderSide(
                            color: color.withValues(alpha: 0.25),
                          ),
                        ),
                      ),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(t('billOpeningAttribute')),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(t('billRuleUnavailable')),
                              if (widget.tableActions != null)
                                widget.tableActions!,
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
                      child: Text(
                        t('tableOpen'),
                        style: const TextStyle(fontSize: 10),
                      ),
                    ),
                ],
              ),
              if (widget.onMergePayment != null)
                TextButton.icon(
                  key: const ValueKey('bar-merge-payment'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: const Size(0, 28),
                  ),
                  onPressed: items.isEmpty || attempted
                      ? widget.onMergePayment
                      : null,
                  icon: const Icon(Icons.merge_type, size: 16),
                  label: Text(
                    [
                      '合并支付',
                      'Combine',
                      '合併支付',
                      'รวมจ่าย',
                    ][widget.language.index],
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              if (table?.isBarCounter != true && table?.isBarSeat != true)
                Row(
                  children: [
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
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '${t('guests')}: ${session?.partySize ?? currentContext.partySize ?? '—'}/${table?.maximumSeats ?? '—'}',
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        filter,
        voucher,
        TableMembersButton(
          detailRead: widget.detailRead,
          auth: widget.auth,
          language: widget.language,
          tableRef: currentContext.tableRef,
          sessionRef: currentContext.sessionRef,
          revision: widget.revision,
        ),
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

  bool? reportedDraft;
  @override
  Widget build(BuildContext context) {
    final hasDraft = items.isNotEmpty && !attempted;
    if (reportedDraft != hasDraft) {
      reportedDraft = hasDraft;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onDraftChanged?.call(hasDraft);
      });
    }
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
          // An IndexedStack also mounts and lays out its hidden catalog. Every
          // table selection used to rebuild it and fetch all product pages.
          child: widget.tablePanel != null && !menuOpen
              ? widget.tablePanel!
              : AbsorbPointer(
                  absorbing: !acceptingAdds,
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
                    canAdd: canAdd,
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
                    detailRead: widget.detailRead,
                    onQuickAddSpecialProduct: acceptingAdds
                        ? (
                            product,
                            price,
                            selectionRef, [
                            expenseOwner,
                            authorization,
                          ]) => addExistingProduct(
                            product.reference,
                            knownProduct: product,
                            edit: false,
                            selectionRef: selectionRef,
                            unitPriceCents: price,
                            expenseOwnerUserAccount: expenseOwner,
                            authorizationRef: authorization,
                          )
                        : null,
                    onRepriceDraft:
                        (
                          draftRef,
                          price,
                          selectionRef, [
                          expenseOwner,
                          authorization,
                        ]) {
                          final item = items[draftRef];
                          if (item == null || !editable) return;
                          setState(() {
                            items.remove(draftRef);
                            items[selectionRef] = OrderSelection(
                              item.product,
                              item.quantity,
                              paymentTiming: currentContext.paymentTiming,
                              selectionRef: selectionRef,
                              unitPriceCents: price,
                              expenseOwnerUserAccount: expenseOwner,
                              authorizationRef: authorization,
                            );
                            dirty = true;
                          });
                        },
                    onAddProduct: editable ? addExistingProduct : null,
                    onQuickAddProduct: acceptingAdds
                        ? (product) => addExistingProduct(
                            product.reference,
                            knownProduct: product,
                            edit: false,
                          )
                        : null,
                    // Once sent, only server orders contribute to consumption.
                    // The outbox owns an uncertain command, not a second draft.
                    draftCents: attempted ? 0 : total,
                    draftCards: {
                      for (final item
                          in attempted ? <OrderSelection>[] : items.values)
                        item.selectionRef: BillProductCard(
                          key: ValueKey('draft-card-${item.selectionRef}'),
                          onTap: editable
                              ? () => editDraftItem(
                                  item.product,
                                  selectionRef: item.selectionRef,
                                )
                              : null,
                          language: widget.language,
                          name: item.product.name(widget.language),
                          specification: item.product.specification(
                            widget.language,
                          ),
                          quantity: item.quantity,
                          priceCents: item.priceCents,
                          specialPrice: item.specialPrice,
                          totalCents: item.quantity * item.priceCents,
                          base: widget.auth.session?.base,
                          thumbnailPath: item.product.thumbnailPath,
                          quantityControls: true,
                          productRef: item.selectionRef,
                          onMinus: editable
                              ? () => change(
                                  item.product,
                                  -1,
                                  selectionRef: item.selectionRef,
                                )
                              : null,
                          onPlus:
                              editable &&
                                  item.product.inventoryKnown &&
                                  canAdd(item.product)
                              ? () => change(
                                  item.product,
                                  1,
                                  selectionRef: item.selectionRef,
                                )
                              : null,
                          badges: Text(
                            '${t('tableBillPaid')} 0 / ${t('tableBillUnpaid')} ${item.quantity}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xff216344),
                            ),
                          ),
                          leadingBadge: Text(
                            t('billDraft'),
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                    },
                    headerBuilder: widget.tablePanel == null
                        ? null
                        : billHeader,
                    orderAction: widget.tablePanel == null
                        ? null
                        : OutlinedButton(
                            key: const ValueKey('workspace-toggle-menu'),
                            onPressed: busy && !refreshingSelection
                                ? null
                                : () => setMenu(!menuOpen),
                            child: Text(
                              t(menuOpen ? 'ordersBack' : 'tableOrderStart'),
                            ),
                          ),
                    primaryAction:
                        widget.tablePanel != null &&
                            (items.isNotEmpty || (busy && !refreshingSelection))
                        ? FilledButton(
                            key: const ValueKey('cart-submit'),
                            onPressed: canSubmit
                                ? () => unawaited(submit())
                                : null,
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xff17483b),
                              foregroundColor: Colors.white,
                              disabledBackgroundColor: const Color(0xff17483b),
                              disabledForegroundColor: Colors.white,
                            ),
                            child: Text.rich(
                              TextSpan(
                                text: t(
                                  busy && !refreshingSelection
                                      ? 'cartRecording'
                                      : 'cartConfirmOrder',
                                ),
                                children: [
                                  TextSpan(
                                    text: '  ¥ ${formatCents(total)}',
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : null,
                    recording: busy && !refreshingSelection,
                    beforeActions: widget.tablePanel == null
                        ? null
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (!busy &&
                                  (attempted ||
                                      (!ready && message == 'cartPending')))
                                OutlinedButton(
                                  key: const ValueKey('cart-recovery'),
                                  onPressed: busy
                                      ? null
                                      : () => setState(() => recovery = true),
                                  child: Text(t('orderRecoveryTitle')),
                                ),
                            ],
                          ),
                    auth: widget.auth,
                    language: widget.language,
                    tableRef: widget.orderContext.tableRef,
                    sessionRef: widget.orderContext.sessionRef,
                    revision: widget.revision + billRevision,
                    changesAllowed: editable && draftAction,
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
                        if (widget.tablePanel == null && busy && !confirming)
                          const LinearProgressIndicator(),
                        if (stale && !busy && items.isNotEmpty && !attempted)
                          TextButton(
                            key: const ValueKey('cart-refresh'),
                            onPressed: () => unawaited(refreshSelection()),
                            child: Text(t('cartRefreshRetry')),
                          ),
                        if (widget.tablePanel == null)
                          Text(t('cartDraftNotice')),
                        if (widget.tablePanel == null)
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
                      ],
                    ),
                  ),
                ),
                if (widget.tablePanel == null)
                  Text(
                    'CNY ${formatCents(total)}',
                    key: const ValueKey('cart-total'),
                  ),
                if (widget.tablePanel == null)
                  FilledButton(
                    key: const ValueKey('cart-submit'),
                    onPressed: canSubmit ? () => unawaited(submit()) : null,
                    child: Text(t('cartSubmit')),
                  ),
                if (widget.tablePanel == null)
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
