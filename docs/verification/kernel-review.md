# T3/T4 内核独立代码审查

日期：2026-09-17。代码审查通道最终复核；架构通道结论由主集成者另行合并。

## Code Review Summary

**Files Reviewed:** 12  
**Total Issues:** 0 unresolved  
**Recommendation:** APPROVE，限下列 T3/T4 代码与宿主验证范围。

### By Severity

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0

## 精确范围

以下路径均相对 `packages/supplier_core/`：

- `lib/src/data/commit_coordinator.dart`
- `lib/src/data/database.dart`
- `lib/src/data/graph_workspace.dart`
- `lib/src/data/migrations.dart`
- `lib/src/data/projection_writer.dart`
- `lib/src/data/tables.dart`
- `lib/src/application/record_service.dart`
- `lib/src/domain/aliases.dart`
- `lib/src/contracts.dart`
- `test/storage_test.dart`
- `test/record_service_test.dart`
- `test/support/test_rig.dart`

复核源码集合指纹：`027cbb8a326cfd898b677fa83ee12c546b988be56bd2be0cdbcc6a41e11cc82d`。
算法：相对路径升序；每文件拼接 `path + LF + SHA256(file bytes) + LF`，再对拼接后的 UTF-8 求 SHA256。未包含本报告或其他文档。

规格依据：`.omx/plans/prd-supplier-ralplan.md` §§3.1–3.4、T3/T4；`.omx/plans/test-spec-supplier-ralplan.md` 对应事务、图、陈旧版本与确认重试要求；`docs/superpowers/specs/2026-09-16-supplier-inquiry-design.md` 的历史、快照、冲突与重定向规则。

## 已关闭发现

| 原发现 | 修复与回归证据 |
| --- | --- |
| 同目标并行 redirect 撞邻接唯一键 | 只对精确邻接键去重，保留全部 revision heads；真实 SQL 提交回归确认 parallelRedirect |
| quarantine 只记状态，旧结果仍可读 | 工作区读取/写入检查 run 状态；真实 DELETE 失败、重开后旧 run 读取和 reset 拒绝，恢复后可清理 |
| coordinator 清理覆盖主错误 | 同时保留 primary/cleanup 及 stack，携带 committedReceipt；覆盖业务提交前、后及单独清理失败 |
| entity/neighbor 分页不能范围 seek | entity 使用复合 tuple；双向邻接分支直接按 target_id/source_id 下界 seek；EXPLAIN 回归验证两个方向范围索引 |
| 无关纠错重写或拒绝历史引用 | 未变 supplier/product 引用保留；删除关联后的 notes 纠错、supplier 合并且 contact 后改电话后的 notes 纠错，保留原 ID/快照 |
| RecordService 吞已提交清理错误 | `graph_cleanup_failed` 明确向调用者传播并保留成功回执上下文；普通提交后响应丢失仍按同一持久事件恢复 |

另核对：私有校验结果由协调器自己的真实图运行产生；封存触发器、确认身份绑定、预期 heads CAS、统一锁序、全部页同一最终事务；标准报价祖先状态跨 delete 传播；冲突投影保留显式无胜者摘要；受影响实体及依赖投影按持久工作表更新，未改实体不重写。未发现本范围内绕过图校验的成功回退。

## 本通道新鲜验证

在 `packages/supplier_core/` 使用本机 Dart SDK：

```sh
/private/tmp/supplier-inquiry-toolchain/flutter/bin/cache/dart-sdk/bin/dart analyze lib/src/data lib/src/application/record_service.dart lib/src/domain/aliases.dart lib/src/contracts.dart test/storage_test.dart test/record_service_test.dart test/support/test_rig.dart
```

结果：`No issues found!`。

```sh
PUB_CACHE=/private/tmp/supplier-inquiry-toolchain/pub-cache XDG_CONFIG_HOME=/private/tmp/supplier-inquiry-toolchain/config /private/tmp/supplier-inquiry-toolchain/flutter/bin/cache/dart-sdk/bin/dart test test/storage_test.dart test/record_service_test.dart --reporter expanded
```

结果：**39/39 PASS**。包括首/中/末页回滚与重开、提交后重试、封存篡改、版本失效、hash 拒绝、100 固定种子 SQL DAG heads oracle、201 修订单实体链、隔离、CAS、联系人快照、历史引用、合并修复和冲突解决。

命令与结果由独立审查通道重新执行；此报告不以作者全套测试日志替代上述观察。主集成者维护的全套 core/浏览器日志属于另行验证，不在本报告冒称已重新运行。

## 结论边界

本通道已无阻断 T3/T4 代码依赖交接给 T5/T6 的发现；最终双通道 gate 由主集成者结合独立架构结论决定。

本结论不是 M1/M2/M3 或三端发布通过。真实跨进程/标签锁、活动库指针恢复、备份/交换、查询性能及 50万修订峰值仍属于后续任务的实测范围；201 条 SQL 深链和小图 oracle 不替代规模证明。Windows/Android 实机验证按用户要求 DEFERRED，不记 PASS，也不作为本次代码交接阻断。
