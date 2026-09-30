# 独立员工实时连接与桌台刷新

2026-10-01 更新：线上已补齐独立收银 WebSocket 精确代理路径，并启用 KINGCLUB 收银实时服务。独立诊断会话通过加密员工登录、桌台读取及公网 connection.ready 验签解密，随后退出。实际订单变化投递和跨端业务仍待验收；不能把握手成功等同于全部实时闭环。默认配置开关仍为 false，部署须显式设置。部署证据见后端 `docs/commerce/2026-10-01-cashier-realtime-rollout.md`。

## 协议与安全

- 复用已有加密codec，增加限定端点/cashier/ws；签名路径是内部路径，外部地址保留配置的代理前缀。clientId固定store:<会话门店>，每次重连重新生成nonce/requestId及连接密钥。
- IoCashierSocket仅允许wss，保持系统证书验证，关闭压缩和HTTP重定向，禁止带userinfo。适配器只暴露SDK升级所需的openUrl；其他HttpClient操作失败关闭。连接超时关闭HTTP客户端，迟到socket也关闭。异常统一替换，不打印含签名参数的原始URL。
- ready必须返回本会话门店；随后只接受pong及commerce.changed，严格检查连续序号、时间窗口、门店、固定topic和payload字段数量。16KiB消息上限、16条待解密上限；不接受支付成功事件或业务写命令。
- 20秒加密ping，45秒未收到pong时下个心跳检查断开；ready等待8秒，IO连接总超时10秒。断线采用1/2/4/8/16/30秒加随机抖动重试，会话过期停止，不自动刷新凭证。
- 退出、凭证轮换或页面销毁关闭该会话连接；退后台停止，回前台重新连接并查询。异步请求按代次检查，迟到连接不能恢复旧会话，连接请求不并发重叠。

## 页面行为

- 显示实时通道连接中/已连接/未连接四语言提示；未连接时仍可手动查询。
- ready及合法变更仅使桌台失效，400ms合并通知后调用1902重新读取第一页；正在查询时最多再排一次刷新，不从通知内容改金额、库存、付款或核销状态。
- 编译开关关闭时保持原来的手动只读快照，不启动socket。不能将编译开关打开等同于渠道、服务或门店授权已完成。

## 验证边界

客户端测试采用明确的协议/传输替身，覆盖路径签名、ready、事件、跨店/重放/序号跳跃拒绝、迟到连接、重连随机数、会话过期、合并刷新及后台停止。另有独立Node crypto验证/cashier/ws路径签名。尚未用此Dart客户端连接真实TLS服务器、代理或Android设备，证书、设备网络、长时稳定性仍须验收。

本轮flutter analyze无问题；全量55项测试通过、1项可选截图测试跳过，Git差异空白检查通过。

ARM32 release验证构建成功（15.3MB）：`flutter build apk --release --target-platform android-arm --dart-define=CASHIER_PREVIEW=false --dart-define=CASHIER_REALTIME=true --no-pub`。显式包含员工入口与实时代码，不是默认演示构建；没有内置真实地址/账号，没有安装。仍使用现有开发签名、包名cn.kingclub.cashregister.preview和0.1.1+2，不是正式发布签名或生产验收。

构建产物SHA256：8491BDAEFF0017455F3C2BFB011A4085C2DDFAF1913E67E5CEF53E65D01C6787。build/app/outputs/flutter-apk/app-release.apk已由本验证构建替换；此前文档哈希仅对应历史构建，不代表当前产物。初始收银工程仍未提交/推送，本轮也未修改后端运行配置。
