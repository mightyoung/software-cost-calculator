# 本机文件流实验

2026-09-17，macOS arm64，Dart 3.13.3。仅隔离实验，未安装生产文件适配器。

`prototypes/storage_gate/lib/file_gate.dart` 和 `test/file_gate_test.dart` 验证：

- 8 MiB 文件以最多64 KiB块读取指定区间，精确核对84470字节；允许EOF空区间，拒绝负数和越界。
- 读取过程中真实截断源文件时明确失败，不把短读误报成功。
- 输出先独占创建临时文件，逐块等待写入，flush和close成功后才允许发布。
- 输入流中途失败，清理部分输出并拒绝发布。
- 来源失败且临时目录权限导致删除也失败时，同时保留原始异常/堆栈与清理异常；恢复目录权限后abort可重试，期间禁止发布。
- 目标已存在时拒绝覆盖；临时路径创建失败后abort不删除原有文件。

六项测试通过，原始证据 `prototypes/storage_gate/file-tests.txt`。复现：在该原型目录运行 `dart test test/file_gate_test.dart --reporter expanded`；依赖及工具链同 [SQLite宿主实验](storage-gate.md)。

边界：工作目录须由任务独占，外部进程不能替换临时文件/目标或原地修改输入；rename前存在性检查不提供对恶意并发写入的无覆盖保证。未证明任意用户选择目录、Windows/Android授权、真实close失败、断电目录持久性或取消正在写入的流。源流失败是显式注入，不是物理介质故障。此实验不放行T1总门。
