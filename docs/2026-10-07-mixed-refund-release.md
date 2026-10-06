# Mixed-tender refund UI

The existing touch refund dialog now displays the server allocation for WeChat, original store principal/gift, platform cash and whole coins. It distinguishes returned-goods value from money returned and explains coupon restoration only on full refund with the original expiry.

One context request supplies all quantity options. Selecting quantity makes no network request. Submission carries the chosen fingerprint; unknown submission keeps the original durable request ID. Invalid context clears submission eligibility. Recovery validates the returned allocation before acknowledging a completed refund.

History uses the same funding breakdown, including APP-origin orders, and does not assume actual returned tender equals the gross returned-goods amount.

Validation: 1084 Flutter tests passed, 5 skipped, with the shipping `CASHIER_USB_RASTER_OUTPUT=true` define. All 10 focused refund tests passed. Analyzer found no error/warning; existing informational style findings remain. ARM32 release built and signature verified. APK SHA256: `1faf669888b7ee590b3c862c6e673d9805138967b5fd3be55bc01f2a9c339a4e`.

Backend migrations 372–374 and coordinated runtime are deployed and passed live read-only context, table-detail, report and runtime checks. No real financial refund was submitted.

Terminal follow-up: SUNMI reconnected and the signed APK was installed with `install -r`; session and business data were retained. Screenshot checks confirmed the table page and yesterday's paid-order detail, payment channel and receipt reprint entry. No real refund was submitted. This does not mark real financial acceptance or the entire product complete.
