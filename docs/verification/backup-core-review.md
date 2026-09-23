# 备份格式、导出与候选构建独立审查

日期：2026-09-17。**APPROVE，限以下 core 与私有原生 artifact 范围。不是完整恢复或 T5 完成结论。**

## Code Review Summary

**Files Reviewed:** 9  
**Total Issues:** 0 unresolved  
CRITICAL / HIGH / MEDIUM / LOW 均为 0。

## 范围

- `packages/supplier_core/lib/src/exchange/backup_format.dart`
- `packages/supplier_core/lib/src/application/backup_service.dart`
- `packages/supplier_core/lib/src/application/backup_candidate.dart` 的 `BackupCandidateBuilder`
- `packages/supplier_core/lib/src/contracts.dart` 新增锁上下文部分
- `packages/supplier_core/test/{backup_format,backup_service,backup_candidate}_test.dart`
- `apps/supplier_app/lib/platform/native_backup_artifact.dart`
- `apps/supplier_app/test/native_backup_artifact_test.dart`

依据批准设计 §8、PRD §3.2–3.4 与 T5，以及先前格式审查发现。只读核对 SQLite schema、真实图提交器和原生文件端口作为上下文；不重复批准整个内核。

## 发现闭环

- 编码前完成字符串转义字节预算检查；大型设置在 JSON 解析/编码前拒绝。导出从 SQLite 读取大字段前先按 `octet_length` 检查；按 32 行分页，不把整个备份收集到内存。
- header、row 外层与 footer 精确键校验；备份表/列白名单固定，回执数字按列校验并规范化为安全整数，拒绝字符串/null 冒充数字及不支持版本。
- UTF-8/JSON 语法与后续语义构造的错误均有结构化诊断、原始异常/堆栈及行号/字节位置；回调和源 IO 不在解析 catch 内，不被伪装成格式错误。
- 候选恢复拒绝“同来源实例回执 generation 晚于备份 header generation”的自相矛盾内容；以前恢复的不同实例回执不受此上界误伤。

## 其余核对

导出在应用写锁内核对活动版本，再开启读事务；全部表来自同一事务，完成的私有文件重新解析校验后才复制并发布。`ApplicationWriteContext` 私有构造、同锁身份与生命周期检查允许既有持锁流程复用，无递归取锁。输出 abort 与私有 artifact dispose 同时失败时，原始异常及两次清理异常仍可追溯；发布后清理失败不伪称未发布。

候选构建器仅接受独占空候选：footer 通过前修订停留在 staging；重复修订/辅助键拒绝，后续由真实图协调器验证闭包、heads 和投影。辅助数据按持久工作表分页恢复，检查表计数、FK、成功事件/任务、结果数量及行回执属于同事件结果集合；保留原回执身份，清理合成提交记录。失败候选必须由调用者整体丢弃，不能作为活动库开放。

NativeBackupArtifact 只创建和清理自己的唯一任务目录，正式输出发布前读取冻结的私有文件；本类不提供任意用户文件覆盖能力。

## 证据归属与边界

独立审查通道最终对上述 core 源码/测试执行 `dart analyze`：**No issues found!**。执行三个 core 测试文件：**34/34 PASS**（格式 14、导出 8、候选 12）。新增语义错误位置与同来源回执 generation 回归均包含在内。

独立原生 artifact 源码/测试 analyze：**No issues found!**。读取主集成者真实文件日志 `artifacts/development/native-backup-artifact-tests.log`：**1/1 PASS**；原生运行结果来自主集成者环境，本通道未在沙箱重复获得 Flutter 运行通过。先前 Chrome 格式+预算 **16 PASS** 日志已读取；最终新增两项语义诊断用例的 Chrome 结果未据此冒称已验证。

新增候选完整内容摘要、native 激活 journal/指针 CAS、epoch 重绑定后的最终内容复核由后续独立通道审查，不包含在本次批准。也不包含故障切换矩阵、平台真实 quota、Windows/Android 实机或大规模峰值；不把临时候选建立成功称为恢复完成。

## 后续新增范围：候选内容摘要

独立新增审查 `packages/supplier_core/lib/src/data/candidate_digest.dart` 与 `test/candidate_digest_test.dart`，**APPROVE，0 unresolved**。本段扩展前述范围中的摘要函数结论，不扩展到 native 恢复状态机或激活接入正确性。

最终独立执行这两个文件的 `dart analyze`：**No issues found!**；独立摘要测试 **12/12 PASS**。这是在前述 34 项测试之外新增的独立证据，不将实现者的 digest/builder 联合套件算作本通道复跑。

发现并关闭两处覆盖遗漏：额外用户表原先只绑定 schema 定义、忽略表数据，现直接拒绝非 required 表；SQLite `user_version` 原先未绑定，现要求与支持版本一致并纳入摘要。两项分别有回归。

已核对所有 required 表，包括权威修订、投影、设置、回执和工作表；schema 中的表、索引、触发器等定义参与摘要。数据按实际主键顺序分页，每页 32 行；主键缺失/null 明确拒绝。查询字段前用 SQLite `octet_length` 限制单行原始字段总量，schema 对象数量与定义字节同样有界；编码转义可能放大单条输出，因此不把 512KiB 原始字段门限声称为实际总内存峰值。所有扫描在同一读事务中完成，动态标识符有引用转义，schema SQL 仅作为文本读取与哈希。

业务表值仅将 `database_meta.active_epoch` 规范化为 0，instance/generation/schema、内容与回执均保留；SQLite 内部 bookkeeping 不属于逻辑内容。测试确认 epoch 改变摘要不变，generation、trigger/index、设置、投影、修订、回执及工作表改变摘要；71 行跨页扫描与不同插入顺序结果稳定，超大字段拒绝。

最终源码 SHA256：`candidate_digest.dart` 为 `cb811c7cc91b63956504335c3179cf9938386086e42ba3a0f11bc502febfd169`；测试为 `97a6b065a91cf4431d7606c49be1b0f5b16da89e6b2a51b168ef1cd64c4b1e1d`。摘要是对已验证候选的内容绑定，不独立证明基线图/schema 本身合法，不替代 native 激活阶段比对、完整性检查或崩溃恢复验证。
