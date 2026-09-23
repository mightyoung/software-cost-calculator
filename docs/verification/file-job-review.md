# 持久文件任务独立审查

日期：2026-09-17。**APPROVE，限 JobStore 与关联 schema；不是 T5 全部完成结论。**

## Code Review Summary

**Files Reviewed:** 3  
**Total Issues:** 0 unresolved

### By Severity

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0

## 范围与依据

- `packages/supplier_core/lib/src/exchange/job_store.dart`
- `packages/supplier_core/test/backup_job_test.dart`
- `packages/supplier_core/lib/src/data/tables.dart` 的 `job_input`、绑定触发器及确认事件索引增量

依据批准 PRD、实施计划 T5/T7 和测试规格 A10/A11。只读追踪 `CommitCoordinator`、数据库封存和回执实现作为上下文，不重复批准整个事务内核。审查关注状态转换、持久身份、源重选、版本绑定、不可变封存及有界读取。

## 发现闭环

1. 原 `create` 在返回任务 ID 前读取全部源文件，无法支撑先订阅任务再执行耗时准备的入口契约。现先读取长度、持久化 created 任务并返回；完整哈希由调用者等待的 `bindSource` 完成。绑定期间可按任务 ID 取消，且定期及发布前检查状态/数据库版本，没有脱离任务管理的后台 Future。
2. 已提交任务证明按 `confirmation_event.job_id` 查找，原 schema 只有 event_id 主键。新增 `confirmation_job(job_id,event_id)`，独立运行的 EXPLAIN 回归确认 job_id 使用该索引。

## 已核对行为

未绑定源不能进入 parsing、封存或重启验证。首次绑定要求创建时的原始活句柄；重开后丢失未绑定身份会明确失败，要求新建任务，不猜测新选择文件属于旧任务。成功绑定后重选按长度及 SHA256 比较；数据库触发器阻止已绑定长度/摘要被覆盖。源 IO/截断异常向调用者传播，不生成成功绑定。

状态转换执行应用锁、活动实例/epoch/generation 核对和事务内状态 CAS。封存绑定创建时版本与 schema；过期预览只能取消旧尝试并建立链接的新空尝试，保留旧 seal，丢弃旧决定和 expected-head 输入。调用方仍须重新解析验证。cancelled/failed 为终态；协调器自身也拒绝以旧 token 复活终态任务。

公共状态接口不能直接签发 previewReady、committing 或 committed。重开时成功状态要求同任务、同 seal/decisions、同实例/epoch/schema/起始 generation 的持久确认与回执，结果计数必须一致；仅伪写 committed 状态不能作为成功证明。真实协调器提交后关闭再打开的回归通过。

源读取每次请求最多 64KiB，累计长度和范围实际读取量严格校验，SHA256 流式计算，无整文件收集或总文件大小限制；安全整数长度检查保留。初次绑定每 1MiB 及结束时做取消/版本检查。这里不把 range 上限或 EXPLAIN 证明声称为全应用内存/性能验收。

## 验证证据与边界

本独立审查通道执行上述三个文件的 `dart analyze`：**No issues found!**；执行 `dart test test/backup_job_test.dart --reporter expanded`：**12/12 PASS**。包含真实 SQLite 文件重开、先创建后读取、绑定中取消、未绑定身份丢失、截断、索引、伪成功、真实成功回执、回执版本不匹配、旧 seal 重启、版本漂移和状态 CAS。初轮 7 项测试已被这次完整 12 项执行覆盖，不重复累计。

本类是持久任务基础，不是完整 `watchJob/prepare/resume` 用户流程。T7 解析必须对实际消费的输入重新哈希并在封存前核对，不能把先前 `verifySource` 当作文件此后不可变的证明。解析错误诊断/进度 UI、分页预览、整包恢复、Web 文件端口、原生激活状态机、真实 quota、Windows/Android 设备与大规模性能均不在本次批准范围。

### Recommendation

**APPROVE — 当前限定范围无未解决问题。**
