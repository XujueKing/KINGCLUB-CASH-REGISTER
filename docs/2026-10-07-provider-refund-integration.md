# Table WeChat item refunds

Current update: [mixed-refund integration](2026-10-07-mixed-refund-release.md) adds eligible frozen APP compositions to this same flow. Earlier exclusions below describe the previous release.

Consumption-detail actions now open a touch quantity/reason/physical-return dialog for table-paid orders with payment.refund permission. Refund-only is the default; only explicitly received intact goods request stock restoration. Context and actions use existing K261006002020. Original request IDs persist in secure storage before submission, survive reopening and are queried rather than replaced after uncertainty. Query completion closes the dialog and refreshes the bill. Server enablement is required.

Order snapshots accept completed WeChat refund projections without pretending they are wallet credits. Paid receipts retain original gross amount and add refunded/net amount. No automatic financial transaction was performed.

Validation: full suite 1075 passed, 5 skipped, 3 printing cases failed because the run omitted CASHIER_USB_RASTER_OUTPUT. All 23 targeted printing/journal/bill tests passed when rerun with the shipping printing define; the new touch refund/uncertain-query test also passed. Analyzer has no errors, existing informational findings remain. This code has not been installed on the cashier; backend coordinated release and actual authorized refund acceptance remain pending.

## Release follow-up
Unaccepted preparation is shown separately from processing. Recheck reloads server context and retains the original request ID when quantities are reconfirmed; journal revision cannot change employee/order/product/request identity. Original-result queries are authoritative if a delayed earlier request won the race. Recovery widget tests cover both ambiguous submission and not-observed/reconfirmation.

Full release-flag suite: 1080 passed, 5 skipped. APK built and installed with install -r on the existing SUNMI device; app data retained. Backend migrations 357?361 and refund API/flag are enabled. No actual financial refund was executed.


## Original payment eligibility (2026-10-07)

The bill now uses the server providerRefundAvailable flag instead of inferring refund support from a table checkout pointer. Paid standalone APP WeChat orders can use the same touch refund dialog; member-balance and mixed-tender orders do not expose the WeChat refund operation. Missing/invalid eligibility flags default to false. The server always revalidates the original transaction and merchant before submission. Real-money refund acceptance remains unperformed.

Validation: 47 focused Flutter tests passed. ARM32 release APK signed with the existing device key and installed with install -r on the target SUNMI; employee session and V1 data preserved. Backend read-only APP and cashier contexts passed. No actual refund submitted.
