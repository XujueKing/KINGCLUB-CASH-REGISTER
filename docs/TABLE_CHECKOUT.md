# 整桌收银

## 2026-10-06 触屏布局与统一扫码

明细紧接“整桌结账”标题，金额区只占右栏：总额、已付为小字，应收为大字。付款入口合并为扫码付款、现金收款、银行码收款、独立 POS；不再摆四个扫码渠道按钮。现金数字键盘和员工扫码确认按钮并列，目标横屏无需滚动即可操作。默认扫码枪监听不依赖输入焦点。

微信、支付宝本地识别渠道；KING 专用付款码在既有 K260930001937 报价请求中由服务器识别顾客授权的本店余额/平台现金账户。客户端不猜账户、不自动补足、不把普通会员身份码作为扣款授权。付款时仍重新验证授权，并保留原请求恢复与防重复扣款流程。

现金和银行码共用原整桌手工收款接口 K260930001942/1943。首次确认必须扫当前收银员会员码，银行码只能选门店既有收款账户，金额必须等于应收；现金可找零。回执记录员工与账户，原码不保存。银行码单独作为 bank_code 渠道，不冒充微信接口到账或现金。

本次已发布后端迁移 340/341，完成签名一致的 Android 保留数据升级，并检查扫码页及现金页实际屏幕；未发起真实扣款。相关客户端 29 项、服务端 32 项针对性测试通过。会员付款门店启用配置当前仍缺，不能将自动识别测试视作余额实扣验收。平台/本店券的整桌抵扣及分账仍未开放，入口灰显；不得按券名称直接减钱。

总额、已付、应收在同一收银界面显示。现金使用触屏数字键盘；微信、支付宝沿用统一服务商收款及原请求恢复，支持无焦点扫码。独立 POS 刷卡成功后记录凭证号，服务端单独按 pos 渠道入账、拒绝同店重复凭证，不驱动 POS 机。

整桌打折/免单仅改变未付款商品，一次负责人会员码授权、一次数据库事务。原价和成交价格、操作员、授权人、时间保存在现有明细调整流水。未知结果保留原请求，重新打开先查询，避免重复优惠。储物袋折扣券规则尚未开发，本轮显示暂不可用；不自动套用 AA 券。

未付款小票独立标识“未付款 · 非收款凭证”，复用 USB 栅格打印设备选择与权限。实际纸张宽度、打印机授权和出纸仍须实机确认；代码测试不等于真实收款。

后端发布只含本次收银修改，基于 5ad61242 隔离构建，迁移 295（POS渠道/API）及 297（整桌优惠API），不包含同时开发中的组局套餐。后端完整校验和客户端收款恢复测试完成后保留数据升级目标 SUNMI。

## 发布记录

2026-10-04 已发布独立收银镜像 cashier-checkout-20261004，KINGCLUB 备份校验通过，迁移仅 295/297，运行检查通过；隔离构建 npm run verify 通过，340 个测试文件、3600 项测试通过。收银端 66 项收款/账单相关测试及负责人扫码与未知优惠恢复测试通过。目标 SUNMI 保留数据升级，签名匹配，原登录与桌台读取正常。未发起真实收款、刷卡、免单或打印验证。Flutter 分析无错误和警告，仍有既有及新增样式建议未清理。


### Checkout amount correction (2026-10-04)

The V1 missing totals were caused by the server compact request registration rejecting accountType=null on non-balance channels. Backend migration 298 corrects the five affected contracts without changing domain validation. Read-only device verification confirmed totals display again. Cash touch input also normalizes leading zero and allows replacing an exact-amount shortcut; 14 dialog tests pass. The reported physical touch mismatch is still awaiting a reproducible button/location example; no hardware calibration change has been made.


### Session refresh and business-day checkout fix (2026-10-04)

Employee-session refresh now reloads the quote or restores the original durable checkout instead of leaving the dialog cleared. An ended/changed table session closes the old checkout route, including after the 06:00 business-day rollover. Initial quote failures offer a read-only retry and no longer claim that an unsubmitted payment needs reconciliation. Existing payment uncertainty handling is unchanged. All 17 checkout dialog tests passed, including session refresh, quote retry and ended-session navigation.


### Preparation response recovery

When preparation fails after the original request was persisted, the dialog automatically queries that same request once. A confirmed prepared result restores the scanner immediately; unknown/missing results retain the original recovery controls. This never retries preparation or submits payment automatically. All 18 dialog tests passed.
