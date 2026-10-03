最新：触屏折扣、数字键盘与服务器扫码授权已发布；当前操作要求见 TOUCH_PRICE_AUTHORIZATION.md。

# Release status ? 2026-10-03

Price, unit discount and complimentary items are deployed to KINGCLUB and installed on SUNMI DAB6264H90115 with matching certificate and preserved application data. The existing employee login and the item price dialog were verified on the device, including the complimentary expense-owner scan entry. The local test selection was removed without confirming an order or charging/refunding money.

Pending selections and submitted unpaid items support price changes. Special-price selections remain separate from later regular-price additions. Complimentary items retain original price, operator, optional scanned expense owner and inventory history; they do not create cash receipts. Existing order, adjustment and inventory records are reused; no business tables were added.

Backend migrations 289?291 only were applied after a verified KINGCLUB-only backup. Runtime health/readiness checks passed. Backend: 3562 full-suite tests plus 265 edge-case regression tests; cashier: 968 full-suite tests and 26 return regression tests; APP compatibility: 10 tests. APP source compatibility is committed separately; no iPhone build was installed in this release.

The older entries below describe earlier stages and are superseded by this release status. The broader change from payment-time stock issue to actual-serving-time stock issue is still a separate unfinished item.

---

# 商品特价进度（2026-10-03）

本批代码尚未安装到收银机，不能当作已上线。

已接上待下单卡片改价弹窗、单位折扣计算及特价标签；独立 selectionRef 保存到本地草稿和下单请求。再次点击同商品新建普通价格行，原价和特价共享库存上限。已保存账单按商品及特价分行标识汇总，减量队列使用相同标识，避免减错同款行。

客户端验证整批回执：根订单金额、各订单金额、唯一订单号和整批金额必须与本次所选行一致。草稿恢复检查同款各行的合计库存。商品快照校验特价单价与实际计价一致。

已提交未付合并卡片改价已接通：一张卡片中的各笔未付款原订单批量提交，已付款不改价，整次修改成功后才更新对应本地待下单行。特价卡片加号沿用特价；菜单加购按原价。仍待接通零元免单结算及赠送承担人。后端价格入口保持关闭，尚未安装到设备。后端完整边界记录在 ccsop-service/docs/commerce/CASHIER_ITEM_PRICE_PROGRESS.md。

针对性测试：草稿/请求/交互/商品分组 57 项通过，账单/快照/分组 44 项通过（分组测试有重叠）；live 静态检查无问题。全量结果随后记录。

全量测试初次运行 956 项通过、5 项跳过、3 项旧用例失败。三个旧用例仍要求二次确认、已删除的成单说明或未知库存可加购；按已确定的交互更新后，三个相关文件回归全部通过。未进行真实收款或设备安装。

本次继续开发验证：点单、已提交卡片改价、逐单回执及账单回归 44 项通过，live 静态检查无问题；四语言价格交互覆盖已付数量排除、整批未付数量、单位价格和特价加购。后台推送刷新后仍按会员会话及桌台范围确认本地回调，避免同桌刷新吞掉草稿价格更新。
