# 2026-09-30 接收机器设备联调

## 设备与安装包

用户已授权在本机接管收银机。后续 USB 授权完成，已识别 SUNMI D2_2nd-SQB：Android 11、armeabi-v7a、1366×768。所有设备命令均显式指定目标收银机，未操作同时连接的手机、未清除设备数据。

现有应用为 0.1.1 / versionCode 1002，拉取安装 APK 后核实 SHA-256 为交接中的 `10DF6FFF313BE46F1472293BB53BDFBEE989440196C52F2071487DA1B660C74F`。原包与本机候选包的开发签名不同，因此未尝试覆盖安装或卸载。已请求用户通过私有途径提供原电脑的 debug.keystore，用于保留应用数据升级；签名文件不得提交 Git。

已启动现有应用并核对独立员工登录页。打印设备检查识别一台已授权 USB 打印类候选设备，简体中文 576 点 TEST ONLY 小票预览正常生成。没有发送打印、切纸、钱箱或真实交易指令；结束检查后返回员工登录页。USB 候选存在及预览成功不等于 XP-80U 真实出纸验收。

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

真实协议测试不代表扫码枪、打印出纸、共享线上数据库或真实渠道交易验收。当前候选包因签名不一致尚未安装；现有版本仅完成上述启动、登录页和打印预览检查，尚未进行真实员工登录。
