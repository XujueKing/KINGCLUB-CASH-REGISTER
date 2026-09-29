# 员工会话安全存储交接（2026-09-29）

发现：登录/续期响应先通过 StaffSession.fromServer 的时间校验，再等待安全存储写入，原 _install 只复查 epoch。如果写入期间访问会话到期，仍会创建业务客户端并发布到内存。

新增登录/续期两个可控时钟测试，暂停 SecretStorage 写入，在到期边界恢复写入。原代码两个测试均失败：操作正常完成而非 SESSION_EXPIRED。修复后，_install 写入前后及 SessionVault.saveIfCurrent 回调均要求当前认证 epoch 和未过期的访问凭据；失效写入由 vault 删除，不创建业务客户端，登录/续期失败路径正常清理。

另新增实际控制器的“写入中退出”竞争测试，验证 SESSION_CHANGED、无业务客户端、内存会话为空、持久化会话不存在。保留既有序列化存储、失败关闭和不自动重试策略，不变更服务端期限或会员 APP 登录流程。

本轮均为本地自动化测试替身，不是真实 Android Keystore 慢写入/断电验收。没有真实登录、改权、交易或线上部署；已安装 57bbebb 仍不含本轮及 8e0ad86 修复。

验证结果：flutter analyze 无问题；完整 flutter test 447 项通过、5 项可选跳过。尚未重新构建或安装本轮代码。
