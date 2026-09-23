# 完整开发执行记录

当前 G001、G002（T3/T4）均已由官方 checkpoint 标记 complete，G003（T5/T6）为 in_progress，原生聚合目标 active。正式历史仓储、原子提交、持久图校验与 RecordService 已完成当前内核交接；正在开发备份恢复/文件任务与分页查询/精确比价。业务界面及 M1/M2/M3 尚未完成。用户要求暂缓 Android/Windows 验证的覆盖决定继续有效，G001 完成不等于未测平台能力通过。

## 当前阶段证据与分工

- T5/T6当前集成快照核心 **218 tests PASS**、analyze clean、AOT SQL/query smoke PASS，见 [business-core-tests.log](../../artifacts/development/business-core-tests.log)、[business-core-analyze.log](../../artifacts/development/business-core-analyze.log)、[query-build.log](../../artifacts/development/query-build.log)。两阶段持久文件任务已有12项测试及[独立审查](../verification/file-job-review.md)。本机文件/宿主/备份恢复联合已有 **34 tests PASS**；G003仍在进行，Web恢复已获限定审查通过；文件/UI流程及剩余故障验收未完成。
- 核心全套 **107 tests PASS**、analyze clean、可执行 SQLite smoke 构建及运行 PASS，分别见 [kernel-tests.log](../../artifacts/development/kernel-tests.log)、[kernel-analyze.log](../../artifacts/development/kernel-analyze.log)、[kernel-build.log](../../artifacts/development/kernel-build.log)。这是 T3/T4 内核与宿主验证，不是 M1 或50万修订规模验收。
- [内核独立代码审查](../verification/kernel-review.md) 为 **APPROVE**，独立重跑39项针对性测试通过；范围及未覆盖事项以报告为准。
- [原生文件端口报告](../verification/native-file-ports.md) 记录8项测试和修复复核；覆盖私有任务目录输出与单 owner isolate 写锁，不包含外部用户保存目标。
- 原生文件/宿主/备份 artifact 联合 **21 tests PASS**，见 [native-file-backup-host-tests.log](../../artifacts/development/native-file-backup-host-tests.log)：安装元库升级保留设备身份、旧连接 epoch 隔离、缺失/损坏活动库拒绝及真实文件备份。限定本机临时文件，不作为延期设备的验证。
- 备份格式及容量边界 **18 VM + 18 Chrome PASS**，导出服务8项、候选构建12项；[备份独立审查](../verification/backup-core-review.md) APPROVE。候选内容摘要覆盖 schema、权威及派生表，只忽略激活 epoch。
- 原生恢复专项 **13 tests PASS**，见 [native-restore-tests.log](../../artifacts/development/native-restore-tests.log)；持久状态重建覆盖 armed/switched/rollback_pending 及 epoch 窗口、内容篡改回退、accepted 后禁止自动回退。[独立架构复核](../verification/native-restore-architecture.md) APPROVE。不是实际进程 kill/断电验证，Web生产恢复与文件任务/UI仍未完成。
- T6 查询正确性独立审查 [APPROVE](../verification/query-review.md)。100k报价/500k修订真实文件已生成；分页先取有序ID再关联展示字段，20轮本机暖查询p95为前缀257.943ms、包含75.710ms。完整计数、SQLite integrity/quick-check及外键检查通过；详见 [查询报告](../verification/query-layer.md)。这不代表实际导入、Web或延期设备性能通过。
- 正式Web适配实际Chrome已通过记录写入、嵌套回滚、备份回读、跨标签页应用锁、独立元库CAS及完整浏览器重启持久化；见 [Web报告](../verification/web-runtime.md)。修复限定Drift2.35 opfsLocks嵌套事务，Native保持默认事务。Web恢复激活及九个持久边界已通过真实Chrome测试并获限定审查通过，详见[恢复报告](../verification/web-restore.md)；worker回收、quota/I/O故障和用户文件/UI仍需后续工作，G003未完成。
- T7前置转换已有13 VM/Chrome测试和独立审查；有界单卷ZIP已有11 Chrome测试（合入218项核心回归），修复local extra与descriptor CRC歧义。见 [Excel基础边界](../verification/business-excel-foundations.md)。尚未完成XML工作表读取、业务回执、导出或Office往返。
- 主集成者负责 T5 备份与平台接入；core_storage 通道负责 T6 查询。UI 接入继续遵循 [交互契约](ui-interaction-contract.md)，等待正式公共服务冻结，不引入临时 CRUD。

当前目标状态已核对 `.omx/executions/supplier-development/.omx/ultragoal/goals.json`；后文保留早期实验和阻塞历史，不将其旧状态当作当前实现。

## 最新执行覆盖：设备验证延期

Windows/Android 实际设备测试统一记为 **DEFERRED（用户明确延期）**，不记 PASS；本轮不继续寻找设备或要求用户先完成设备验证。按批准功能范围继续 T3/T4 及后续开发，其他正确性、事务、协议和服务依赖保持。已有 Android arm64 debug APK 构建证据仍仅证明构建和静态包检查。

