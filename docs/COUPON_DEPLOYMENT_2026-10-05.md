# Coupon deployment — 2026-10-05

- Backend image: `kingclub-v2-api:coupon-740a7087`, a scoped compiled overlay on a snapshot of the live container. Unrelated together-refund changes were excluded.
- Rollback container retained: `kingclub-v2-api-before-coupon-740a7087`.
- Internal readiness and public `/kingclub-v2/health` passed after replacement.
- Douyin prepare and single-coupon confirmation enabled for KINGCLUB Hunan University of Technology store only. Private profile matches the configured store, account and POI; the preparation encryption key is persistent. No credentials are stored in this document.
- Meituan remains disabled. AA fulfillment remains deferred. No real coupon was redeemed during deployment; real coupon acceptance remains pending.
- SUNMI D2 package `cn.kingclub.cashregister.preview` upgraded using `adb install -r`, without uninstalling or clearing data. Certificate matched the installed application.
- Installed APK SHA-256 matches build 389d8d9: `4214593504343495b1d52651a0ac2fd87db1ce50062e41ebd67e00b2315c89f9`.
- Login QR refreshed successfully after deployment. The previous employee session requires login again; coupon workspace acceptance is pending that login and a real scan.