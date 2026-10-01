# 支付宝未付款关闭恢复（进行中）

ProviderPaymentResult 已接受原支付宝收款请求对应的 closed_unpaid / receipt.orderRetained=true，与微信共用提示和原请求恢复记录处理。必须匹配原门店、员工、订单、请求、渠道、金额和币种，不能仅凭 closed_unpaid 字符串清除记录；不会显示付款成功或退款成功。会员余额不接受此渠道凭证。

后端单笔共用归档事务及 268 草稿配套实现；显式关单按钮、持久化发送记录和整桌支付宝关闭尚未完成，因此本节点不构建安装、不声称用户已可发起关单。现有已安装版本保持 b669929。

验证：provider_payment_test / provider_payment_panel_lifecycle_test 共 9 项通过，两份修改文件 analyze 无问题。后端实际 MySQL 已验证支付宝归档后的现金重收与清台，关闭渠道证据为合成输入；不能据此声称已完成官方渠道实测。
