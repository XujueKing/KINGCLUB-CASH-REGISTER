# Paid-order and serving attention ? 2026-10-05

Workbench K260929001902 adds session.appPaidOrders and unservedQuantity, documented by migration 324 (contract-only, no new tables). App paid count excludes cashier-origin orders. Unserved includes paid/waived and postpay pending lines, subtracting delivered/refunded units; prepay pending does not ring.

Cashier watches the existing store websocket and refreshes the authorized workbench, with a 30-second recovery poll. New payments produce one media-stream tone and an orange-red table plus red table-menu badge. Device-local checkpoints survive app restart, scoped by server/store/session. Initial installation baselines historical paid orders. Clicking a table acknowledges only the paid count in its displayed snapshot; later arrivals remain unread. Badge counts tables, not items. Viewing does not change serving state. Pending serving shows the supplied swinging bell; reduced-motion setting disables swing. Audio requires audible device media volume.

Validation: 34 backend workbench tests, 4 shell tests, payment-alert deduplication/stale-view/independent-table regression passed; release built. Live read-only validation returned V1: one external paid order and one unserved unit; B1: zero. Real new APP payment and physical audio acceptance remains pending. Migration 324 and scoped workbench JS deployed; unrelated together-refund work excluded. Signed ARM32 APK installed with data preserved.

Sidebar spacing increased from 3 to 7; voucher label shortened to ??. Wine pickup stays inside that workspace.
