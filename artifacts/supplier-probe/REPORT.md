# 供应商询价系统：阶段 0 小样验证

2026-09-16。已交付可复用 Dart 核心、SQLite/Drift 存储、严格文本 XLSX 读写及 Web 技术验证页。此次完成的是本机可验证的小样工作；尚未完成全部平台验收和正式业务应用。

## 新增字段

项目名称、项目编号、询价时间、询价地点、询价人已进入报价完整快照；另存询价时区偏移以保留原本地时间。项目编号是文本且非唯一，不以项目或姓名自动去重。询价人无需用户账户，报价日期独立保留。旧库新增列为 null。

样本 `000123-A`、金额 `12.340001`、电话 `0013800000000` 经过存储与 WPS 往返后完全一致。询价时间数据库为 `2026-09-16T06:30:00.123Z` + 480 分钟，Excel 为 `2026-09-16T14:30:00.123+08:00`。

## 实际验证矩阵

| 环境/路径 | 结果与限度 |
|---|---|
| macOS 原生 Dart + SQLite | PASS：独立进程写入/重开、XLSX 导入另一个空库、三库四表逐值比较一致 |
| Codex 内置浏览器 | PASS：最终编译版选择 sharedIndexedDb，初始化后重新导航及刷新数据保留，共享 XLSX 往返一致；未测试浏览器退出/重启、存储驱逐 |
| WPS Office macOS | PASS：真实打开并本地另存，再经独立 openpyxl 检查文本类型、Dart 解码及新库恢复；全部业务值一致。无需登录，本地另存为可完成 |
| Microsoft Excel | BLOCKED：本机未安装；不能用 WPS 或库自测代替 |
| Windows | NOT RUN：当前不是 Windows 主机，未产出 Windows 应用 |
| Android | NOT RUN：虽有 Android SDK，但缺可用 Java Runtime；未构建或运行 Android 小样 |
| iOS | NOT RUN：只有 Command Line Tools，没有完整 Xcode；未构建或实机测试 |
| Flutter UI / Web 离线首次启动 | NOT IMPLEMENTED：交付为共享 Dart 核心和编译 JS 技术页，无产品壳、service worker、文件选择器集成 |

工具链：Flutter 3.47.4 携带 Dart 3.13.3；实际使用 Dart CLI。Drift 2.35.0、excel 4.0.6，确切依赖见小样 pubspec.lock。临时 SDK 位于 `/private/tmp/supplier-inquiry-toolchain/flutter`，不打包进仓库。

## 测试、审查与编码预算

- 最终 `dart analyze` 无问题，`dart test` 19/19，通过 Web JS 编译与差异空白检查。见 [验证记录](validation.txt)。
- 覆盖 nullable 迁移、DDL/版本原子性、精确十进制、时区/日历、非空库拒绝、导入故障后关闭重开及重试、真实 WPS 正向及负向兼容边界。
- 独立审查发现并修复父行号导致静默丢报价、CRLF 改写、Unicode 替换、合并单元格丢值及迁移部分提交问题。最终 [代码审查](code-review.md) APPROVE、[架构审查](architecture-review.md) CLEAR，仅限隔离小样。
- [清理检查](cleanup-review.md) 限定当前源码；未引入无依据重构。WPS 兼容仅处理未被实际单元格样式直接或继承使用的41–44号声明，原文件及业务单元格不改；其它变体明确拒绝。
- 既有 v1 golden 的修订/业务摘要重新计算一致，六份旧批准产物字节与哈希未改变。固定工作簿真实编码 9,586 字节，预算 B=1,088,266。最大单元格、转义及唯一字符串样本也满足编码字节≤B，见 [预算记录](encoder-budget.json) 和 [复现脚本](check_encoder_budget.dart)。其中转义压力样本 B 超过20MiB，按正式协议应拒绝准入；压力样本只验证编码器，不是合法同步包。
- 尚未覆盖正式 100供应商/500产品/1000报价基准、100000行规模、所有编码器极限组合、解析器峰值内存/耗时和多设备同步；上述结果不能证明预算 B 的全域保证。

## 交付与下一步边界

[运行方式](../../prototypes/supplier_probe/README.md) · [原始样本](supplier-sample.xlsx) · [WPS保存样本](supplier-wps-roundtrip.xlsx) · [独立值比较](independent-evidence.json) · [浏览器证据](browser-evidence.txt)

当前格式 `supplier-inquiry-stage0-snapshot`、schema2，只向空库恢复；重复导入非空库明确拒绝。尚未实现普通 Excel 映射/筛重、正式 DAG 合并、删除与冲突处理、聚合查询产品界面或完整备份机制。下一阶段应先用相同 fixture 完成 Flutter 四端存储与文件选择适配，再按独立正式协议实现同步。

工作以本地文件交付，未提交或推送。历史临时代理数量限制已解除，双角色独立审查已真实完成。

本次 Ultragoal：G001、G002-excel、G003 均 complete，严格质量门通过。[计划](../../.omx/ultragoal/goals.json) 与 [检查点账本](../../.omx/ultragoal/ledger.jsonl) 保留过程；[真实目标完成返回](../../.omx/ultragoal/evidence/goal-completion-result.json) 已记录，随后 get_goal 返回 null 也原样保留。这些状态仅对应本次隔离小样范围。目标运行约35分钟。
