# T12 发布验收矩阵

更新：2026-09-23。基线：[批准设计](../superpowers/specs/2026-09-16-supplier-inquiry-design.md)、[RALPLAN PRD](../../.omx/plans/prd-supplier-ralplan.md)、[A01–A18 验收规格](../../.omx/plans/test-spec-supplier-ralplan.md)。

**结论：当前为开发候选，正式发布未放行。** Android/Windows 验证按用户明确要求延期，不执行、不算失败、也不算通过。其他缺口继续保留。

## 判定口径

- **PASS**：本项规定范围已执行，结果通过且有可核对证据。
- **PARTIAL**：存在有效分层证据或已实现用例，但完整场景/最终候选重跑证据未齐。
- **BLOCKED**：必需验证受环境或工具条件阻断，无法作通过判断。
- **DEFERRED**：用户明确延期的验证；独立于 PASS/FAIL，不计入通过率。

测试源码链接用于定位覆盖范围。执行结果以本轮完整日志为准，早期专项报告补充平台或故障细节；总测试数不能代替未执行的验收场景。

## 最终候选执行证据

| 检查 | 结果 | 原始证据与范围 |
| --- | --- | --- |
| 核心静态分析 | PASS | [final-core-analyze.log](../../artifacts/development/final-core-analyze.log)：No issues found。 |
| 核心完整测试 | PASS，435/435 | [final-core-tests.log](../../artifacts/development/final-core-tests.log)；包括下表所列核心用例及新增 bundle 内层双失败两项回归。 |
| 应用静态分析 | PASS | [final-app-analyze.log](../../artifacts/development/final-app-analyze.log)：No issues found。 |
| 应用完整测试 | PASS，113/113 | [final-app-tests.log](../../artifacts/development/final-app-tests.log)；包括下表所列应用测试，不能代替 integration_test 目录下的设备集成测试。 |
| Web release 构建 | PASS | [final-web-build.log](../../artifacts/development/final-web-build.log)：Built build/web。 |
| 隔离 Chrome 运行时 | PASS（限定范围） | [运行日志](../../artifacts/development/final-web-runtime.log)、[JSON 报告](../../artifacts/development/web-runtime-smoke.json)：OPFS/IndexedDB、进程重开与跨标签锁；worker 观测数量 5→6→7→8→9，完整内存/泄漏门仍未通过。 |
| Web 正式交换适配器 E2E | PASS（限定范围） | [报告](../../artifacts/development/web-exchange-smoke.json)、[日志](../../artifacts/development/web-exchange-run.log)：真实 OPFS XLSX/ZIP、业务/同步导入、取消及损坏输入无回执；进程重启后备份 locator 可读、重试同回执。绕过系统 chooser，未走 Flutter 点击链路。 |
| 实际 Flutter UI picker | BLOCKED | [报告](../../artifacts/development/web-exchange-ui.json)：已导航至导入并触发真实 picker，自动化无法给 File System Access chooser 提供文件；没有替换 picker，也未完成导入。 |
| 10 万报价/50 万修订查询 | PASS（限定范围） | [2026-09-23 报告](../../artifacts/benchmark/query-100000-20260923/report.json)、[独立 oracle](../../artifacts/benchmark/query-100000-20260923/oracle.json)：全量摘要、分页排序和四项查询时延通过；不代表完整导入/导出/备份/恢复。 |
| A17 并发导出/终止小样本 | PASS，9/9（限定范围） | [报告](../../artifacts/benchmark/a17-concurrency-checkpoint-20260923-v2/report.json)：第 1/5/9 卷各执行 complete/cancel/SIGKILL；并发修改重开保留，只有 complete 发布。平台快照创建、规模及 UI 均未覆盖。 |
| WPS 实际保存与回流 | BLOCKED | [尝试记录](../../artifacts/development/office-roundtrip-wps-attempt.json)：WPS 7.5.1 启动/版本查询成功，AppleEvent 文档与窗口访问超时；未验证保存和正式回流。 |
| 本地工作流集成测试 | BLOCKED，未执行 | [local_workflows_test.dart](../../apps/supplier_app/integration_test/local_workflows_test.dart)；仓库无 macOS target，[尝试日志](../../artifacts/development/final-app-integration.log)报告 Web integration tests 不受支持。Android/Windows 不补跑，按用户要求 DEFERRED。 |
| 最终代码 / 架构审查 | APPROVE / CLEAR | 协调者汇总的本轮 code-reviewer / architect 最终回报，见[清理审查记录](final-cleanup-review.md)。不解除下述发布验收缺口。 |

本轮新增覆盖：

