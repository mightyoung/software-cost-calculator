# 原生文件端口基础验证

2026-09-17。本报告覆盖 [native_file_ports.dart](../../apps/supplier_app/lib/platform/native_file_ports.dart) 的原生范围读取、应用私有任务目录输出和单 owner isolate 应用写锁。独立只读复核已确认本轮两项修复：现有锁文件先解析最终符号链接再进入同一队列，期间不额外打开/关闭描述符；发布在首次异步等待前设置 `_publishing`，拒绝同时 abort 或重复 publish。

## 证据与结果

集成负责人新鲜运行的 [测试日志](../../artifacts/development/native-file-ports-verified.log) 记录 **8 tests passed**，本次复核已读取该日志及对应 [测试源码](../../apps/supplier_app/test/native_file_ports_test.dart)，未重复执行。宿主为 macOS；工具链固定版本见 [toolchain.json](../../apps/supplier_app/toolchain.json)：Flutter 3.47.4 / Dart 3.13.3。

复现入口：在 `apps/supplier_app` 下使用固定工具链运行 `flutter test test/native_file_ports_test.dart`；本机 Flutter 测试环境及 localhost 代理绕过条件见 [平台报告](platform-capabilities.md)。

| 测试 | 已验证内容 |
|---|---|
| 范围读取 | 精确字节与偏移、每块不超过64 KiB、越界拒绝、尾部空区间、读取中真实截断报错 |
| 关闭后发布 | 写入完成前不允许发布；发布后目标字节正确、临时文件消失；不能再次发布或 abort 已发布文件 |
| 源流失败 | 部分临时输出删除，原始错误保留，不能发布失败输出 |
| 已有路径 | 独占创建冲突不修改既有临时文件；目标已存在时拒绝发布且保留目标 |
| 两个锁实例 | 同路径按本地队列串行；动作抛错后等待者及后续调用可继续 |
| 递归获取 | 同锁递归请求抛错，不等待自身；随后锁仍可使用 |
| 符号链接别名 | 已存在锁文件与最终符号链接共用队列和递归检查；此用例在本次 macOS 运行中通过，Windows 测试定义会因符号链接权限条件跳过 |
| 发布竞争 | publish 发起后，同步拒绝并发 abort 和第二个 publish，首次发布正常完成 |

源码与日志摘要用于绑定本轮证据：

```text
native_file_ports.dart
3427ecd9321e5e7411f69fa048bd443c6a272f00f68985119842ecce77d97bf6
native_file_ports_test.dart
bfee462c186c8ec49be0483e1bc175dc38e802813f21ab7eefd2f4c2c3044465
native-file-ports-verified.log
e0ae659b0d9a8c7dff8d5d529d89240c0daf587fe732b4072116c1cb8d6f5827
```

## 使用条件与证明边界

- `PrivateFileOutput` 仅在应用拥有、路径为该任务独占预留的同一私有目录内发布。先独占创建临时文件，写入、flush、close 后 rename；不能用作任意用户保存目标或竞争条件下的原子“不覆盖”适配。`File.rename` 会替换后来出现的目标，因此独占路径约定不能省略。[Dart rename 文档](https://api.dart.dev/dart-io/File/rename.html)
- `NativeInputSource` 每个范围重新打开文件，检测 EOF 截断但不证明不同范围来自同一不可变内容；同长度修改、文件替换及恢复任务的源身份仍由任务层摘要校验处理。
- 写请求必须路由到同一 owner isolate，本地静态队列与 OS advisory lock 配合；不能把该实现称为跨 isolate 串行化。锁路径应由应用统一分配，锁文件在使用期间不能替换，任意硬链接或首次创建时不同路径拼写的统一身份不在这8项证明内。
- POSIX advisory lock 是进程级，关闭本进程中该文件的任意描述符会释放相关锁；其他代码不能绕过 owner 打开后关闭锁文件。最终符号链接解析修复避免为规范化路径另开关描述符。[Dart lock 文档](https://api.dart.dev/dart-io/RandomAccessFile/lock.html)
- 源码使用 finally 关闭读取句柄，并将主错误与清理错误分别保留；本轮没有注入 close/delete/flush 失败，没有做进程崩溃或跨进程锁验证，不能据此宣称这些失败路径已实测通过。

这是正式端口基础的宿主测试，不是外部用户文件授权/保存、Android 文件提供器、Windows 原生行为、整包大数据内存或设备验收。Windows/Android 实际设备测试按用户决定 **DEFERRED**，不记 PASS，也不阻止后续开发；原生运行期是否允许写入仍依实际持久库、应用锁和活动库指针初始化结果决定。外部目的地发布与完整文件任务闭环由后续平台/服务适配完成。

上述 Dart API 页面当前标记3.13.4，项目固定3.13.3；引用用于说明文件和锁的 API 边界，本轮运行证据以固定工具链测试日志为准。
