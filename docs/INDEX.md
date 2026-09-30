# 开发与功能文档入口

更新：2026-10-01。当前文档并非完整的生产验收包：实现说明较多，部分产品流程、跨端验收和运维操作手册仍需补齐。当前状态以功能总表为入口，旧日期记录保留为证据，不能覆盖后续核查结论。

| 类别 | 入口 | 当前用途 |
| --- | --- | --- |
| 产品范围、参考功能、缺口与验收 | [FEATURE_MATRIX](FEATURE_MATRIX.md) | 每个开发节点同时维护状态、证据和剩余任务 |
| UI 参考与本轮问题 | [首页与参考审查](2026-10-01-home-review.md)、[全屏](2026-10-01-fullscreen.md)、[商品目录](2026-10-01-catalog-read-and-layout.md) | 8 张参考截图对应关系、紧凑布局、全屏和验证边界 |
| 生产目标与开发日志 | [PRODUCTION_GOAL](PRODUCTION_GOAL.md)、[单一产品](2026-10-01-single-product.md) | 历史增量不能当成当前功能总表 |
| 身份与接口 | [STAFF_SESSION](STAFF_SESSION.md)、[登录](2026-10-01-account-only-login.md)、[会员识别](2026-10-01-member-identity.md)、[交接](CODEX_HANDOFF_BACKEND_INTEGRATION.md) | 员工会话、门店授权、接口契约 |
| 桌台与订单 | [LIVE_TABLES](LIVE_TABLES.md)、[OPENING_CLIENT](OPENING_CLIENT.md)、[LIVE_ORDERS](LIVE_ORDERS.md)、[点单](ORDER_CART_UI_2026-09-29.md) | 快照、每日规则、下单及恢复 |
| 支付与余额 | [渠道接入](PROVIDER_PAYMENT_INTEGRATION.md)、[渠道缺口](PAYMENT_CHANNEL_GAP_AUDIT.md)、[充值](STORE_RECHARGE.md) | 收款、查单、账户和退款边界 |
| 券、账务与交班 | [核销查询](VOUCHER_LOOKUP.md)、[核销报表](VOUCHER_REPORT.md)、[交班](SHIFT_RECONCILIATION.md) | 查询不是首次核销，核销报表不是全部财务 |
| 硬件与验证 | [打印](PRINTER_INTEGRATION.md)、[本地验证](2026-09-30-local-verification.md)、[设备验证](2026-09-30-android-build-verification.md) | 区分代码测试、设备读取、实际打印与营业验收 |

仍需完善：会员/预约/存酒的收银操作规范，端到端验收脚本，综合财务口径和渠道账单流程，交班归属规则，故障处置与门店上线清单。接口/数据库的权威定义在统一后端仓库；跨端缺口详见其中 `docs/commerce/2026-10-01-unified-business-review.md`。
