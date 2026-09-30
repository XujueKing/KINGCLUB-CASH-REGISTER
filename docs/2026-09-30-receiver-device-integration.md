# 2026-09-30 接收机器设备联调

## 设备与安装包

用户已授权在本机接管收银机。当前 ADB 尚未识别交接中的 SUNMI D2，只有一台非目标手机。没有向该手机安装应用，没有清除任何设备数据。用户正在开启收银机 USB 调试；后续识别设备后必须显式指定序列号、核对机型和已安装包签名。

收银 main `53a02e8` 成功构建 ARM32 Release 候选包，尚未安装：

- 文件：`build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk`，16923328 字节。
- SHA-256：`624DDAC7753FC48D8FE41EBBC863D931BF895CB54C2E15D889A68BB28CD6F60C`。
- 包名 `cn.kingclub.cashregister.preview`，版本 `0.1.1`，ARM32 split versionCode `1002`，ABI `armeabi-v7a`。
- 开启 `CASHIER_REALTIME`、`CASHIER_VOUCHER_LOOKUP`、`CASHIER_VOUCHER_REPORT`，其余业务/打印开关保持默认值。
- APK 签名验证通过，仍为本机 Android Debug 开发签名。跨机器签名可能不同，不能未核对就保证可保留数据升级，更不能用卸载旧包解决签名冲突。

## 真实协议联调

复用统一后端已有隔离 Redis/MySQL/TLS 验证脚本，执行此前本地测试排除的 `live_backend_interop_test.dart` 和 `table_clear_backend_interop_test.dart`。测试使用本机新建的独立数据库、仅回环监听的 Redis、临时测试 TLS 证书和明确 TEST ONLY 数据；生产 Dart 客户端正常验证指定测试证书，没有关闭证书验证。

首轮员工登录、会话轮换、WSS、四渠道原付款准入查询通过；清台通知测试超时。已定位后端测试环境仅在上菜专项开启实时事件写入，清台专项遗漏该开关。后端测试脚本已修正该配置，生产功能默认值未修改。

最终重跑通过：`live_backend_interop_test.dart` 一次，以及 `table_clear_backend_interop_test.dart` 正向清台、重新开台后的历史回执重放各一次，共三次 Dart 测试执行全部通过。

验证了员工登录/会话轮换/退出、证书校验的 HTTPS/WSS、四渠道原付款准入查询、清台并发防重、单张清台回执、两条事务事件经 Redis 到达 WSS、按门店桌台重读，以及旧请求重放不改变新场次。后端完整 verify 同时通过；临时 Redis/MySQL 已停止。

真实协议测试不代表收银机 UI、扫码枪、打印出纸、共享线上数据库或真实渠道交易验收。当前候选包待目标设备识别与签名核对，未安装。
