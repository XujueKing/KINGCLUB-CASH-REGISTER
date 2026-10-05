# Physical wine storage locations

The existing storage dialog reads store-specific presets from K261004002007 context. It displays cabinet rows from highest to lowest and columns left to right. Staff must choose the physical compartment before scanning the member. The location is included in the durable pending request and the server receipt; conflicting retries cannot move a stored bottle. Compartments are not exclusive reservations. Existing holdings are not automatically assigned a position.

Backend migration 325 adds store presets and a nullable location to the existing holding. Backend commit 3389ffe6 deployed; full verify passed (3796 tests). Cashier tests cover shelf orientation, selection, automatic deposit and lost-response recovery (3 tests). Release ARM32 signature matched the installed application; upgraded with install -r, preserving data.

## Bottle labels and pickup (2026-10-05)

New deposits now create one physical holding/QR per bottle. Fixed 80mm printer output contains location, nickname, existing public member number, wine/specification, remaining percentage, expiry and the opaque bottle QR. Printing is automatic with cut and no preview. Output is 576x216 dots (27mm content); the printer cutter feed is reserved for a 35-40mm total label, pending physical measurement. Print failure offers explicit reprint without repeating deposit; accepted labels are fenced per bottle across restart.

Select a current table and open the unified voucher scanner. Scan the customer's existing APP pickup code (43-character short-lived token), not a member identity code. The server resolves the owner, validates the member session and holding version, attaches the member, and registers paid/not-served stored wine in the bill. Then scan the physical bottle label to collect and serve it. Registration does not decrement storage quantity or create a sale; physical collection does, without sales-stock or money movement. Bills show stored wine under all/paid filters. Durable request lookup recovers lost replies; raw customer credentials remain only in memory.

The scanner routes known Douyin links, APP pickup tokens and physical bottle labels automatically. Ambiguous codes ask for a channel; Meituan/KING voucher adapters remain unavailable rather than guessing or reporting success.

Older one-bottle records can be labeled by choosing their actual shelf with Print label. Their holdings, expiry and ownership are retained. Old multi-bottle records are not split without verifying physical bottles. No actual deposit or pickup was fabricated during deployment.

Backend migration 326 and the three affected compiled modules deployed with backups, runtime health/readiness and real read-only served query passed. Cashier installed with matching certificate and install -r, preserving data.

Verification: 3808 backend tests passed; two deployment-check process timeouts passed on isolated rerun (3/3), build/migration/static checks passed. Cashier full suite: 1005 passed, 5 skipped, 7 failed. Three printer tests require CASHIER_USB_RASTER_OUTPUT=true and passed with that flag; the remaining four failures reproduced unchanged at baseline f52cc98 in opening/cart/recovery tests. Targeted printer, labels, pickup, deposit, voucher and bill tests passed (29). Monochrome QR independently decoded with ZXing. Physical paper output/height and customer-operated pickup still require on-device confirmation.


## Pickup-code-first correction (2026-10-05)

Migration 327 extends existing holding/pickup records for requested state and request lookup; no parallel inventory or customer identity table. Backend 39 targeted tests and 20 cashier tests passed. Backend build/static/migration checks passed; deployed health/readiness passed. ARM32 build signed with matching installed certificate, install -r succeeded. Device is at V1 unified scanner; real customer scan and bottle scan are pending user cooperation. Flutter analyzer reports informational lint only.


## Unified product card and explicit physical serving

Stored wine now uses BillProductCard and the original store-scoped commerce product material, name and specification. It retains a separate physical holding identity so sale quantities/prices cannot merge into a stored bottle. The amount displays Stored wine; paid/served badges share sale-card styling. Registration no longer adds a label reprint card to the scanner workspace.

Tap the stored wine card for its large shelf location, then Serve to arm the scanner. The physical label must match that exact itemRef and table/session; unrelated bottle scans and replay mismatches are rejected. Successful delivery closes the dialog and refreshes that bill. Already served bottles open read-only location details.

StaffAccessPage now retains the same workspace element during a same-session credential refresh, with touch input blocked while authentication is unavailable. Stable identity keys exclude rotating credential objects; failed refresh/revocation removes the workspace. A widget regression verifies retained state across refresh and removal on revocation. This addresses the timed return to the table overview.

Backend 23 pickup tests passed. Cashier pickup, bill, voucher, access and refresh regressions passed; ARM32 signed upgrade installed preserving data. Real bottle picture/name confirmed on the attached terminal. New physical serving still requires the customer's next real bottle scan; no transaction was simulated.
