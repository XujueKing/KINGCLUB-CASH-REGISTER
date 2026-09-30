# KINGCLUB CASH REGISTER

配合 KINGCLUB APP 扫码点单和 CCSOP KINGCLUB 商务服务的门店前台安卓收银机项目。

最新工作安排：另一台机器接续后端、数据库及 APP 联调，本机后续负责收银端精修。请先读[给另一台 Codex 的交接说明](docs/CODEX_HANDOFF_BACKEND_INTEGRATION.md)，其中列明源码交付边界、接口契约、线上库差异和验收清单。下文为早期项目入口，最新实现/验证状态以交接说明及其引用记录为准。

当前状态：横屏预览与本地草稿、独立员工加密登录/续期/退出、门店桌台快照、消费明细和实时通知后重新查询均已实现代码及本地测试。尚未部署配套后端、配置真实员工授权或完成线上/真机营业验收；经营写接口仍在开发。

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
.\scripts\build-preview.ps1
```

构建脚本默认产出 32 位 ARM Release 优化预览包（`app-armeabi-v7a-release.apk`），独立包名 `cn.kingclub.cashregister.preview`，显示名称“KINGCLUB 收银预览”。可用 `-Mode profile` 进行性能分析，或 `-Mode debug` 调试；不要用 Debug 包评估最终流畅度。默认不安装；提供 `-Install -DeviceSerial <已核对的收银机序列号>` 才会验证目标型号并安装，不清数据、不覆盖收钱吧。

预览包使用 `CASHIER_PREVIEW=true` 启动样例界面；普通 `flutter run` 默认为独立员工登录入口，已保存会话须先向服务端续期验证。演示数据不会传到服务器，退出演示会清空内存草稿。预览服务设置仅检查 HTTPS `/ready`，与独立员工登录分开。

只读接入验证包（不等于正式发行，也不自动开启服务端能力）：

```powershell
& ..\tools\flutter-3.47.1\bin\flutter.bat build apk --release --target-platform android-arm --dart-define=CASHIER_PREVIEW=false --dart-define=CASHIER_REALTIME=true --no-pub
```

支付、开台、清台、打印及真实员工授权尚未接入。不能用此包实际营业；Release 仅指性能优化构建，不代表经营功能正式上线。本独立预览包仍使用原开发签名以便覆盖升级，不用于正式发行。
