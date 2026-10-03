# 整桌收银

总额、已付、应收在同一收银界面显示。现金使用触屏数字键盘；微信、支付宝沿用统一服务商收款及原请求恢复，支持无焦点扫码。独立 POS 刷卡成功后记录凭证号，服务端单独按 pos 渠道入账、拒绝同店重复凭证，不驱动 POS 机。

整桌打折/免单仅改变未付款商品，一次负责人会员码授权、一次数据库事务。原价和成交价格、操作员、授权人、时间保存在现有明细调整流水。未知结果保留原请求，重新打开先查询，避免重复优惠。储物袋折扣券规则尚未开发，本轮显示暂不可用；不自动套用 AA 券。

未付款小票独立标识“未付款 · 非收款凭证”，复用 USB 栅格打印设备选择与权限。实际纸张宽度、打印机授权和出纸仍须实机确认；代码测试不等于真实收款。

后端发布只含本次收银修改，基于 5ad61242 隔离构建，迁移 295（POS渠道/API）及 297（整桌优惠API），不包含同时开发中的组局套餐。后端完整校验和客户端收款恢复测试完成后保留数据升级目标 SUNMI。

## 发布记录

2026-10-04 已发布独立收银镜像 cashier-checkout-20261004，KINGCLUB 备份校验通过，迁移仅 295/297，运行检查通过；隔离构建 npm run verify 通过，340 个测试文件、3600 项测试通过。收银端 66 项收款/账单相关测试及负责人扫码与未知优惠恢复测试通过。目标 SUNMI 保留数据升级，签名匹配，原登录与桌台读取正常。未发起真实收款、刷卡、免单或打印验证。Flutter 分析无错误和警告，仍有既有及新增样式建议未清理。


### Checkout amount correction (2026-10-04)

The V1 missing totals were caused by the server compact request registration rejecting accountType=null on non-balance channels. Backend migration 298 corrects the five affected contracts without changing domain validation. Read-only device verification confirmed totals display again. Cash touch input also normalizes leading zero and allows replacing an exact-amount shortcut; 14 dialog tests pass. The reported physical touch mismatch is still awaiting a reproducible button/location example; no hardware calibration change has been made.
