# 打印接入：设备事实与只读检查

## USB 选择与系统授权接入（2026-09-29）

新增每设备/接口/输出端点独立选择入口及四语言二次确认。原生usb-printer-permission通道仅request/cancel；严格校验10字段请求、一次随机请求ID、当前deviceId/VID/PID/设备类/接口ID/备用设置/协议/端点/包长，不把历史hasPermission缓存当授权。仅前台可发起、单个请求互斥；当前设备或端点变化失败关闭。没有openDevice、claimInterface、控制/批量传输、初始化、打印或钱箱调用。

系统请求使用随机action、指定本应用package的不可变一次PendingIntent；API33+接收器不导出。接收回调后不依赖可填充extras，重新查当前设备和UsbManager.hasPermission；等待中目标拔出即结束。原生60秒期限，Dart65秒兜底及仅按自身请求ID取消；关闭/销毁清理接收器、计时器和PendingIntent。取消等待不是撤销系统授权，也不能保证关闭已显示的系统对话框。[UsbManager官方说明](https://developer.android.com/reference/android/hardware/usb/UsbManager#requestPermission(android.hardware.usb.UsbDevice,%20android.app.PendingIntent))和[不可变PendingIntent说明](https://developer.android.com/reference/android/app/PendingIntent#FLAG_IMMUTABLE)是实现依据。

页面授权请求结束后清空旧设备观察并要求手动重新检查，不把授权回调显示成可打印；系统弹窗导致前后台切换也不回填旧快照。确认前进入后台使旧选择失效。临时deviceId及描述匹配不是跨拔插的永久物理身份，没有持久默认设备或自动接管所有USB设备。

新增7项客户端/选择契约及8项四语言UI测试：选错接口/输入端点、未确认、重复提交、系统拒绝、响应错配/脱敏、取消/超时/迟到、过期确认、系统弹窗生命周期和重新检查。全量425项通过/4可选跳过，analyze无问题，ARM32 release构建通过；原生广播/拔插/超时全路径自动化仍待补齐。

目标DAB6264H90115保留数据安装独立开发签名包，旧APK源/备份SHA256一致 `D48FEFDB83A549600ADEF43A928193C99D9A6D30683E03E19AE6C77576283EE2`，私有路径 `D:\DeviceBackups\KINGCLUB-CASH-REGISTER\20260929-usb-permission-upgrade\previous-preview.apk`；不是数据/Keystore备份。新APK及设备安装文件SHA256一致 `1D06938459B660467609BD4D287B51413EF89ABDCD33B0CE891356D6BF335D40`，冷启动897ms/等待911ms。

真机操作范围：从实际UI位置选择0483:5743、接口0/0、OUT1，并点击本应用“申请USB授权”确认；计划验证系统取消路径，但**未观察到系统确认弹窗，授权请求已结束**，没有ADB点击系统允许或取消。随后21:42:29手动重新检查，实际hasPermission由false变为true，截图/UI树均核对。不能据此推定系统内部自动授权策略，也不能声称系统拒绝路径已实测。授权状态发生了真实变化，未撤销；从未打开/占用USB或发送数据。PID5696限定300条日志崩溃/ANR/E-flutter匹配0仅短窗口，随后关闭检查页。

已询问用户是否允许一张明确非交易测试小票（无真实订单/会员资料、不开钱箱、先不切纸），答案尚待返回。授权成功不等于出纸成功；输出/任务不确定恢复、80mm四语言实际排版与拒绝/拔插真机回归仍未完成。

## 芯烨 XP-80U 与 USB 描述真机验证（2026-09-29）

用户现场照片铭牌确认：Xprinter芯烨 XP-80U、80mm纸宽、USB+网口、支持ESC/POS，照片中USB线已接。型号/纸宽/协议来自铭牌，不是从商米paperCode推断；铭牌不证明实际出纸成功。照片/序列号不入仓库。只读dumpsys USB显示当前打印候选VID:PID为0483:5743，厂家通用字段printer、产品USB Printer Port，接口class/subclass/protocol=7/1/2；这些描述本身不含型号，不把VID/PID永久硬编码为芯烨。

发现通道由5字段增为严格6字段，新增usbPrinters：临时deviceId、VID/PID、设备类、本应用hasPermission、接口/备用设置/协议及端点地址/类型/最大包长。只读取Android元数据；不读串号/USB路径、不申请权限、不openDevice/claimInterface/传输。候选数、重复临时ID/接口/端点、范围和数量边界均校验；失败不解释为没有设备。deviceId仅本次连接使用，不作跨拔插持久身份。Manifest声明可选USB host能力，没有自动USB附着接管或新的权限申请。

依据[Android USB Host](https://developer.android.com/develop/connectivity/usb/host)区分发现、授权、通信；依据[USB-IF打印类规范5.3–5.4](https://www.usb.org/sites/default/files/usbprint11a021811.pdf)仅将class7/subclass1、protocol1或2且有Bulk OUT的接口列为直连输出候选，不将1284.4协议3当成相同裸输出协议。USB端点存在仍不证明ESC/POS型号能力、纸宽或打印完成。

四语言界面展示每个候选及授权/接口，原状态按钮改名“商米内置状态”，明确不代表外接芯烨。5项模型及4项四语言UI新增测试，全量410项通过/4可选跳过、analyze无问题、ARM32 release构建通过。测试描述符为明确TEST夹具，不冒充真机。

备份旧APK并核对源/副本SHA256 `A9741BE7BD37DB014C56020531A0362D71E5C532D51B3AA47302F16E3EAFBC2B`，私有路径 `D:\DeviceBackups\KINGCLUB-CASH-REGISTER\20260929-usb-descriptor-upgrade\previous-preview.apk`，不含应用数据/Keystore。保留数据升级DAB6264H90115，仍独立0.1.1+2开发签名；新APK和安装后文件SHA256一致 `D48FEFDB83A549600ADEF43A928193C99D9A6D30683E03E19AE6C77576283EE2`，冷启动936ms/等待977ms。

21:29:46应用内实际观察：USB候选1、0483:5743、接口0/备用0、7/1/2、批量输出候选存在、**本应用USB授权=false**。真实截图/UI树已核对并留私有目录，随后关闭检查。PID5493限定300条日志的崩溃/ANR/E-flutter匹配0，仅短窗口。没有请求权限、占用USB、试打、切刀、钱箱或业务操作。

下一步：实现显式选择当前设备、系统授权结果与拔插/身份失效处理；确认实际连接并获试打授权后验证80mm/四语言ESC/POS输出与不确定任务恢复。不能将发现端点或铭牌确认标为打印完成。前一轮拟做的原生生命周期抽取补丁未应用，现有原生超时/断连竞争自动化缺口仍保留。

## 状态 UI 与实际 Binder 查询（2026-09-29）

检查弹窗新增四语言“读取硬件状态”按钮。打开弹窗只发现服务；用户明确点击且当前服务可解析才短暂绑定查询。后台清空发现/状态，恢复前台须重新发现，不自动重连。等待期间禁重复读取/刷新，关闭可用；错误、超时、后台/关闭后的迟到结果不成为当前观察。状态按[官方文档第8–9页](https://cdn.sunmi.com/public/generalfile/mgt-document/841c6680d673447ba9c5d9b1e1131d01.pdf)明确码表翻译；未知值保持未知，纸张原始码不映射为毫米。这份表说明纸张规格可配置，但没有完整编码映射，不从默认值推断现场纸卷。

新增9项UI/平台替身测试及1项状态映射测试，包含四语言1024×600可见/可点布局、无自动绑定、不可解析禁用、失败后不保留旧正常状态、null、后台迟到、超时和关闭。全量401项通过/4可选跳过、analyze无问题、ARM32 release构建通过；这些测试没有替代原生生命周期竞争的自动化测试。

指定DAB6264H90115保留数据升级，仍独立包0.1.1+2/开发签名。旧APK备份在本机私有 `D:\DeviceBackups\KINGCLUB-CASH-REGISTER\20260929-printer-status-upgrade\previous-preview.apk`，源/副本SHA256一致 `ACFCF4930AE9A8228403254E7CE6022047FAA2AFE49C45F7FF74F5A8CD2FCE1A`；不含应用数据/Keystore/固件。新APK及安装后设备文件SHA256一致 `A9741BE7BD37DB014C56020531A0362D71E5C532D51B3AA47302F16E3EAFBC2B`，冷启动904ms/等待946ms。

21:17:40应用内发现服务6.9.7、已启用/可解析、USB打印类候选1；21:18:09点击只读状态返回 **statusCode=505（内置服务未检测到打印机）、paperCode=1**。现场截图及UI树已核对，随后关闭弹窗。不能用paperCode=1推翻505，不能声称内置打印头正常；也不能用505断言USB候选不存在。下一步应核对外接打印机型号/驱动协议，而不是反复初始化内置服务。截图/XML只存私有备份目录。

PID5195限定300条日志的崩溃/ANR/E-flutter模式匹配0，仅短窗口证据。没有初始化、自检、打印、走纸、切纸、开钱箱、真实员工登录、支付/核销或改变收钱吧。原生断连/卡死/销毁竞争自动化、USB候选型号与协议、纸宽、实际小票和正式签名仍未验收。下文“未接UI/真机调用”为上一阶段记录。

## 官方 SDK 只读状态通道增量（尚未接 UI / 真机调用）

固定依赖 `com.sunmi:printerlibrary:1.0.24`，从 Maven Central 获取 AAR；下载样本与本次 Gradle 实际缓存 SHA256 均为 `6FE3BACBBDD8616E78F23A04E5A8265BB26EB5C7B75A64BE6B3356C8782D92A8`。这只是本次产物核对，尚不是构建时依赖校验锁。AAR manifest 没有新增权限或组件。用 JDK javap 检查 Manager、Callback、Proxy 构造及两个查询方法：连接仅 bindService，回调创建代理，代理根据硬件属性选 SDK 自带协议表；没有自动初始化/自检/打印。SDK hasPrinter 的异常路径使用序列号推断，故本应用不调用它。

依据：[官方示例](https://github.com/shangmisunmi/SunmiPrinterDemo)、[官方示例查询实现](https://raw.githubusercontent.com/shangmisunmi/SunmiPrinterDemo/master/app/src/main/java/com/sunmi/printerhelper/utils/SunmiPrintHelper.java)、[Maven 发布项](https://central.sonatype.com/artifact/com.sunmi/printerlibrary/1.0.24)。示例的纸宽三元表达式将所有非1值解释为80mm，不能直接搬到未知版本的生产判断。本次保留原始 paperCode，不转换为毫米；后续按官方规范明确允许值并将其他值显示未知。

新增独立无参数 `printer-status/inspect` 通道，只有明确调用才短暂绑定；后台线程依次查询 updatePrinterState/getPrinterPaper，分别失败则该字段为null。绝不调用打印机初始化、缓冲区、打印、自检、切纸、钱箱或固件修改方法，不读取设备串号。查询完成、断连、空绑定、超时、引擎销毁时解除本应用绑定。2.5秒原生期限；若Binder查询卡住，超时后仍阻止新任务排队，直至旧调用实际返回，并丢弃迟到结果。Dart层4秒期限、严格2字段与32位整数解析、错误脱敏；没有ready/printed属性。

验证：6项新增Dart/通道替身测试（未知码、null、坏数据、只读调用、错误与超时迟到）；完整391项通过/4可选跳过，analyze无问题，ARM32 release构建通过（preview=false/realtime=true，仍开发签名）。实际只读getprop核对目标硬件属性为D2_2nd。SDK内部会为该型号走默认桌面协议分支，不能以编译成功代替设备兼容验收。

边界：当前原检查弹窗仍只调用发现通道，本增量尚未绑定到UI、安装新包或实测Binder；原生绑定/断连/超时竞争没有自动化运行测试。没有试打或操作真实交易。下一轮须补生命周期测试、四语言状态UI与真机只读调用，然后才能评估实际纸张规格；不能把当前构建说成已能正常打印。

## 四语言检查入口与真机通道验证

登录/工作台顶栏新增“打印设备检查”，无需员工身份、不读取经营资料。弹窗仅调用无参数inspect，显示发现证据与明确“打印头/纸张/纸宽未验证”提示。错误不解释为无打印机；超时、关闭弹窗、后台后迟到响应不回填，返回前台须手动重查。简中/繁中/英文/泰语均使用可滚动内容，关闭按钮始终可用。

10项UI/平台通道替身测试覆盖未登录入口、无业务认证调用、错误脱敏、手动重试、前后台、关闭/超时后的迟到响应及四语言紧凑布局。完整385项通过/4可选跳过，analyze无问题，ARM32 release构建通过（preview=false/realtime=true）。这些测试不代表设备打印；以下另列实际通道证据。

指定DAB6264H90115保留数据安装成功，独立包仍0.1.1+2/开发签名；未覆盖收钱吧、清数据或操作其他设备。先备份旧APK并核对源/副本哈希B8343AE3F9A92AABE933BCCBE8241D2257B2383CDEB69A91CAF3359E552CF3B2，保存在本机私有 `D:\DeviceBackups\KINGCLUB-CASH-REGISTER\20260929-printer-discovery-upgrade\previous-preview.apk`；备份不包含应用数据或密钥。

新APK SHA256 `ACFCF4930AE9A8228403254E7CE6022047FAA2AFE49C45F7FF74F5A8CD2FCE1A` 与安装后设备文件一致；冷启动858ms/等待873ms。根据设备UI实际按钮bounds打开只读入口，2026-09-29 20:58:11返回：serviceInstalled=true、serviceEnabled=true、serviceResolvable=true、serviceVersion=6.9.7、usbPrinterCandidates=1。实际截图及UI层级均已核对，随后关闭弹窗回登录页；PID4973限定300条日志的崩溃/ANR/E-flutter模式匹配0，仅短窗口证据。

这是应用内原生通道真实结果，不是预览夹具。USB打印类候选仍不等于正式驱动/协议支持，也不证明纸宽或打印机就绪。没有绑定SUNMI服务、申请USB权限、初始化、打印、自检、走纸、切刀、开钱箱、登录真实员工或调用支付核销。现场截图保留私有目录result.png，不上传。下文“未接UI/安装调用”为上一阶段记录，本节更新发现层验收；实际出纸与业务小票仍未验收。

## 2026-09-29 实查

指定 D2_2nd-SQB 收银机安装 `woyou.aidlservice.jiuiv5`，版本6.9.7（250928001）。只读包元数据及运行服务显示 `woyou.aidlservice.jiuiv5.IWoyouService` 对应 `sunmi.inner.pkg.service.PrinterService`，另有扩展打印/入口服务。没有读取其他应用的私有配置、业务数据或打印内容，没有停止这些服务。

安装服务、运行Binder服务与“打印头存在/正常、有纸、纸宽正确”是不同证据。尚未核实内置或外接实物、58/80mm纸卷与可用打印机状态，已向用户询问。不以设备名称或Android系统PrintManager存在推断可打印。USB dumpsys筛选没有形成实际外设型号证据，不据此认定没有打印机。

## 官方依据

[SUNMI Printer Developer Documentation](https://cdn.sunmi.com/public/generalfile/mgt-document/841c6680d673447ba9c5d9b1e1131d01.pdf)，第7–9页描述服务连接、初始化及状态/纸宽方法：初始化可能继续未完成缓存任务，自检会输出纸张，均不是无副作用探测。只读状态与纸宽仍应经官方SDK按版本能力调用，未知或不支持不能默认为就绪/80mm。后续必须使用官方接口契约，不通过猜测Binder transaction编号探测，以免误触发打印或钱箱。

## 本轮实现

- 原生 `PrinterDiscoveryBridge` 仅暴露无参数 `inspect`。读取指定打印服务的包版本/启用/可解析信息，以及Android USB打印类候选数量；不绑定服务、不初始化、不自检、不发送ESC/POS、走纸、切刀或开钱箱。
- AndroidManifest只增加该包的可见性声明，没有增加USB授权、钱箱、系统管理等权限。未引入第三方打印SDK或修改系统。
- 查询离开UI线程执行；单次互斥，2.5秒返回超时后仍保持后台任务互斥直到实际结束，迟到结果不重复回调；引擎清理时解除通道。没有打印服务自动重连/任务重发。
- Dart严格解析5字段观察；未知插件、超时或错误不伪装“没有打印机”。不返回串号、USB路径、客户信息或日志原文；没有ready/printed属性。服务可解析不代表打印权限、绑定成功或出纸成功。

5项Dart专项测试覆盖只读调用、数据损坏、未知平台与错误脱敏；全量375项通过/4可选跳过，analyze无问题。原生Kotlin在ARM32 release构建通过（preview=false、realtime=true），尚未安装此构建或实际调用应用内检查。原有Android文件保留CRLF，diff检查使用cr-at-eol规则。测试通道为明确替身，不是设备Binder状态证明。

## 后续验收

1. 接入四语言设备检查入口，真机运行该只读通道，区分发现、绑定、状态未知和明确就绪。
2. 用户确认实际打印机与纸宽后，核对官方SDK/能力和模型，读取真实状态，仍不自动初始化或清缓冲。
3. 小票从服务端授权账单/付款凭证生成，草稿与未付款单必须明确标注；现金/微信/支付宝/余额凭证不能靠打印结果代替。
4. 显式测试出纸授权后验证排版、四语言/位图、纸宽、切纸等实际硬件能力。任务持久化、打印结果不确定及补打标识需专门处理，不能超时自动重复打印。
5. 真机长时间验证及实际经营票据、生产签名/部署/付款/核销仍未完成。
