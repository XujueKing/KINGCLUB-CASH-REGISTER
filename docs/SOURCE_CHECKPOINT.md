# 2026-09-29 首次源码检查点

目标远端：`git@github.com:XujueKing/KINGCLUB-CASH-REGISTER.git`，仅 main。
提交前 Git 核查：本地 main 尚无提交；SSH ls-remote 成功且未返回远端引用，无现有历史需要覆盖。

本批内容分类：

- 源码：Flutter 页面、模型、加密通信、员工会话、实时连接和 Android 配置。
- 用户素材：KINGCLUB 原始 logo 与 Android 启动图标；不是会员或业务数据。
- 验证：本地测试及明确标注的 test-only 固定数据、构建脚本、依赖锁和交付/限制文档。
- 不提交：APK、build、.dart_tool、Gradle 缓存、local.properties、日志、设备备份、签名私钥、环境凭据。
- Gradle wrapper 的本地生成文件沿 Flutter 项目默认忽略；新机器需固定 Flutter SDK、Android SDK/JDK，
  先 pub get --enforce-lockfile，再用 Flutter 构建。没有验证不带这些工具的新环境能直接运行 Gradle。

检查覆盖可见源码、文档、测试、脚本及 Android 资源：URL 仅官方文档/XML 命名空间、
测试保留域名或 UI 占位；密钥模式检查未发现实际私钥/令牌，密码命中为测试占位。
此为本批候选范围检查，不等于专业安全审计或生产认证。

当前验证：analyze 无问题；69 项测试通过、1 项可选截图测试跳过；ARM32 release APK
构建成功（15.3MB），SHA256：
`5A5CA6965E5D097FA70B4A8BF33521DE1708F48F2CAEA588EADE4965703885C4`。
该包为员工入口及实时编译开关开启、开发签名，未安装真机；不是经营验收包。

后端对应代码基线 48c645af，接口迁移 173–177 尚未由本任务执行。
源码推送不等于后端部署、创建员工、授权门店或执行付款/核销。
