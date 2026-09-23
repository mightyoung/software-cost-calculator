# Web 实际配额拒绝独立审查

日期：2026-09-18。**APPROVE，仅本轮真实浏览器配额验证增量。**

## Code Review Summary

**Files Reviewed:** 2  
**Total Issues:** 0 unresolved

### By Severity

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0

## 范围与发现闭环

审查 `apps/supplier_app/tool/web_restore_test.py` 与 `tool/web_restore_smoke.dart` 的 actual_quota 增量；正式 Web activate/文件适配代码作为调用上下文。本轮没有修改产品实现，也没有将手工 DOMException 注入当作真实配额证据。

关闭一项 LOW 验证缺口：旧草稿在失败后才读取用于比较的旧版本，只能证明失败后与重开一致。最终 `quota_prepare` 在降低配额和激活前保存 `quotaBaseline`，重开后按该基线核对 instance/epoch/generation，补足“失败前后不变”的证据。

## 核对结果

runner 使用自己创建的临时 Chrome profile 与 localhost origin。先建立正式旧库和已验证候选，再通过 CDP 将该 origin 配额设为正数 **1 byte**，并读取 getUsageAndQuota 确认 `overrideActive=true`、`quota=1`。本结论不采用先前 quota=0 的尝试。

生产 activateRestore 被注入故意陈旧的充足容量估算；断言要求最后估算 phase 为 activate 且 fits 为 true，因此拒绝不是提前预算门的结果。测试 wrappers 的 observe 仅记录并原样重抛实际 adapter Promise 异常；此场景执行时人工 fault 为空，手工 quota/close/IDB 故障场景在其后独立执行。

finally 省略 quotaSize 撤销覆盖，并再次查询确认 overrideActive=false，然后关闭/重开 host。除预先版本基线外，还检查精确名称 retained/snapshot、两条原成功回执及 activation journal 为空。真实拒绝发生在 **durable-output-create**，安全备份目标创建失败，尚未 armed；不能据此声称实际配额故障已覆盖每次流写入、close、候选事务或指针 CAS。

## 验证来源

独立运行 `dart analyze tool/web_restore_smoke.dart`：No issues found；Python AST 语法检查通过。未再启动浏览器。

读取主集成者最终 `artifacts/development/web-restore-quota-run.log` 和 `web-restore-smoke.json`：**PASS**，浏览器 `Chrome/152.0.7977.84`；限制期间 usage=4313528、quota=1、overrideActive=true；观测到 stage=durable-output-create、name=QuotaExceededError；撤销后 overrideActive=false；estimate_allowed、original_preserved、receipts_preserved、unarmed 均 true。已核对这些字段对应的源码断言，不把布尔报告单独当作证明。

这是 Chromium quota manager 的实际拒绝，不是物理磁盘填满，也不代表操作系统文件权限撤销。既有手工故障矩阵与状态 fixture 的限制仍有效。Windows/Android 设备验证按用户要求延期。

## G003（T5/T6）本阶段要求核对

只读核对正确执行空间 `.omx/executions/supplier-development/.omx/ultragoal/goals.json`、批准 PRD T5/T6、实施计划 T5/T6 及现有独立审查/阶段证据；没有修改 goal 状态。当前未识别额外本阶段明确必做阻塞：有界逻辑备份/候选验证、活动指针与故障恢复、持久文件任务/源重选/过期版本、范围流与发布失败、空间预算错误下实际 SQLite FULL 和 Web quota 隔离，以及查询白名单、稳定分页、精确比价、索引计划、固定种子 10k/100k 初测均已有相应材料。

上述判断是当前审查与证据的阶段交接建议，不把逐条限定审查自动升级为完整产品验收。T7 业务回执/Excel编辑回流、T8 UI、T9 多卷 bundle、T11 全链路规模/峰值/正式性能仍是后续目标；不将它们重定义为本阶段新增阻塞。worker 确定性回收和未测平台范围继续如实记录，不声称已消除所有生命周期或发布风险。阶段文档的旧未完成描述应由最新汇总明确覆盖，最终 checkpoint 由主集成者负责。

### Recommendation

**APPROVE — actual_quota 增量无未解决发现；当前未发现阻止 G003 按既定阶段范围交接的额外明确缺口。**
