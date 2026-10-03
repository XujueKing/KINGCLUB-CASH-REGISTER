# Simple cashier collection

Open checkout: read the authoritative bill and accept the hardware scanner directly. Preparing the parent and submitting the scanned code happen automatically once; no second barcode confirmation. Cash/POS/member-balance explicit confirmations remain.

Existing local attempts restore automatically. Prepared attempts accept a fresh code; pending/unknown attempts query their original identity every three seconds while foreground. They never auto-send a code or create a new attempt. Closing an unsent attempt cancels only the payment attempt and leaves the bill. Sent uncertainty stays recoverable, never displayed as an invented unpaid result.

The calendar history view has a settlement entry using its selected original table/session. The service accepts closed sessions for collection only; today's table is independent.

Verification: nine updated dialog widget tests pass, Android ARM32 release builds, same certificate verified and SUNMI install-r preserves data. Service counterpart 1716e827, migration 307 removes cashier shopping-cart expiry only. Real payment deduction remains to be confirmed by the customer scan; automation performs no debit.
