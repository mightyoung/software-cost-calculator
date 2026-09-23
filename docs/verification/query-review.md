# T6 查询独立代码审查

日期：2026-09-17。**APPROVE，仅限 T6 查询正确性；未批准性能或平台发布。**

## Code Review Summary

**Files Reviewed:** 7  
**Total Issues:** 0 unresolved

CRITICAL / HIGH / MEDIUM / LOW 均为 0。

范围：`packages/supplier_core/lib/src/query/{query_repository,comparison,search_keys,candidates}.dart`、`lib/src/data/{tables,projection_writer}.dart` 与 `test/query_test.dart`。依据批准设计 §7、PRD T6 和 `docs/implementation/kernel-query-exchange-notes.md` 中已核对的查询契约。

## 已关闭发现

- 冲突报价原先未登记各当前 head 的引用依赖，关联实体合并后 canonical 字段可能过期。现按全部当前 put heads 保存去重依赖，引用主键容纳同字段多个目标；目标变化触发相关投影更新。
- 删除、重定向及并行非 put heads 原先失去历史名称检索能力。现对没有当前 put 的实体，以索引 keyset 分页保留历史识别词；状态仍明确为删除或冲突，不选胜者。
- 产品文本过滤现同时匹配原 ID 和 canonical ID，合并后旧名称与新名称均可发现相关报价。
- Unicode 前缀上界原先把 U+D7FF 的后继构造成孤立 surrogate。现跳至 U+E000，SQL 回归确认不误收无关私用区键。

另核对：筛选字段和排序白名单、参数绑定、完整比价口径、精确 price_key、未知/未来/过期/异常排除、同日最新和同价并列、分页过滤摘要及 instance/epoch/generation 绑定、冲突 head 分页、联系人快照。未发现以静默空结果或任意胜者绕过错误的回退。

## 证据归属

独立审查通道最终执行相关源码与 `query_test.dart` 的 `dart analyze`，结果 **No issues found!**；最终独立查询回归 **18/18 PASS**，包含并行删除 heads 的历史检索。

此前独立运行查询 17 项与 storage/RecordService 联合套件 **58/58 PASS**；其后修改仅为历史检索的“无当前 put”分支及对应新增用例，不将旧联合结果冒称为最终完整套件复跑。

实现者随后报告查询扩至 **20 项 PASS**，增加显式 null tax_rate 和最大精确小数用例；这些新增用例及后续全 core 结果属于实现者报告，未计入上述 18 项独立复核。

已阅读 `artifacts/development/query-10k.json` 的真实原生 SQLite EXPLAIN：单字段 exact/prefix 使用 search_key 索引范围，contains 扫描另列。该材料是查询结构 fixture 的初测，不是产品写入吞吐、20 次预热 p95 或全链路内存证据。10 万报价/50 万修订、平台峰值与正式 SLA 不在本次 APPROVE 范围；Windows/Android 实机按用户要求延期。

## 后续独立复核：先分页再加载展示字段

2026-09-18，**APPROVE，0 unresolved**。新增范围为 `query_repository.dart` 的 history 分页优化、`query_test.dart` 的新增回归，以及 `docs/verification/query-layer.md`、`artifacts/development/query-100k-optimized.json` 的证据一致性；不扩展到全 T11 或平台性能验收。

已完整核对 SQL 构造和测试上下文。`MATERIALIZED page` 只输出 entity_id 与原排序键；过滤后的 scoped 关系、游标条件、原 sort/ID 稳定排序和 limit+1 都在 page 内。scoped 的非冲突/冲突 UNION ALL 分支互斥，冲突分支通过 EXISTS 检查同一个当前 head 满足全部过滤，多个匹配 head 不会重复报价。候选文本 IN 匹配也不产生行倍增。

page 后按报价主键读取 payload，五个展示 LEFT JOIN 均以主键或完整复合主键关联；不增加过滤条件，不丢失没有展示关联的历史行，也不放大结果数量。因此进入展示联接的报价最多 201 条；最终按 page 中相同 sort key/ID 重排，查询与版本读取仍处于同一事务。confirmed_lowest 分支未改动。

本通道重新执行两份 Dart 文件的 analyze：**No issues found!**；完整查询回归 **21/21 PASS**，包括新增 materialize/两页/展示字段用例、211 条记录在三种排序和 1/50/200 页长下的独立 oracle，以及既有冲突、精确价格、过滤/版本游标测试。这次也独立执行了先前仅由实现者报告的第 19/20 项，不把历次测试次数累计为额外覆盖。

读取 100k 优化报告中的真实 EXPLAIN：page 先 materialize，之后才扫描 page 并按唯一索引加载报价与展示关联。独立复算各 20 个样本的 nearest-rank p95（第 19 个排序样本），prefix 为 **257.943ms**、contains 为 **75.710ms**；最大值分别为 **267.477ms**、**1126.465ms**，与文档一致。本通道没有重跑大库计时；三个 warmup、APFS clone、64MiB cache 与实际运行环境属于实现者保留的测量证据。原先约四秒的单次样本与本次 warm p95 不能直接计算等价加速比。

该优化限制展示 payload/联接规模，不保证过滤或排序总扫描量有界于页长；contains 和广泛匹配仍可能扫描并使用临时排序树。原生宿主机这两组查询满足记录中的阈值，不等同于通用查询 SLA、Web/Android/Windows 性能、产品写入吞吐、峰值内存或完整 T11 通过。
