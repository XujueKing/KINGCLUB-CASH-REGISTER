# 2026-09-30 收银端集中本地验证

## 范围和隔离

运行全部 `test/*_test.dart`，显式排除 `live_backend_interop_test.dart` 和
`table_clear_backend_interop_test.dart`。协议测试仅启动本地 Node 加密对端；
未连接真实后端、数据库或支付渠道，未安装设备、打印、付款或核销。

## 实际结果

- 第一轮：706 通过、5 跳过、66 失败。不能作为生产验收通过证据。
- 修正第一组夹具后：733 通过、5 跳过、39 失败（包含框架级错误计数）。
  该轮 JSON 在本地生成目录 `build/cashier-local-tests.json`，不是提交产物。
- 后续修正退款响应夹具的动态 Map 键类型，单独运行
  `balance_refund_result_test.dart`、`balance_refund_controller_test.dart`：17 通过。
- 修正整桌结账测试的安装 ID 与原请求不一致后，单独运行
  `table_checkout_controller_test.dart`、`table_checkout_collection_test.dart`、
  `table_checkout_cancel_controller_test.dart`：21 通过。

## 已修正的测试问题

- 有效员工会话夹具缺少必需 `workbench.read`；未放宽生产权限验证。
- 结账测试新建随机安装 ID，和固定原请求设备范围不一致；使用测试安装 ID。
- 退款存储替身禁止删除所有键，误阻止登录清理会话；仍禁止删除待退款日志键。
- 可空 JSON 字段使用了推断为不可空的 Map；明确测试 JSON 类型。
- 退款明细动态展开导致 Map 键类型错误；明确 `Map<String, dynamic>`。
- 充值金额断言误匹配同数值百分比；改为带币种金额匹配，待下一轮验证。

## 后续完整重跑

本轮最终本地完整运行：**772 通过、5 跳过、0 失败**，退出码 0。
`dart analyze lib test`：No issues found。

追加修正均为测试层，未放宽生产校验：

- 使用 `flutter/lifecycle` 平台通道，让框架生成合法中间状态；离开前台时
  在 inactive 阶段渲染一次，再进入停止绘制的 paused 阶段。继续断言画面
  不含原敏感内容、迟到结果丢弃、恢复前台不擅自重试业务操作。
- 小票列表滚动明确选中 ListView 的 Scrollable，避免选到 SelectableText
  内部的另一个滚动控件；四语言展开断言保留。
- 整桌结账查询替身动态展开原响应时明确字符串键类型，恢复生产 JSON 形状。

默认跳过的 5 项为：3 项可选截图/真实字体渲染，以及 2 项受编译开关保护的
整桌结账实时更新路由测试。后者已另用
`flutter test --no-pub --dart-define=CASHIER_TABLE_CHECKOUT=true test/table_checkout_realtime_route_test.dart`
运行，**2 项通过**。仅本地测试进程启用开关，不改变生产功能默认关闭状态。
测试证明门店 revision 更新保留原结账对话框、身份失效关闭对话框、不自动收款；
不代表真实 WebSocket 服务或渠道已联调。

## 未完成验证

### 核销查询与报表到期修复后的完整重跑

查询/报表五份专项测试 42 项通过。随后按本文相同本地范围重新运行，
**792 通过、5 可选跳过、0 失败**，退出码 0；JSON 输出仍为
`build/cashier-local-tests.json`。`dart analyze lib test` 无问题。
两份后端互操作测试仍排除，跳过范围不变；新增自然到期用例先复现再修复。
此结果不替代历史 APK 的重新构建、真机或真实业务验收。

### 后续核销查询专项

`voucher_lookup_panel_test.dart` 与 `voucher_lookup_test.dart` 集中运行 13 项通过：
7 项解析、6 项组件。新增组件验证员工退出、替换认证控制器、退后台、离页的
迟到响应隔离，及输入校验、显式提交、混合核销结果、错误脱敏和不自动重试。
这是上述完整运行之后的专项结果，不将新增数量直接计作重新执行的全量结果。
测试使用本地受控替身，不触发真实券核销或数据库写入。

随后新增 `voucher_lookup_controller_test.dart` 10 项，三份核销查询测试集中
执行共 23 项通过。覆盖真实控制器到 SessionChannel 的接口编号、参数、
渠道权限、请求前/响应前到期、退出及错归属响应；SessionChannel 仍是测试
替身，不连接真实服务。该控制器及新增测试静态分析通过。

查询页面自然到期：两项新增用例先复现已有结果及在途结果在独立页面缺少
到期清理的问题，增加会话期限计时失效和返回时有效期检查后，三份查询测试
共 25 项通过。页面及测试静态分析通过；无交易、部署或设备操作。

两项后端互操作测试仍显式排除；三个可选截图/字体渲染测试未执行。

后端集中测试、隔离数据库验证、真机性能及打印、真实渠道业务验收仍未由本轮证明。
