# 收银端自动更新

用户要求收银机自动检测版本、升级 APK。本批增加原生 Android 更新桥、四语言触屏更新窗口、版本发布工具与静态分发配置。

## 使用方式

- 启动检查；运行期间每小时检查；失败后间隔 15 分钟重试。回前台只检查到期任务，同一时间只有一个下载；手动连点也有 15 秒间隔。
- 发现新版自动下载到应用专用缓存，已验证的同一文件可复用。登录页、设置页均有“软件更新”；新版就绪时工作台顶部出现入口。
- 下载不弹窗、不切换业务页、不重启。操作员打开更新窗口，确认已处理点单、收款及未保存内容，再点“安装新版”。Android 未授权安装来源时进入系统授权，返回后重新点击安装。取消系统安装可以再试。
- 当前使用普通 Android 应用的系统安装器，需要人工确认，未实现或宣称无人值守静默安装，也不申请设备管理员/root 权限。旧版没有更新代码，第一次必须以原签名覆盖安装此版；不能卸载旧应用。
- 安装只替换同包名程序，不执行清数据、注销、数据库清理或卸载。具体设备的安装、取消、首次来源授权及数据保留仍需实机验收。

## 内存、文件与校验

- APK 32KB 缓冲区流式写盘；清单最多 16KB、APK 最多 100MB，连接 15 秒、单次读取 20 秒超时、下载整体 10 分钟上限。工作线程串行，退出引擎关闭连接/线程。
- 只允许 HTTPS、清单同源同目录的 APK，不跟随重定向，不传业务登录凭证。保留一个已验证 APK；失败清理半包，升级后检查时清理旧包。
- 下载前校验体积/版本，下载后与安装前均校验 SHA-256、包名、最终 Android versionCode、最低系统版本、已安装应用的当前签名证书。不同签名、降级、哈希不一致或包名不一致拒绝安装。
- 不通过超级接口或数据库取 APK；发布清单和 APK 为独立静态资源，由 Nginx 直接提供，避免业务连接占用和 APK 进入 Node/Flutter JSON 堆。没有新增业务表或存储过程。

## 构建与发布

1. 递增 `pubspec.yaml` 的 version/build。运行 `scripts/build-cashier.ps1`，由私有环境提供 `ServiceUrl`；脚本自动注入同源 `/kingclub-updates/cashier/stable.json`。禁止提交真实环境配置。
2. 输出仍需使用 `.local/signing/cashier-debug.keystore` 原签名重签，口令从私有环境取得。不得发布 Flutter 默认调试证书的包。原证书 SHA-256：`7f839333dcc272a167a129317160c2a82b25b5ba8479529eac802be97c9c93ea`。
3. `python scripts/prepare-cashier-release.py --apk <signed.apk> --output <private-release-dir> --base-url <https-origin/kingclub-updates/cashier> --apksigner <apksigner> --aapt <aapt> --notes <release-notes> [--previous <previous-stable.json>]`。读取最终 APK 的实际 versionCode（包括 Flutter ABI 偏移），验证证书、包名及 ARM32 ABI；生成不可变哈希文件名与 `stable.json`。
4. 在业务域名同一个 HTTPS 虚拟主机配置 `deploy/cashier-updates.nginx.conf`。只添加本产品路径，先备份、`nginx -t` 成功再 reload，不重启业务容器/数据库。
5. `python scripts/publish-cashier-release.py --directory <prepared-dir> --ssh-host <operator-ssh-alias>`。发布锁防止并发覆盖，先传 APK 并核对远端 SHA-256，检查版本递增，原子替换清单，再更新 `latest.apk` 首装下载链接。保留前一份清单与旧 APK；禁止自动清理签名文件。
6. 从公网读取清单，流式下载并核对发布的 APK 大小、SHA-256及响应；首次设备升级前核对设备包名/签名，使用 `adb -s <verified-device> install -r -t <signed.apk>`。无设备时不能报告已经安装。

撤回尚未安装的版本可恢复上一份清单；已升级的设备禁止降级，修复必须发布更高 versionCode。

## 验证

Flutter 测试覆盖下载不触发安装、并发去重、失败隔离、明确确认后安装、四语言和各状态布局；原生纯逻辑测试覆盖来源/路径限制、大小/哈希格式、证书/包名/版本和降级拒绝。真实 APK 编译与原签名校验、公网下载校验单独执行。Android 系统安装器交互不能用这些单元测试冒充实机验收。

参考：Android [安装来源授权](https://developer.android.com/reference/android/content/pm/PackageManager#canRequestPackageInstalls())、[安装与用户确认](https://developer.android.com/reference/android/content/pm/PackageInstaller)。

## 本次交付记录

- 首装版本 `0.1.2`，最终 ARM32 versionCode `1003`（上一包 `1002`）。原签名包保存在 `.local/releases/auto-update-20261014/kingclub-cashier-arm32.apk`。
- Flutter 更新/登录/工作台回归 12 项通过；Android `UpdatePolicyTest` 4 项通过；新 Dart 文件静态检查无问题。全仓分析有既存风格提示，未借本任务全仓重排。
- 发布工具实测拒绝默认调试证书包与未递增版本。Android release 构建成功，并与上一份原签名 APK 证书核对一致。
- 下载路由只增加收银更新子路径，Nginx 配置检查通过、reload 完成，业务健康检查通过；无需业务容器重启或数据库迁移。
- 当前 ADB 无设备，尚未安装到收银机；首次覆盖安装、Android 来源授权与系统确认、实际升级后的登录/点单/打印数据保留待实机验收。

## 首次发布后的复查

发现安装器启动后 Dart 方法已返回，原定时器仍可能在应用退后台时检查新清单，进而替换安装器正在读取的固定缓存文件。本轮 `0.1.3` / `1004` 增加两层保护：进入系统安装/来源授权窗口前锁住更新检查，直到应用退后台并回到前台才解锁；应用在后台不发起新检查，原生安装前也检查 Activity 是否在前台。下载已在进行时可继续完成，但只有用户主动安装且校验结束后才打开系统窗口。

新增四项自动化验证：失败等待 15 分钟与成功等待 1 小时、安装窗口期间禁止检查并支持返回后重试、安装启动失败释放状态、后台检查延后。连同更新、登录、工作台回归合计 16 项通过。

服务器固定发布目录为 `/var/www/kingclub-updates/cashier/`：`stable.json` 是版本号、文件大小、SHA-256 和下载地址清单，`cashier-<versionCode>-<hash>.apk` 为不可变版本包，`latest.apk` 指向当前首装包，`stable.previous.json` 保留上次清单。旧包保留用于追溯，不自动清理。

后续由具备项目和服务器发布权限的维护者（包括 Codex）运行构建、签名、prepare 和 publish 脚本。设备检查更新由程序自己执行，不依赖 Codex 在线，不需要店员在收银机填写版本号或下载地址。发布文件不等于设备已完成安装。
