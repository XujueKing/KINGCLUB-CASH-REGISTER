# 清台原请求与恢复（UI未接入）

后续状态：清台操作及恢复UI已实现，见[TABLE_CLEAR_UI.md](TABLE_CLEAR_UI.md)。下文保留数据层阶段验证边界，不代表真实门店验收。

PendingTableClear固定HTTPS服务、员工、设备、门店、桌台及原场次，明确确认后生成UUID，命令只含storeRef/tableRef/sessionRef/requestId/clearConfirmed=true。不携带客户端订单或结清金额，不把本地判断作为清台授权。

TableClearJournal复用平台安全存储接口，独立pending_staff_table_clear_v1，单isolate串行、最多100条/1M字符、写后精确读回。相同场次或原请求不得被另一请求替换；不同员工不能查看/确认旧记录，也不能覆盖同场次未决请求。读取损坏、写入不明或确认清除失败均保留不确定性，不自动清理、不退回明文、不因退出登录删除。

控制器confirmTableClear先校验当前table.clear会话并保存原请求，再发1921；前后检查认证epoch、到期和权限，重复操作互斥。recoverTableClear默认只发1922；只有调用者显式retryOriginal=true且再次查回not_observed时，才重发同一原请求，不能改场次或UUID。未观察到不是取消证明，也不是成功。

TableClearResult严格核对state/requestId及11字段回执：原门店/桌台/场次/请求/员工、closed状态、精确有效UTC时间、单数/金额/离座数界限及金额与单数关系。只在匹配confirmed时清除对应签名记录。回执是历史原场次证据，不用于把当前新场次本地标为空台；UI成功后须重新读服务器。

验证：9项命令/回执/日志测试、7项控制器测试，覆盖持久化先于网络、重启丢响应只查回、原请求重发、损坏回执、容量/重复/跨员工、存储写后失败、迟到响应、并发及到期。全量282项通过、2项可选跳过；Flutter analyze无问题。存储/网络使用测试替身，不等于Android Keystore断电恢复或真实HTTPS清台验收。

本轮仅数据层及控制器，未接清台按钮/恢复界面，未构建安装新APK、部署或真实清台。下一步四语言UI、桌台刷新和生命周期，再补跨语言/设备验证；完整生产目标仍包含其他支付/核销等未完项。
