# Android 本地构建验证

## 最新真机保留数据升级

2026-09-30 11:39，对既定授权收银机先只读核对型号、前台及截图：前台为
独立收银应用空白员工登录页，无正在操作的订单。旧 APK 已拉取到本机私有
备份目录 `D:/DeviceBackups/KINGCLUB-CASH-REGISTER/pre-voucher-read-20260930-113848/previous.apk`，
设备原件和本机副本 SHA256 均为
`2FA4CD91BACA1EA02EE7B9561EF82F49442ADA550847992999DF9ED30E5DAEB1`。
这是 APK 备份，不含应用数据/安全存储；新版本 code1002 高于旧 code2，
普通降级可能受系统限制，不能承诺仅凭旧包无损回退数据。

新旧包签名 SHA256 均为
`7f839333dcc272a167a129317160c2a82b25b5ba8479529eac802be97c9c93ea`。
显式指定目标序列号执行 install -r 成功，未卸载或清数据，未覆盖收钱吧。
安装后读取 APK 哈希与下文 10DF6FFF 联调包一致；版本 0.1.1/code1002，
ARM32。am start -W 返回 COLD/ok，TotalTime 948ms、WaitTime 971ms。
截图核对仍为独立员工空白登录页；当前应用进程限定最近300条日志中
FATAL EXCEPTION/ANR/E-flutter 模式匹配0，只证明短窗口未见匹配异常。

本段覆盖下文“未安装”的历史状态。未登录员工、申请权限、打印、收款、
核销、迁移或部署；未操作其他手机。冷启动不是长时性能验收，安装成功
不证明新接口已上线、员工权限已配置或业务工作台完成端到端验收。

## 最新核销读取联调产物（未安装）

默认开关关闭的最新源码重建成功，仍为下文 1D20A55A 哈希；由于页面入口
受编译开关控制，不能据此证明核销查询/报表进入可访问产物。
随后重建时明确增加以下三个参数，其余使用下文 ARM32 release 命令：

```text
--dart-define=CASHIER_VOUCHER_LOOKUP=true
--dart-define=CASHIER_VOUCHER_REPORT=true
--dart-define=CASHIER_REALTIME=true
```

构建成功，16.1 MB，SHA256：
`10DF6FFF313BE46F1472293BB53BDFBEE989440196C52F2071487DA1B660C74F`。
核对包名 cn.kingclub.cashregister.preview、0.1.1/code1002、仅 armeabi-v7a，
apksigner 验证通过，仍 Android Debug 签名。当前标准输出 APK 已是此配置，
不再是下文默认配置；另保留同哈希副本：
`build/app/outputs/flutter-apk/kingclub-voucher-read-10df6fff-arm32.apk`。

没有启用付款码支付/余额/充值/整桌结账/打印输出的默认关闭编译开关，
但这不代表整个应用只读：既有现金/点单等操作仍受员工权限与服务端控制。
新增三个开关仅用于核销读取及经营通知的后续隔离联调，不自动执行查询或
提供可用员工身份；1950 后端迁移仍未执行，公开核销确认仍未接通。
本次未安装、启动设备应用或登录员工，不宣称端到端、扫码枪或真实打印通过。

## 构建与检查

Flutter 3.47.1，执行：

```text
flutter build apk --release --target-platform android-arm --split-per-abi --no-pub
```

成功生成 `build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk`（约 15.9 MB）。
SHA256：`1D20A55AAA16E416619FF79E923DEA54F6F706B4DA4122A6DA319EE107FD687D`。
这是本轮未提交工作树的本地产物，不是可复现正式发布标记。

Android SDK 36.1.0 工具检查：

- aapt：仅 `armeabi-v7a`；minSdk 24、targetSdk 36。
- 包名 `cn.kingclub.cashregister.preview`，版本名 0.1.1、versionCode 1002。
  split-per-abi 按 Flutter 规则增加 ABI 版本偏移；不得误写为原非拆分包的 2。
- apksigner verify 通过，但证书为 Android Debug，仍属内部验证包。
- 未传入 CASHIER_PREVIEW，入口是独立员工登录；未启用 CASHIER_* 业务编译开关。
  整桌结账、真实渠道等默认关闭功能不能由这次优化构建证明可用。

## 修复的打包风险

初次未使用 split-per-abi 时，APK 虽包含 ARM32 的 libapp/libflutter，依赖还带入
ARM64/x86_64 的 libdartjni。aapt 因此列出三个 ABI，但其他 ABI 没有完整 Flutter
引擎，不能把它作为完整多架构包交付。本轮改为明确 ARM32 拆分，检查结果仅一个 ABI。

`scripts/build-preview.ps1` 同步采用 split-per-abi 并选取相应 APK 文件名，避免
日后预览构建再次产生混合不完整 ABI。PowerShell 语法检查通过；本轮未执行该脚本的
预览构建或安装分支，实际构建的是上述非演示入口命令。旧 app-release.apk 未删除，
不能把它误当作本轮推荐的 ARM32 产物。

## 原生测试

初试 `:app:testReleaseUnitTest` 失败：当前插件没有该任务。核对实际任务列表后运行
`:app:testDebugUnitTest -Ptarget-platform=android-arm`，成功。
`UsbRasterFramesTest`：4 tests、0 failures、0 errors、0 skipped（XML 结果已核对）。
覆盖条带大小、指令边界、截断与模式拒绝、图像字节不得解释为额外命令。
不代表 USB 授权/连接、真实走纸、切刀、钱箱或中文字体已验收。

## 仍未完成

### 后续设备只读复核

对既定授权收银机使用显式 `adb -s`：get-state 返回 device；型号
D2_2nd-SQB，Android 11，ABI 为 armeabi-v7a/armeabi。仅查询目标设备，
未枚举或操作其他手机。

当前安装独立包版本 0.1.1、versionCode 2、primaryCpuAbi armeabi-v7a，
lastUpdateTime 为 2026-09-29 23:12:05。今天的核销查询/报表会话到期修复
未包含在这个安装版本中；不能用已安装状态证明最新代码完成真机验证。

`dumpsys usb` 当前 host_manager.devices（不是历史 connections）可见
VID 1155 / PID 22339、USB Printer Port、接口 class 7/subclass 1/protocol 2，
OUT 地址 1、IN 地址 130，均 type 2（bulk）。设备描述没有给出 XP-80U 型号，
不凭通用 USB 名称断言具体品牌、纸宽、权限或就绪状态。
没有打开 USB 接口、发送打印指令、申请权限、启动/停止应用或安装新包。

最初构建阶段未连接设备；随后仅进行了上述只读复核。没有安装/启动应用、
读取生产凭证、执行交易、权限变更、数据库迁移或部署。
正式签名和发布版本方案、带业务开关的隔离联调构建、Android 11 ARM32 真机性能、
XP-80U 实际打印及生产渠道验收仍待完成。Gradle 的弃用/插件兼容警告尚需后续评估，
本轮未升级构建工具或改动签名身份。
