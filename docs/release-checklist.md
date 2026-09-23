# 发布检查清单

更新：2026-09-23。当前定位为**开发候选**；尚未达到完整正式发布验收。[A01–A18 矩阵](verification/release-matrix.md)是各项状态与证据入口。

## 当前开发候选门

- [ ] 固定候选源码与依赖锁文件摘要，记录 Flutter/Dart、SQLite、浏览器版本和验证日期；后续变更需重跑受影响范围。
- [x] 核心静态分析与完整测试通过：[analyze](../artifacts/development/final-core-analyze.log)、[435/435 测试](../artifacts/development/final-core-tests.log)。
- [x] 应用静态分析与完整测试通过：[analyze](../artifacts/development/final-app-analyze.log)、[113/113 测试](../artifacts/development/final-app-tests.log)。这是宿主测试运行器证据，不是已安装原生应用验收。
- [ ] 本地工作流集成测试通过。当前未执行：仓库无 macOS target，且[运行日志](../artifacts/development/final-app-integration.log)报告 Web integration tests 不受支持；Android/Windows 继续延期。
- [x] [Web release 构建](../artifacts/development/final-web-build.log)与[隔离 Chrome 存储运行时](../artifacts/development/web-runtime-smoke.json)通过，限定为构建及 OPFS/IndexedDB 端口、重开和锁验证。
- [x] [Web 正式交换适配器 E2E](../artifacts/development/web-exchange-smoke.json)通过：真实 OPFS 业务表/同步包、取消与损坏输入无回执，进程重开后备份 locator 可读且重试同回执。系统 chooser 被绕过，此勾选不覆盖 UI。
- [x] [Web Flutter UI 注入句柄链路](../artifacts/development/web-exchange-ui-injected.json)通过业务映射、逐行决定、提交、同步包导出/预览/提交及重启后的两条任务卡和两份 OPFS 备份；[截图](../artifacts/development/web-exchange-ui-injected.png)保留。注入句柄不等于系统文件选择器。
- [x] [10 万报价/50 万修订查询](../artifacts/benchmark/query-100000-20260923/report.json)与[独立 oracle](../artifacts/benchmark/query-100000-20260923/oracle.json)通过；限定结构查询 fixture，不是完整交换/备份/恢复性能验收。
- [x] [A17 小样本 9/9](../artifacts/benchmark/a17-concurrency-checkpoint-20260923-v2/report.json)通过：第 1/5/9 卷分别 complete/cancel/SIGKILL，并发修改重开保留，取消/终止不发布。此勾选仅为宿主小样本，A17 整体仍 PARTIAL。
- [ ] 实际部署的完整产品链路、离线/升级及内存门通过。Chrome worker 数仍观测为 5→9；[真实 UI picker 尝试](../artifacts/development/web-exchange-ui.json)受自动化能力阻断，系统文件选择尚未验证；注入句柄的后续 UI 链路另有上述限定通过证据。
- [ ] 按[用户指南](user-guide.md)核对录入查询、业务表映射/预览/确认、完整同步、冲突/关联修复、备份恢复、任务继续与失败提示。
- [x] 最终代码与架构审查完成：code-reviewer **APPROVE**、architect **CLEAR**，由协调者汇总本轮审查回报，记录于[最终清理审查](verification/final-cleanup-review.md)。该结论不替代剩余平台、容量和产品交互验收。
- [x] Android/Windows 实机、安装、生命周期及跨端环路按用户要求标记 **DEFERRED**。当前不执行，也不记录为失败或通过。
- [ ] 对外提供候选时同时附带验收矩阵、已知限制、备份说明及产物摘要，明确其开发候选身份。

上述复选框只在对应最终证据落盘且核对后勾选。现有分层测试结果见矩阵，不据代码存在或口头观察提前勾选。