- latest、供应商和联系人查询：[查询用例](../../packages/supplier_core/test/query_test.dart)与[工作区用例](../../apps/supplier_app/test/core_supplier_workspace_test.dart)。
- 复杂关联环、多头与删除/重定向冲突：[关联修复](../../apps/supplier_app/test/alias_repair_test.dart)、[冲突处置与 parallelRedirect 详情入口](../../apps/supplier_app/test/conflict_disposition_test.dart)、上述工作区用例。
- 解析取消、失败同任务重试：[原生业务导入](../../apps/supplier_app/test/business_import_native_test.dart)、[同步工作流](../../apps/supplier_app/test/bundle_workflow_test.dart)、[同步页面](../../apps/supplier_app/test/bundle_sync_page_test.dart)。大型文件真实浏览器取消 ≤2 秒仍未验证。
- 同步工作流主错误、堆栈及取消/abort/dispose 清理错误聚合：[故障回归](../../apps/supplier_app/test/bundle_workflow_test.dart)，已发布输出不会因后续清理失败再次 abort。
- BackupService 输出 abort：[备份服务用例](../../packages/supplier_core/test/backup_service_test.dart)。Web durable backup 已[关联任务及持久 locator](../../apps/supplier_app/lib/platform/web_file_ports.dart)，[正式适配器进程重启回读](../../artifacts/development/web-exchange-smoke.json)通过；完整 UI 入口链路仍缺。
- Android 默认应用支持目录通过 `path_provider` 接入：[目录解析用例](../../apps/supplier_app/test/native_data_directory_test.dart)。这是实现和注入式宿主测试；Android/Windows 实际验证仍 DEFERRED。

## A01–A18

