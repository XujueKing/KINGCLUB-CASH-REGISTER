# 收银沉浸式全屏

用户要求隐藏底部安卓导航栏，已开启持续目标：全屏 → 会员身份识别 → 真实点单 → APP/收银同步闭环；目标仍在进行中。

应用启动调用 immersiveSticky；Android 11 使用 WindowInsetsController 隐藏系统栏，旧系统使用兼容标志。恢复前台和获得焦点时重设；键盘关闭后的尺寸变化延迟 1.3 秒恢复，键盘仍显示或应用在后台则不执行。遵循系统边缘手势临时呼出导航行为，不修改设备全局策略、不锁定系统、不影响收钱吧。

应用展示名改为 KINGCLUB 收银，包名和签名保持以支持保留数据升级。

验证：工作台 4 项测试通过，Flutter analyze 无问题，ARM32 release 构建通过；核对原签名后 install -r 成功。SUNMI 实拍 1366×768 全画面无底部导航条，已登录桌台正常、实时连接绿色。测试空输入框唤起键盘/关闭、退出到桌面再返回；不输入凭证、不提交查询或交易。证据保存在忽略目录 build/kingclub-fullscreen*.png。其他 Android 厂商和版本尚未真机验收。

实现依据：[Android 官方沉浸式系统栏说明](https://developer.android.com/develop/ui/views/layout/immersive)。