本轮已补齐 latest/供应商/联系人查询、复杂关联环修复、多分支删除/重定向冲突处理及并行重定向详情入口、解析取消、失败后同任务重试、备份失败中止输出及 Web 安全备份任务定位。同步工作流同时保留主错误与清理错误，避免清理失败覆盖根因。Android 默认目录已接入 `path_provider`；这些实现与宿主回归不解除浏览器端到端或原生实机验证门。

## 正式发布门

正式发布前，在未延期范围内关闭所有 PARTIAL/BLOCKED，并保留可复查证据：

| 门槛 | 实际执行与通过标准 | 记录位置 |
| --- | --- | --- |
| 表格软件往返 | 用真实 Excel、WPS 打开业务导出，修改价格/备注后保存并回流；核对前导零、长电话、六位小数、日期精度、空白保留、旧基线和回执 | [WPS 7.5.1 尝试](../artifacts/development/office-roundtrip-wps-attempt.json)已启动，但 AppleEvent 文档/窗口操作超时，实际保存与回流仍 BLOCKED；[A04/A06/A07/A18](verification/release-matrix.md)保留完整往返门 |
| 浏览器产品链路 | 实际界面完成文件选择、业务导入、完整同步预览/提交/导出及恢复；关闭浏览器后验证安全备份能通过任务持久位置重新读取，再核对完整数据 | [Web 运行时证据](verification/web-runtime.md)；注入句柄的 Flutter UI 映射、提交、同步与重启任务卡通过，正式适配器备份重开通过；系统选择器和完整 UI 恢复仍未验 |
| 离线与升级 | 已缓存后断网重开；更新页面、worker、WASM 资源版本；确认数据保留且资源不混用，降级模式禁写 | A14；现有存储探针不能替代 |
| 完整规模 | 10 万报价/50 万修订的查询、全量导入/导出/备份/恢复均比较完整摘要并测量时间和峰值 | [性能报告](verification/performance.md)；2026-09-23 查询及独立 oracle 已 PASS，原空间阻断为历史。full-chain-100k 另行运行、尚无完成结果，此发布门仍未通过 |
| 并发导出与中断 | 第一/中/末卷期间并发编辑、取消和终止；成功包来自同一快照，失败不公布半包，记录 WAL/临时空间 | [小样本 9/9](../artifacts/benchmark/a17-concurrency-checkpoint-20260923-v2/report.json)通过；关闭源库后准备冻结副本，尚未覆盖平台快照创建、规模时间/RSS/大 WAL、SIGKILL 后启动清理及 picker/worker/UI，A17 仍 PARTIAL |
| 故障与原子性 | 提交和恢复关键点终止后重开；仅见旧库或完整新库。另做受控磁盘满，核对旧库、回执与候选清理 | A10/A13；浏览器受控配额错误证据不代替物理磁盘满 |
| 交互时延 | 实测输入到首屏、进度首次显示、取消反馈；大型文件在真实浏览器中取消需 ≤2 秒。Web 同时披露 page/worker/WASM 内存观测范围 | A15 与性能报告；已有小型取消测试不能外推大型浏览器文件，不用截图或宿主 RSS 代替 |
| 发布复核 | 最终源码、测试日志、构建产物相互对应；矩阵逐项审阅，所有残留限制随候选公开 | 本清单与验收矩阵 |

Android/Windows 延期继续有效。若以后发布这些平台或宣称完整三端环路通过，必须重新纳入实际安装、重启、文件交互与 Windows→Android→Web→Windows 验收；Flutter 共用代码不构成这些证据。

## 停止与回退

出现数据摘要不一致、部分提交、无法恢复原库、成功提示与实际文件不符时，停止发布该候选。保留失败日志、输入文件、任务编号及原库；修复后重跑对应故障点和关联回归，再更新矩阵。不要删除失败记录来获得全绿结论。

本清单不含未经验证的复制粘贴命令；具体测试入口和已有运行记录见矩阵、性能与平台验证文档。执行记录应追加实际命令和结果，不把清单中的待办当作已执行。