延期调整开发顺序，不取消后续设备证据，也不自动赋予首版平台支持或发布通过结论。正式原生启动流程实际打开持久 SQLite、取得可靠应用写锁并完成活动库指针初始化后，可以开放对应业务写入；不要求历史 Windows/Android 验证报告先标 PASS。内存回退或缺少可靠跨写者锁仍在运行期拒绝写入，不能硬编码能力 PASS。下文等待设备与 blocked 快照属于被本次决定覆盖的历史记录。

本次用户要求从已有成果继续完成批准计划。主计划仍为 `.omx/plans/prd-supplier-ralplan.md`，产品约束仍为 `docs/superpowers/specs/2026-09-16-supplier-inquiry-design.md`。

旧根目录Ultragoal账本是另一个已完成的阶段0任务，其会话指针仍绑定存活所有者。本次通过官方CLI在 `.omx/executions/supplier-development` 下建立新执行空间，没有删除、覆盖或冒用旧会话。

- 持久brief：`.omx/executions/supplier-development/.omx/ultragoal/brief.md`
- 目标：`.omx/executions/supplier-development/.omx/ultragoal/goals.json`
- 账本：`.omx/executions/supplier-development/.omx/ultragoal/ledger.jsonl`
- Codex聚合目标已由原生create_goal建立；仅全部实现、清理、验证、独立双角色审查通过后结束。

## 顺序

1. G001-t1-t2：补T1可运行存储/快照/恢复实验，复测T2。
2. G002-t3-t4：正式历史仓储、原子提交、持久图校验和记录服务。
3. G003-t5-t6：备份恢复、文件任务、分页查询与比价。
4. G004-t7-t8-excel-m1：业务Excel和可用本地界面。
5. G005-t9-t10-m2：全量分卷同步与人工冲突。
6. G006-t11-t12-m3：规模/故障/Web及可运行本机验证与最终质量门；Android/Windows设备验证延期。

## 实施与发布边界

设备验证延期与未实现分别记录。平台适配、正式仓储和应用服务开发继续推进；正式写入口依据实际启动能力及事务/图验证开放，不依赖历史设备验收清单放行。不把宿主实验作为Windows/Android实机证据，最终发布验收不能用代码构建替代。

文件输入输出与应用写锁已有原生基础适配，T5 继续接入备份/任务/启动流程；规范字段继续由单一内核负责人维护。UI等正式服务后接入，不以临时可变CRUD替代修订历史。

## 早期验证记录（当前内核交接见上文）

- 本机SQLite隔离原型21项通过，原生CLI构建与锁运行检查通过。
- 本机文件流隔离原型6项通过，包括真实读取中截断、源失败清理和已有文件保留。
- Web真实SQLite分页快照、双顶层标签页写锁、完整浏览器重启和未提交事务期间强杀回滚通过；独立报告继续记录候选库切换实验。
- T4纯图起草阶段：34项图测试，核心VM全套64项、Chrome纯测试51项；100固定种子DAG的heads与独立集合差oracle一致，单实体12000条历史、2000重定向深链均分页迭代。当时图工作区只有抽象持久端口和小型测试适配，尚未安装生产仓储/RecordService/可信提交令牌；该实现状态现已由 G002 交接取代。
- 图草稿独立code-reviewer为APPROVE，architect为CLEAR；仅覆盖纯算法/测试边界，见docs/verification/pure-graph-review.md，不代表生产集成或整体任务完成。

`artifacts/development/core-analyze-final.log`、`core-tests-final.log`、`core-chrome-graph-verified.log` 保存新鲜测试输出。根目录直接 `dart analyze` 会扫描历史独立脚本 `artifacts/supplier-probe/check_encoder_budget.dart` 并报未解析的excel包；正式包与隔离原型分别分析通过，未修改历史脚本或伪称根目录检查通过。

Android工程壳debug APK已成功构建，API29/36、arm64-v8a、v2调试签名核对通过；没有设备运行证据。详情和SHA见docs/verification/android-build-gate.md。

## 历史阻塞记录（已由最新执行覆盖取代）

此前账本状态：G001为in_progress，G002–G006为pending，原生聚合目标active，未标记任何整体开发里程碑完成。等待设备接入或明确调整开发依赖的决定已通过官方steer记入ledger；运行时拒绝在active原生目标下写blocked checkpoint，因此没有伪造blocked/complete状态。当时原生快照为 `.omx/executions/supplier-development/goal-snapshot-awaiting-platform.json`。

随后连续三轮复核，同一平台门阻塞未变、当时没有设备接入或明确门槛调整决定。原生聚合目标曾通过update_goal标记blocked，随后官方checkpoint成功记录阻塞证据；没有标记complete。当时快照为 `.omx/executions/supplier-development/goal-snapshot-blocked.json`。该暂停现已由用户明确延期设备验证的决定解除，当前状态以本文开头及官方执行账本为准。