| ID | 场景与当前状态 | 已有证据 | 剩余范围 |
| --- | --- | --- | --- |
| A01 | 标准报价缺字段、零价：**PARTIAL** | [领域用例](../../packages/supplier_core/test/domain_test.dart)、[录入 UI 用例](../../apps/supplier_app/test/local_workflows_test.dart)，本轮核心/应用完整测试均通过 | 缺各必填字段均不得提交的完整产品交互联合核对；设备集成测试未执行。 |
| A02 | 标准/历史模式、纠错与复制：**PARTIAL** | [业务工作流用例](../../packages/supplier_core/test/business_workflow_test.dart)、[记录服务用例](../../packages/supplier_core/test/record_service_test.dart)、[录入用例](../../apps/supplier_app/test/local_workflows_test.dart) | 历史导入→纠错→复制补齐→转标准的完整产品界面闭环。 |
| A03 | 日期精度与时区：**PARTIAL** | [领域用例](../../packages/supplier_core/test/domain_test.dart)、[映射用例](../../packages/supplier_core/test/business_mapping_test.dart)、[映射运行日志](../../artifacts/development/business-mapping-tests.log) | +08/-03:30/+05:45 实际设备互导未完整执行；Android/Windows 部分 DEFERRED。 |
| A04 | 编号、电话、金额精确往返：**PARTIAL** | [业务 Excel 基础](business-excel-foundations.md)、[XLSX 写入测试日志](../../artifacts/development/xlsx-writer-vm-tests.log)、[报价 UI 用例](../../apps/supplier_app/test/local_workflows_test.dart)、[WPS 7.5.1 尝试](../../artifacts/development/office-roundtrip-wps-attempt.json) | WPS 可启动，但文档/窗口 AppleEvent 操作超时，实际改价保存与正式回流仍 BLOCKED；早期 probe 文件不代替本轮完整验收。 |
| A05 | 纠错同 ID、复制/合法重复新 ID：**PARTIAL** | [记录服务用例](../../packages/supplier_core/test/record_service_test.dart)、[新询价与重复导入用例](../../packages/supplier_core/test/business_workflow_test.dart) | 实际产品详情“编辑/复制”操作闭环。 |
| A06 | 改表回流、旧基线、keep/clear/newInquiry：**PARTIAL** | [业务工作流用例](../../packages/supplier_core/test/business_workflow_test.dart)、[业务提交日志](../../artifacts/development/business-commit-tests.log)、[Web 正式适配器 E2E](../../artifacts/development/web-exchange-smoke.json)、[导入页面](../../apps/supplier_app/lib/features/exchange/business_import_page.dart) | OPFS 正式适配器功能链路通过；真实 Excel/WPS 修改回流与 Web 系统 picker→映射→确认完整交互仍未验证。 |
| A07 | 改名重排重导、删除不复活、异设备候选：**PARTIAL** | [回执测试日志](../../artifacts/development/import-receipts-tests.log)、[业务工作流用例](../../packages/supplier_core/test/business_workflow_test.dart) | 实际改名重排/跨设备无回执的人工候选闭环；不承诺无 ID 自动同步。 |
| A08 | 因果合并、并行分支与人工解决：**PARTIAL** | [图用例](../../packages/supplier_core/test/graph_test.dart)、[图浏览器日志](../../artifacts/development/core-chrome-graph-verified.log)、[并集提交用例](../../packages/supplier_core/test/bundle_exchange_service_test.dart)、[冲突 UI 用例](../../apps/supplier_app/test/local_workflows_test.dart)、[Web adapter E2E](../../artifacts/development/web-exchange-smoke.json) | Web bundle 正式适配器通过，完整 UI 交互未独立验证；三设备实际不同顺序环路中原生平台部分 DEFERRED。 |
| A09 | 缺卷、篡改、版本、闭包/投影：**PARTIAL** | [分卷用例](../../packages/supplier_core/test/bundle_test.dart)、[数据库验证用例](../../packages/supplier_core/test/bundle_database_test.dart)、[并集提交用例](../../packages/supplier_core/test/bundle_exchange_service_test.dart)、[Web 损坏输入无回执](../../artifacts/development/web-exchange-smoke.json) | 浏览器正式适配器已覆盖一个损坏输入路径；完整故障组合及真实 picker/UI 路径仍未齐。 |
| A10 | 解析/事务/提交前后中断：**PARTIAL** | [存储事务用例](../../packages/supplier_core/test/storage_transaction_test.dart)、[分卷交换故障用例](../../packages/supplier_core/test/bundle_exchange_service_test.dart)、[原生同步工作流用例](../../apps/supplier_app/test/bundle_workflow_test.dart) | 第一/中/末卷与真实进程终止组合、重开后的最终候选验证；模拟异常不等于全部生命周期验收。 |
| A11 | 第二窗口修改、旧预览与实例切换：**PARTIAL** | [提交上下文日志](../../artifacts/development/commit-context-tests.log)、[同步陈旧预览用例](../../apps/supplier_app/test/bundle_workflow_test.dart)、[关联修复陈旧预览用例](../../apps/supplier_app/test/alias_repair_test.dart) | 真实双窗口产品交互路径。 |
| A12 | 删除、合并、关联异常与环修复：**PARTIAL** | [记录服务用例](../../packages/supplier_core/test/record_service_test.dart)、[查询用例](../../packages/supplier_core/test/query_test.dart)、[关联修复 UI 用例](../../apps/supplier_app/test/alias_repair_test.dart)、[多头/反向关联工作区用例](../../apps/supplier_app/test/core_supplier_workspace_test.dart)、[删除/重定向冲突用例](../../apps/supplier_app/test/conflict_disposition_test.dart) | 复杂环与冲突处置的宿主回归通过；异常查找→显式修复→实际文件同步的完整产品链路仍未独立验收。 |
| A13 | 备份、迁移、恢复切换故障：**PARTIAL** | [原生中断报告](native-restore-interruption.md)、[迁移日志](../../artifacts/development/native-storage-migration-tests.log)、[Web 恢复报告](../../artifacts/development/web-restore-smoke.json)、[Web 安全备份重开](../../artifacts/development/web-exchange-smoke.json)、[恢复 UI 用例](../../apps/supplier_app/test/restore_workflow_test.dart)、[备份失败 abort 用例](../../packages/supplier_core/test/backup_service_test.dart) | 正式适配器的任务安全备份已通过浏览器进程关闭重开后的 locator 回读与同回执重试；完整产品恢复 UI、规模及真实物理磁盘满仍未验。受控配额耗尽及原库/回执保留已有专项证据。 |
| A14 | Web 重开、离线、升级与降级：**PARTIAL** | [Chrome 运行报告](../../artifacts/development/web-runtime-smoke.json)、[Web 存储门](web-storage-gate.md)、[恢复报告](web-restore.md) | OPFS/IndexedDB 重开与跨标签锁有实测；应用离线缓存、资源升级及最终 UI 降级链路仍缺完整证据。重开时 worker 数 5→9，完整内存/泄漏门未通过。 |
| A15 | 10 万报价/50 万修订全链路：**PARTIAL** | [性能报告](performance.md)、[10 万查询 PASS](../../artifacts/benchmark/query-100000-20260923/report.json)、[10 万独立 oracle PASS](../../artifacts/benchmark/query-100000-20260923/oracle.json)；[旧空间阻断](../../artifacts/benchmark/query-100000-space-gate-20260921/report.json)保留为历史 | 查询空间门已解除，扫描、分页、摘要/排序和四项时延通过。完整导入/导出/备份/恢复链路另行运行、尚无完成结果；各环节峰值、首屏/进度/取消时延仍未齐，不能将完整规模改为 PASS。 |
| A16 | Windows→Android→Web→Windows：**DEFERRED** | 用户明确要求先不验证 Android/Windows；[平台能力记录](platform-capabilities.md)仅作已有背景 | 当前不执行原生平台环路，不宣称三端实际文件环路通过。 |
| A17 | 并发导出、一致快照与取消/终止：**PARTIAL** | [快照用例](../../packages/supplier_core/test/export_snapshot_test.dart)、[原生同步工作流用例](../../apps/supplier_app/test/bundle_workflow_test.dart)、[第 1/5/9 卷 complete/cancel/SIGKILL 9/9 PASS](../../artifacts/benchmark/a17-concurrency-checkpoint-20260923-v2/report.json)、[范围说明](performance.md) | 小样本独立连接并发修改重开保留、取消/终止无发布；冻结副本在关闭源库后准备，未覆盖平台快照创建。未测规模时间/RSS/大 WAL、启动清理及 picker/worker/UI，不升级整体状态。 |
| A18 | source 回执稳定、keep 后再改、合并重导：**PARTIAL** | [回执日志](../../artifacts/development/import-receipts-tests.log)、[业务工作流用例](../../packages/supplier_core/test/business_workflow_test.dart)、[导入协议说明](../implementation/business-import-contract.md) | 供应商合并后同源重导、多操作回执的完整产品界面联合验证。 |

