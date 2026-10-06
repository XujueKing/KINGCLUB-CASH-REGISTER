# Table WeChat item refunds

Consumption-detail actions now open a touch quantity/reason/physical-return dialog for table-paid orders with payment.refund permission. Refund-only is the default; only explicitly received intact goods request stock restoration. Context and actions use existing K261006002020. Original request IDs persist in secure storage before submission, survive reopening and are queried rather than replaced after uncertainty. Query completion closes the dialog and refreshes the bill. Server enablement is required.

Order snapshots accept completed WeChat refund projections without pretending they are wallet credits. Paid receipts retain original gross amount and add refunded/net amount. No automatic financial transaction was performed.

Validation: full suite 1075 passed, 5 skipped, 3 printing cases failed because the run omitted CASHIER_USB_RASTER_OUTPUT. All 23 targeted printing/journal/bill tests passed when rerun with the shipping printing define; the new touch refund/uncertain-query test also passed. Analyzer has no errors, existing informational findings remain. This code has not been installed on the cashier; backend coordinated release and actual authorized refund acceptance remain pending.
