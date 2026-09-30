# KINGCLUB CASH REGISTER

配合 KINGCLUB APP 扫码点单和 CCSOP KINGCLUB 商务服务的门店前台安卓收银机项目。

当前统一入口：[功能与验收总表](docs/FEATURE_MATRIX.md)、[开发文档索引](docs/INDEX.md)。只维护一套最终产品，在真实 UI 和统一业务上迭代；历史记录不作为当前完成状态。跨机器背景见[交接说明](docs/CODEX_HANDOFF_BACKEND_INTEGRATION.md)。

当前已验证独立员工登录、自动门店归属、真实桌台读取和保留数据升级。业务模块有大量实现和测试，但写接口启用、渠道配置、跨端及真实营业验收仍有缺口，不能按页面存在推断已可营业。

已开启[生产目标](docs/PRODUCTION_GOAL.md)：独立员工账号，微信／支付宝／现金／会员余额，美团／抖音来客团购核销。渠道资质、支付/核销、员工开台下单、清台、交班和打印均未完成生产验收；不是已可营业版本。

## 工作区

- 收银机：`D:\WEB3_AI\KINGCLUB-CASH-REGISTER`，仅 `main`。
- 会员 APP：`D:\WEB3_AI\KINGCLUB-APP-V2`。
- 统一 KINGCLUB 后端：`D:\WEB3_AI\ccsop-service`，`business/kingclub-v2`。聊天、商务已合并，统一运行 `src/main.ts`。
- 历史商务目录 `ccsop-service-commerce` 暂留，不再继续开发，不自动删除。

物业与 KINGCLUB 部署在同一服务器，使用不同业务数据库和服务。收银机只对接经过授权的 KINGCLUB 接口，不直连数据库，不调用物业经营接口。源码并行工作区不代表需要合并后端分支或改变部署结构。

## 设备与参考

已连接设备为 SUNMI D2_2nd-SQB，Android 11 / API 30，1366×768，32 位 ARM（armeabi-v7a）。构建方案必须覆盖该 ABI，不能只产出 arm64 包。打印机、扫码器和客显能力尚未验证。

用户提供的收钱吧截图仅用于流程参考，不作为商品、价格、会员、订单或营业数据来源。不得覆盖、卸载或读取其私有业务数据库。

## 评审入口

- [横屏工作台 V1 与授权范围](docs/WORKBENCH_V1.md)
- [历史接入核查与第一阶段方案](docs/INTEGRATION_REVIEW.md)
- [员工会话](docs/STAFF_SESSION.md)、[桌台快照](docs/LIVE_TABLES.md)、[消费明细](docs/LIVE_ORDERS.md)
- [收银实时连接](docs/CASHIER_REALTIME.md)、[源码检查点](docs/SOURCE_CHECKPOINT.md)

## 本地运行与验证

使用 Flutter 3.47.1 / Dart 3.13.1，与会员 APP 的新机器工具链一致。

协议互验测试还需要 PATH 中的 Node.js（独立 crypto 对端，不访问网络或真实渠道）。

```powershell
& ..\tools\flutter-3.47.1\bin\flutter.bat pub get --enforce-lockfile
& ..\tools\flutter-3.47.1\bin\flutter.bat analyze
& ..\tools\flutter-3.47.1\bin\flutter.bat test
.\scripts\build-cashier.ps1 -FlutterSdk <Flutter目录> -ServiceUrl <私有发布配置中的HTTPS服务地址>
```

构建脚本产出 32 位 ARM Release 包（`app-armeabi-v7a-release.apk`），只构建不安装。包名暂保留 `cn.kingclub.cashregister.preview` 以保留原应用数据，不代表有预览模式。安装前核对目标设备和原应用签名，使用同签名保留数据升级。

应用始终进入独立员工登录/已授权工作台，已移除 CASHIER_PREVIEW 分流。服务地址由发布配置提供，用户无需填写。保留的 build-preview 脚本名称仅转调同一产品构建。

需要实时通知的构建额外指定相应开关（不自动开启服务端能力）：

```powershell
flutter build apk --release --target-platform android-arm --split-per-abi --dart-define=CASHIER_REALTIME=true --dart-define=CASHIER_SERVICE_URL=<私有发布配置> --no-pub
```

支付、开台、清台及打印的代码、线上启用和实机验收状态分别见功能总表。Release 仅指优化构建，不代表所有经营功能已上线；目前仍使用原开发签名保留数据升级，正式发行签名尚待安排。
