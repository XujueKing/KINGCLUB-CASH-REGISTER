# Logo 与 Release 预览真机检查

## 本轮变更

- 版本 0.1.1+2，独立包名不变。
- 使用用户提供的原版黑底白字 King club PNG，同时替换工作台标识和 Android 桌面图标；原素材不重绘、不调色，来源见 assets/brand/README.md。
- 构建脚本默认 Release，保留 profile/debug 显式选项。CASHIER_PREVIEW=true 和付款禁用不变。
- 继续使用既有开发签名，便于独立预览包覆盖升级；非正式发行签名。
- 不同时重构页面或切换渲染后端，避免混淆首次 Release 对比；设备日志仍报告 Impeller / Vulkan。

## 验证结果

- flutter analyze：无问题。
- flutter test：11 通过，1 个可选截图测试跳过。含 Logo 资源加载、四语言及紧凑横屏测试。
- ARM32 Release APK 约 14.1 MB；SHA-256 为 0F3944B70A140C0A810ADE541833F3ED8FBB4C305FFAC46B66428B8D94F78A42。
- 新旧 APK 签名证书摘要一致；APK 元数据及安装后的包标志均无 DEBUGGABLE。
- 指定目标收银机覆盖安装 Success；版本核对为 0.1.1 / 2，未卸载或清数据。
- Activity 冷启动检查 Status: ok / TotalTime: 1421 ms。这是 Android Activity 启动指标，不是触摸延迟或 Flutter 完整首帧指标。
- 真机截图核对桌面图标、桌台页、订单页、会员占位页；安全点击订单→会员→桌台完成，最后停在桌台页。未触碰真实订单或付款。
- 本次捕获的 Release 进程日志中未发现 Skipped / FATAL / Exception / Davey 匹配；这只是有限采样，不能证明长期无掉帧。

## 性能结论边界

此前 Debug 启动日志出现跳过 208 / 475 帧。现在已移除 Debug 构建开销，但没有同条件帧时间基准，不能宣称已量化提速或完全解决点击卡顿。Android gfxinfo 只记录少量宿主帧，不能充当 Flutter SurfaceView 的完整帧率统计。需要用户复测连续切换、选桌和加菜；若仍卡顿，再在 Profile 模式收集 Flutter UI/raster 帧时间，区分页面重建与设备 GPU 路径。

截图保存在 gitignored artifacts/release-*.png。员工登录、真实经营接口、收款、打印等仍未接通，不因 Release 安装成功标为营业验收。
