# 恢复空间准入独立审查

日期：2026-09-18。**APPROVE，仅恢复空间估算和新操作准入增量；不重新批准整个恢复状态机。**

## Code Review Summary

**Files Reviewed:** 12  
**Total Issues:** 0 unresolved

### By Severity

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0

## 范围与依据

核心：`packages/supplier_core/lib/src/exchange/restore_space.dart`、`test/restore_space_test.dart`。平台：`apps/supplier_app/lib/platform/{native_database_host,web_database_host,native_restore,web_restore,web_capacity}.dart` 的容量注入及 prepare/activate/replay 相关增量，`web/supplier_platform.js` 的 capacityEstimate。验证：`test/restore_space_admission_test.dart`、`tool/capacity_test.cjs`、`tool/web_restore_smoke.dart`、`tool/web_restore_test.py`。

依据批准设计 §8：空间预测用于提前提示，真实配额/I/O/SQLITE_FULL 的事务正确性不能依赖预测准确。系数明确为 `restore-space-v1` 启发式，不是实际峰值上界、空间预留或物理磁盘余量保证。本轮不扩展既有恢复状态机、真实磁盘耗尽、设备验证或后续故障接缝。

## 核对结果

容量状态区分 estimated、unsupported、failed、invalid；只有 estimated 可以携带 availableBytes。Web 桥拒绝缺失、负数、非整数和不安全整数，合法 quota-usage 为负时归零；采样异常保留 failed 和诊断。原生默认明确 unknown，不伪造可用空间。unknown 对应 `fits == null`，不会当作 0 拒绝或当作已保证充足；仅 `fits == false` 抛出包含版本、阶段、依据和组件预算的 SPACE_REQUIRED。这个显式领域结果不吞掉实际恢复异常。

原始字节值先验证安全整数；所有乘法使用 BigInt，单组件转换回 int 前验证范围，总预算继续以 BigInt 累加。预算分别列出 staging、candidate_increment、transaction_journal、safety_backup_private、safety_backup_published、metadata_and_slack。activate 时 staging 与 candidate_increment 为 0，已分配候选只作为日志规模依据，不将其已有占用再次算作新分配；两份可能同时存在的备份分开计入。

prepare 在应用写锁内核对活动版本并采样，在创建候选记录和数据库前执行准入；不足时没有候选可激活。activate 在同一写锁内检查 ready/预期版本、复验候选后重新采样，在创建安全备份及持久化 armed journal 前拒绝不足；拒绝保留 ready 候选，允许稍后重试。采样是时点估算，既有文件包含在平台 usage 中，不承诺其他任务不会继续占用。

replay 的 `_recoverActivation`、`_finishActivation`、rollback 路径没有调用准入或 CapacityReader；已持久化的恢复工作不因新的容量估算被拦截。Web 的候选 allocated-byte 查询只加入新激活预检，未引入 replay 的容量依赖。新增查询没有改变先应用写锁、再活动版本/SQL 的顺序。

## 验证来源

- **独立执行：**核心两文件 analyze、平台相关七个 Dart 文件 analyze，均 No issues found；`dart test test/restore_space_test.dart --reporter expanded` **5/5 PASS**；`node --test tool/capacity_test.cjs` **2/2 PASS**；JS 语法检查通过。
- **读取实现者真实 Chrome 证据：**`artifacts/development/web-restore-smoke.json` 总状态 PASS，capacity 包含实际浏览器 estimated 采样，以及 prepare_rejected、activate_resampled、candidate_preserved、recovery_not_gated 全 true。已核对 smoke 断言：replay 注入会抛错的 sampler，采样次数仍为 0，恢复后的 instance 为候选且 journal 为 accepted。本审查未另开浏览器。
- **主集成者报告，非本通道独立执行/持久日志复核：**原生组合测试工具会话 70785 最终 exit 0、15 tests PASS（空间准入新增 1、既有恢复 13、并发 1）。`native-restore-tests.log` 仍是较早 13 项日志，不能用于声称已独立核验此次 15 项。本轮已读取新增原生准入测试，核对其拒绝前后文件集合、候选保留、激活重采样和随后成功重试断言。

未把这些结果升级为系数已校准、真实空间预留或真实耗尽仍可完成恢复的保证。后续原生 restoreFault/SIGKILL 验证不属于本次增量结论；Windows/Android 设备验证仍按用户要求延期。

### Recommendation

**APPROVE — 上述空间准入增量无未解决发现。**
