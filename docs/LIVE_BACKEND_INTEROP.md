# Dart客户端与隔离后端TLS互通（2026-09-29）

新增test/live_backend_interop_test.dart，由ccsop-service新建MySQL/Redis隔离测试入口选择性启动Flutter测试进程。未配置CASHIER_TEST_BASE时显式跳过，不把常规单元测试当作在线互通通过。

实际使用CcsopHandshakeClient、CcsopClient、IoJsonTransport、StaffSession、TableSnapshot、IoCashierSocket及CcsopRealtimeCodec，无模拟传输、无替代服务结果。协议两端分别运行Dart与Node实际实现。

先用默认信任根访问临时自签HTTPS，确认TRANSPORT_FAILED；随后仅在测试HttpOverrides范围使用SecurityContext(withTrustedRoots:false)信任临时证书。未配置badCertificateCallback，未改生产TLS逻辑或系统信任根。服务只绑定127.0.0.1随机端口，证书SAN含127.0.0.1，证书/私钥留在仓库外临时目录（两天有效，重跑过期后需重新生成），不打入APK。

验证：独立TEST_ONLY员工加密登录、服务端会话解析、门店/员工/唯一桌台及已提交名称解析、实际WSS建立和加密ping/pong、握手续期、新密钥读取成功、旧密钥拒绝INVALID_SIGNATURE、旧WSS下一次ping校验关闭、注销后请求拒绝SESSION_EXPIRED。账号密码由后端测试夹具随机生成，只传子进程环境，不写文件、不打印、不上传。后端原四个接口仅在本次新建测试库启用，结束恢复禁用。

实测qJ6xXR隔离MySQL（201迁移）及AVKmw7kv隔离Redis，附带Node HTTP/WS/outbox全链路与本Dart TLS测试全部通过，退出0，所有专属服务已关闭。Flutter analyze无问题，常规217项测试通过、2项跳过（可选截图及本在线测试）；本在线测试在上述隔离运行中单独1项通过。后端完整verify190文件/1378测试通过，Docker静态检查分支跳过。

本轮仅测试及文档，无应用业务代码变更，不需要重装APK。没有验证安卓UI实际登录、Android Keystore/断电恢复、公开CA证书/反向代理、生产域名或正式账号。Dart测试验证实时心跳及会话变更，Node联调验证SQL队列→Redis→WS通知；尚未合为Dart客户端收到事务通知并触发UI重读的单一验收。真实支付/核销、完整营业及生产部署仍未验收。