## 平台与证据边界

| 范围 | 状态 | 说明 |
| --- | --- | --- |
| macOS 宿主 Dart/native SQLite、Flutter 测试运行器 | PASS（限定范围） | 核心 435/435、应用 113/113 及双方 analyze 通过；无 macOS target，不代表 macOS 安装包或设备集成验收。 |
| Chrome 存储/锁/恢复端口探针 | PASS（限定范围） | 上述 JSON 报告明确记录 OPFS/IndexedDB、进程重开、锁及恢复；不能推导全部产品 UI、离线缓存或文件选择链路通过。 |
| Chrome 正式业务/同步适配器真实文件链路 | PASS（限定范围） | [E2E 报告](../../artifacts/development/web-exchange-smoke.json)：真实 OPFS XLSX/ZIP、取消/损坏输入无回执、进程重开和幂等重试；绕过系统 chooser，未覆盖 UI 点击路径。 |
| Chrome 业务导入/完整同步 UI（注入文件句柄） | PASS（限定范围） | [界面报告](../../artifacts/development/web-exchange-ui-injected.json)与[截图](../../artifacts/development/web-exchange-ui-injected.png)：实际 Flutter 页面完成映射、逐行决定、业务提交、同步包导出/预览/提交；重启后两项任务卡和两份 OPFS 备份可见。打开/保存句柄由测试注入，不代表原生选择器。 |
| Chrome 原生系统文件选择器 | BLOCKED | [真实 picker 尝试](../../artifacts/development/web-exchange-ui.json)调用了系统选择器，但自动化无法选中文件；后续注入句柄测试不解除此门。 |
| Chrome 任务安全备份重开 | PASS（限定范围） | [适配器 E2E](../../artifacts/development/web-exchange-smoke.json)验证业务与同步任务的备份 locator 进程重开后可读、提交前修订数符合预期、重试同回执；不是完整 UI 恢复验收。 |
| Chrome 大文件取消反馈 ≤2 秒 | BLOCKED | 已有解析取消实现及宿主测试；未完成真实浏览器大型文件时延验收。 |
| Chrome 完整内存/泄漏门 | BLOCKED | runtime 报告 PASS 范围不包括此门；worker 数由 5 增至 9，尚无足够证据判断生命周期与总内存满足要求。 |
| 真实 Excel/WPS 正式业务文件修改回流 | BLOCKED | [WPS 7.5.1 尝试](../../artifacts/development/office-roundtrip-wps-attempt.json)可启动但 AppleEvent 文档/窗口访问超时（-1712）；副本未发生字节变化，未验证保存/正式回流。Excel 也无本轮完整往返证据。 |
| Android / Windows | DEFERRED | Android 默认应用支持目录已接入 `path_provider`，但用户延期的实际安装、文件交互、生命周期与持久化验证未执行，不据共享 Flutter 代码或目录测试宣称通过。 |

本轮最终日志已落盘；上表仍未执行的场景保持 PARTIAL/BLOCKED，不能仅依据总测试数改为 PASS。发布动作按[检查清单](../release-checklist.md)执行。
