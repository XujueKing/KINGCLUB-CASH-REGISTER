# 员工认证握手客户端

状态：本地协议代码与独立加密互验；尚未接登录页/安全保存/生产接口，不是员工登录交付。

现有 cryptography2.9.0 的纯Dart Ecdh实现抛 UnsupportedError；新增 [PointyCastle4.0.0](https://pub.dev/packages/pointycastle) 的 P256 key generation/ECDH，并继续复用原 cryptography HKDF/HMAC/AES-GCM。没有修改后台加密协议或建立明文登录API。

每次认证生成Random.secure播种的临时P256密钥，公钥为65字节非压缩格式。密钥生成与ECDH运算由 Isolate.run 执行，不在Flutter界面线程同步计算。收到服务端公钥先验证长度、非压缩前缀、坐标范围和曲线方程，拒绝无穷/无效点；临时私钥完成后丢弃引用，不落盘，不声称Dart托管内存保证清零。

先经HTTPS `/supper-handshake` 协商，验证P256/AES256GCM/HKDFSHA256/HMACSHA256套件及有效期；再以握手密钥密封 `/supper-interface`。保留代理前缀，签名canonical固定原协议路径和空session字段，不附会员API key。仅允许1901员工登录、1903刷新；返回必须为可认证解密的result对象。

同一客户端仅允许一个认证操作；关闭后丢弃迟到结果。任何超时或提交后失败不自动重试，避免旧refresh token重用撤销；当前只返回内存对象，后续需对会话数据做严格模型验证并安全持久化。客户端服务器地址仍由明确配置提供，不在Git硬编码生产地址。

测试使用独立Node标准crypto进程验证随机P256共享秘密、握手签名及密文往返、非法点、算法降级、响应篡改、认证并发、关闭迟到响应及接口白名单。TEST-ONLY数据只在test/support，既非生产数据也未创建真实账号。Android ARM32真机握手耗时、安全存储、完整员工登录及真实服务尚未验收。

本轮验证：7项握手专项通过，全部26项测试通过、1项可选截图测试跳过；flutter analyze无问题。未构建或覆盖安装新APK，未连接生产登录，未提交/推送收银仓库的初始工作树；该工作树包含此前已暂存的初始工程，需单独审阅发布范围，不能将本地协议变更报告为已推送。
