# Physical wine storage locations

The existing storage dialog reads store-specific presets from K261004002007 context. It displays cabinet rows from highest to lowest and columns left to right. Staff must choose the physical compartment before scanning the member. The location is included in the durable pending request and the server receipt; conflicting retries cannot move a stored bottle. Compartments are not exclusive reservations. Existing holdings are not automatically assigned a position.

Backend migration 325 adds store presets and a nullable location to the existing holding. Backend commit 3389ffe6 deployed; full verify passed (3796 tests). Cashier tests cover shelf orientation, selection, automatic deposit and lost-response recovery (3 tests). Release ARM32 signature matched the installed application; upgraded with install -r, preserving data.

This increment completes physical location selection and persistence. Short-label printing and bottle-label pickup remain pending.
