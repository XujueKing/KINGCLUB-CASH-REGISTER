# Physical wine storage locations

The existing storage dialog reads store-specific presets from K261004002007 context. It displays cabinet rows from highest to lowest and columns left to right. Staff must choose the physical compartment before scanning the member. The location is included in the durable pending request and the server receipt; conflicting retries cannot move a stored bottle. Compartments are not exclusive reservations. Existing holdings are not automatically assigned a position.

Backend migration 325 adds store presets and a nullable location to the existing holding. Backend commit 3389ffe6 deployed; full verify passed (3796 tests). Cashier tests cover shelf orientation, selection, automatic deposit and lost-response recovery (3 tests). Release ARM32 signature matched the installed application; upgraded with install -r, preserving data.

## Bottle labels and pickup (2026-10-05)

New deposits now create one physical holding/QR per bottle. Fixed 80mm printer output contains location, nickname, existing public member number, wine/specification, remaining percentage, expiry and the opaque bottle QR. Printing is automatic with cut and no preview. Output is 576x216 dots (27mm content); the printer cutter feed is reserved for a 35-40mm total label, pending physical measurement. Print failure offers explicit reprint without repeating deposit; accepted labels are fenced per bottle across restart.

Select a current table, choose voucher > stored wine, scan the member code, retrieve the indicated bottle and scan its label. Only the same member/store available bottle can be collected; one transaction records pickup and served state, links membership and updates the storage bag. No sales stock or money is moved. Table bills show the collected bottle as served, including closed-session history. Lost replies are recovered by original request; raw member codes are held only in memory.

Older one-bottle records can be labeled by choosing their actual shelf with Print label. Their holdings, expiry and ownership are retained. Old multi-bottle records are not split without verifying physical bottles. No actual deposit or pickup was fabricated during deployment.

Backend migration 326 and the three affected compiled modules deployed with backups, runtime health/readiness and real read-only served query passed. Cashier installed with matching certificate and install -r, preserving data.

Verification: 3808 backend tests passed; two deployment-check process timeouts passed on isolated rerun (3/3), build/migration/static checks passed. Cashier full suite: 1005 passed, 5 skipped, 7 failed. Three printer tests require CASHIER_USB_RASTER_OUTPUT=true and passed with that flag; the remaining four failures reproduced unchanged at baseline f52cc98 in opening/cart/recovery tests. Targeted printer, labels, pickup, deposit, voucher and bill tests passed (29). Monochrome QR independently decoded with ZXing. Physical paper output/height and customer-operated pickup still require on-device confirmation.
