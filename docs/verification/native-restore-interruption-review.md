# 原生恢复故障接缝与实际进程中断独立审查

日期：2026-09-18。**APPROVE，仅此次接缝、双向并发和子进程中断验证增量；不代表完整平台或产品交付。**

## Code Review Summary

**Files Reviewed:** 5  
**Total Issues:** 0 unresolved

### By Severity

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0

## 范围与计划符合性

审查 `apps/supplier_app/lib/platform/native_database_host.dart`、`native_restore.dart` 的新增接缝，`test/native_restore_concurrency_test.dart`、`test/support/native_restore_fault.dart` 和 `tool/native_restore_interrupt.dart`；读取既有 metadata 事务与 accepted 处理作为上下文，不扩大旧恢复状态机审查。

实施计划 `docs/superpowers/plans/2026-09-16-supplier-inquiry.md:166` 要求“测试数据库与故障注入不能进入产品公开API”。主集成者核对出旧草稿公开 restoreFault 构造参数/field 不符合此约束后，本审查暂停该草稿批准。最终版本已删除公开参数/field，产品侧仅保留私有 `_restoreBoundary`，测试 helper 位于 test/support，只有测试和 tool 导入。正式入口与无 Zone 注入的调用不会安装故障动作；没有产品代码导入测试支持。该计划符合性问题已关闭。

## 核对结果

五个命名边界分别位于恢复已持应用写锁、切换事务前、切换事务内、切换事务后、接受事务后。`inside_switch` 在 `_metadata.transaction` 回调内，UPDATE active 已执行，但回调停在 awaited checkpoint，尚未 UPDATE restore_activation 为 switched，也尚未返回并提交。metadata 采用 DELETE journal 和 synchronous FULL。该位置不是提交后的伪边界；此判断来自事务控制流核查，未声称独立读取过 kill 前另连接可见的指针。

`after_accept` 在 accepted/used 的 metadata 事务完成之后。现有异常处理读取 accepted 状态后不会设置 rollback_pending；重开恢复同样不自动回退 accepted。默认路径未改变事务内容、锁的持有区间、校验或状态转换，新增边界没有捕获/降级正常异常或另走宽松恢复路径。

子进程工具每轮创建独立临时目录，通过 Process.start 创建并保存自己的 Process；只对该对象发送 SIGKILL，没有任意 PID、进程名或进程组终止。子进程仅在指定 checkpoint 输出并 flush 标记后永久等待，父进程收到准确标记才终止并等待退出，再重开正式 host。正常验证路径先确认候选 instance、epoch、唯一 snapshot 内容与原设备身份，随后新增 after-recovery 并再次重开，确认仍在该 instance 且两条记录存在。工具 finally 的额外终止仍只针对自己创建的 Process。

双向并发测试使用真实应用锁和显式 barrier：restore-first 后，等待中的 staged commit 必须抛 `stale_active_database`，不能写入回执或修订；commit-first 后，恢复必须抛 `stale_preview`，保留原 instance/epoch、递增后的 generation、提交内容及一条成功回执，且未创建恢复备份。不是用任意异常替代具体陈旧状态断言。

## 验证来源与限制

**独立执行**最终五文件 `dart analyze`：No issues found。未重复运行完整 core、所有 Chrome 或另外启动中断进程。

**读取主集成者新鲜持久证据：**`artifacts/development/native-restore-admission-tests.log` 最终 **16 tests PASS**，包含新增空间准入 1、既有恢复 13 和双向并发 2；这是读取日志，不声称本通道独立执行全部原生测试。

`artifacts/development/native-restore-interrupt.log` 与 `.json` 对 before_switch、inside_switch、after_switch、after_accept 四边界均记录 **signal_exit -9 / PASS**、设备身份保留及接受后写入保留。已核对工具实际 Process.start/SIGKILL 路径和恢复断言，这些是本机真实进程终止证据，不是手工构造 journal fixture。

SIGKILL 不等同于断电/磁盘掉写；本证据仅来自当前本机平台，不升级为 Windows/Android 真机验证。后续故障点、完整恢复矩阵或 G003 需求验收不在本限定结论内。

### Recommendation

**APPROVE — 最终私有接缝与上述中断/并发增量，无未解决发现。**
