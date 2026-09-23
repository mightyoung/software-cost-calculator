# 原生恢复激活独立架构复核

日期：2026-09-17。修复后结论：**APPROVE，R1已关闭，本次限定审计范围无未关闭发现**。这是只读代码复核与新鲜日志核对，未修改实现、未自行执行恢复测试，不代表设备验收或完整 T5 通过。

## 审计范围

- [native_restore.dart](../../apps/supplier_app/lib/platform/native_restore.dart)：候选准备、激活 journal、启动恢复和回退。
- [native_database_host.dart](../../apps/supplier_app/lib/platform/native_database_host.dart)：启动顺序、活动指针、连接身份隔离与安装元库。
- [backup_service.dart](../../packages/supplier_core/lib/src/application/backup_service.dart)：同锁备份上下文；另核对候选构建、epoch更新和提交协调器相关边界。
- [candidate_digest.dart](../../packages/supplier_core/lib/src/data/candidate_digest.dart)：候选稳定内容摘要；[candidate_digest_test.dart](../../packages/supplier_core/test/candidate_digest_test.dart)覆盖范围与分页反例。
- 依据：[批准 PRD 第3.2/3.3节](../../.omx/plans/prd-supplier-ralplan.md)的候选摘要、锁序、指针切换、重开与安全回退要求。

## 已关闭发现

### R1 / 原HIGH，已关闭：候选 epoch 写入后的恢复路径失去内容摘要绑定

原实现的 `_finishActivation` 在 `armed` 且候选 `actualEpoch == new_epoch` 时跳过 `_verifyCandidateFile`；`switched` 路径也直接进入重开检查。随后仅验证 SQLite integrity/FK、表/schema、instance/epoch 和 generation，缺少候选内容绑定。

原触发条件：准备合法候选并留下 `armed + 候选epoch已提交` 或 `switched` 的持久状态；候选文件中 `supplier_projection.name` 或 `local_settings` 被改动，但 instance/epoch/generation不变，SQLite结构与FK仍合法。原路径可能接受不再等于用户确认内容的候选。

修复已核对：prepare在已完成候选构建/验证后计算并持久保存 `content_digest`。`candidateContentDigest` 在同一读事务内分页哈希非SQLite内部schema定义及全部required表，包括权威修订、派生投影、设置、回执和工作表；唯一被规范化的数据值是 `database_meta.active_epoch`，其余身份/generation仍进入摘要。schema定义同时绑定约束、触发器和索引。

`_finishActivation` 的共同接受路径通过新连接重新计算摘要，与prepare持久值比较，随后才提交accepted；该检查覆盖正常激活、armed已写epoch和switched恢复，不是事后重新信任未经确认的新摘要。新增armed_epoch设置篡改、switched投影篡改用例均验证回到完整旧库及递增epoch，未篡改窗口仍可恢复。结合下列新鲜测试日志，R1关闭。

## 已落实的架构边界

| 要求 | 当前代码判断 |
|---|---|
| 同锁预备份 | activate 使用 `withApplicationWriteContext`；BackupService 接收同一上下文，不递归申请锁。自验并发布当前库备份后才写 armed |
| armed先于候选epoch | 先持久登记旧版本、候选ID、新epoch、备份路径，再调用 epoch CAS 更新；中断后可识别0或目标epoch |
| 原子指针/状态切换 | active指针与switched在同一安装元库事务中提交 |
| 接受前重开 | switched后以新连接校验身份、schema、SQLite/FK、generation及prepare持久的完整候选内容摘要；通过后才accepted |
| accepted后不可自动回退 | accepted与候选used同事务；异常路径重读accepted后不回退，启动accepted路径也不自动回切旧库 |
| 未完成激活拒写 | `readActiveVersion` 拒绝armed/switched/rollback_pending；启动在分配业务host前先运行恢复 |
| 旧host隔离 | `_openedVersion` 固定打开时的instance/epoch；与当前指针及已连接库同时比较，旧host不能取得新epoch |
| 回退中断窗口 | 先持久rollback_pending，再把保留旧库更新到new_epoch+1；指针回切与rolled_back同事务，重复恢复识别旧epoch或回退epoch |
| 回退不覆盖已改旧库 | 回退检查保留库generation等于journal旧值，否则拒绝；旧库文件不删除 |
| 安装身份保留 | deviceId留在独立安装元库；候选使用新instance；恢复不覆盖设备ID |

以上是当前代码顺序与检查的观察，不把静态存在的分支当作对应故障测试已通过。

## 测试证据与边界

已读取最新 [native-restore-tests.log](../../artifacts/development/native-restore-tests.log)：**13/13恢复专项PASS**，对应 [native_restore_test.dart](../../apps/supplier_app/test/native_restore_test.dart)。该日志已更新，先前17项组合测试的引用不作为本次计数。日志仍含 Drift 多实例调试告警，不称零告警运行。

13项包含原5项业务恢复检查，以及8个持久边界：armed、armed_epoch、switched、rollback_pending、rollback_epoch、switched损坏文件、armed_epoch设置篡改、switched投影篡改。测试通过直接构造元库journal/活动指针/库epoch状态，再重开host验证结果；这是**持久状态重建测试，不是真实kill、断电或存储刷新故障注入**。accepted提交响应丢失、实际进程强杀和电源故障仍未由这13项证明。

另读取 [candidate-tests.log](../../artifacts/development/candidate-tests.log)：候选构建与内容摘要组合 **22 tests PASS**，以及 [candidate-analyze.log](../../artifacts/development/candidate-analyze.log) 的 No issues found。摘要用例覆盖仅epoch变化不改变摘要、generation/触发器/索引/设置/投影/修订/回执/工作表变化改变摘要、跨32行分页与插入顺序无关、过大行拒绝。早期 `candidate-digest-tests.log` 的编译失败仍保留，不能误作最新结果。

本报告只涉及本机原生实现与日志观察，不宣称Windows/Android设备、跨进程强杀、外部用户保存目标或大规模峰值通过。Windows/Android设备验证继续按用户要求DEFERRED，不作为本次架构交接的额外阻塞项。

## 审计快照

```text
native_restore.dart
3657cb5cfd643df5be7c2a158da01e81850db4ac8cf9601a138000626ac6a7cf
native_database_host.dart
170ec36f4fdb73bb51883890917a245e9ca23c4ebc514c95a47a104214fa124b
candidate_digest.dart
b2db2b05e2ea696e0fa69c5b55596c3c8004b81dfe701a849e48a5e7137746b8
backup_service.dart
6de18c74f1fc4ccba7263c5bca8af9f497294ed62d1ea6344c44153846605e0a
native_restore_test.dart
5c8d078cbf19a17e2624d5b417c7443294f1642e8ff2301ec0b6d90680a4115b
native-restore-tests.log
661c9b24bba0aa29daa30458a48ad2e4603ebaa99589bf92fc07eb2712e646df
```

SHA-256对应本次读取的实现快照；后续修复须以新源码与新鲜验证更新结论。
