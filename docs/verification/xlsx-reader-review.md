# T7 有界 XLSX reader / staging 独立审查

日期：2026-09-18。**APPROVE，仅有界读取与隔离暂存基础，不代表完整 T7 完成。**

## Code Review Summary

**Files Reviewed:** 8（含下方追加实物 probe）  
**Total Issues:** 0 unresolved

### By Severity

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0

## 范围与依据

生产范围为 `packages/supplier_core/lib/src/exchange/xlsx_reader.dart`、`xlsx_staging.dart`；读取完整对应 `test/xlsx_reader_test.dart`、`xlsx_staging_test.dart` 和 `test/support/xlsx_fixtures.dart`。另外审阅 `apps/supplier_app/tool/web_xlsx_smoke.dart`、`web_xlsx_test.py` 的浏览器断言及证据来源。现有 bounded ZIP 和 business mapping 仅作为调用上下文，不扩大本轮批准范围。

依据批准 PRD 的 XLSX 工作集决策、T7 原始词法/类型及有界 shared strings 要求，以及测试规格 I05 和资源边界。默认策略为 5000 数据行加一表头，实际 row 元素计数；显式 `maxDataRows` 不放宽 8 MiB 压缩、32 MiB 展开、2048 ZIP entries 边界，也不等于已经实现普通大工作簿适配器。

## 发现与关闭

1. **已关闭 HIGH：无效结构静默丢字。** 原标量 `v/f/t` 允许未知子元素，`1<garbage>9</garbage>2` 会变成数值词法 `12`；富文本 `is/si/r` 的未知内容也可能变空。现在标量拒绝子元素，业务文本容器检查允许子节点及非空裸文字；对应反例回归通过。
2. **已关闭 MEDIUM：宽松 XML 解析接受损坏实体/语法。** xml 6.6.1 默认对未知实体保留原文，原前置检查不足。现在严格检查实体、数值字符引用、XML 字符、属性赋值、QName、保留 namespace、注释和普通文字的 CDATA 终止符；DTD、错误嵌套、多个根及不支持命名空间明确失败。CDATA 内容与合法转义不被误当实体再次解析。此处是支持 profile 的显式边界，不声称完整 OPC/XSD 验证。
3. **已关闭 MEDIUM：SpreadsheetML 文本转义未解码。** shared、inline 和 `t=str` 现在按文本单元单次处理 ST_Xstring，`_x000D_` 保留 CR、`_x005F_x0041_` 保留字面 `_x0041_`，不递归变成 A；解码后仍执行长度与非法字符检查。规则来源为 [Microsoft ST_Xstring 说明](https://learn.microsoft.com/en-us/openspecs/office_standards/ms-oi29500/d34ae755-c53f-4a44-a363-c6dd3ee018a4)。

这些修复直接关闭解析边界，没有用失败后返回空值、吞异常或另一套解析器绕过原契约。审查中发现的 brace lint 也已由实现者修复。

## 核对结果

原始 `t`、style index、数值词法及 formula 分开暂存；空/shared formula 节点仍保留非 null 标记，缓存值不能作为 literal 导入。`t=d` 保持独立 date kind，现有映射明确拒绝无显式支持的转换。日期系统由 workbookPr 的严格布尔值提供；Strict OOXML 等非支持 namespace 明确失败，合并单元格拒绝。

暂存使用独立数据库，shared strings 落 SQL，内存缓存至多 32 条。row 元数据与 cell 分页分开，主键 seek、单页最多 200 条，不把宽行整行载入分页结果。单次解析事务结束前必须验证全部 ZIP entries，包括未选择资源的实际 CRC；`zip.verified` 和选中 worksheet 完成后才设置 ready。失败/取消不暴露解析结果，未完成暂存重开仍被隔离。取消 checkpoint 运行在调用者 Zone，避免进入暂存事务的 Drift 上下文，并保留原异常；清理失败保留 primary 与 cleanup 诊断。

读取没有构建 worksheet DOM 或全部 shared strings 列表，但仍持有有界 ZIP 和当前展开 entry/text。这里确认的是代码层面的固定单卷上界，不是峰值堆内存实测结论。

## 验证来源与限制

独立运行核心五文件 `dart analyze`：**No issues found!**。独立运行 `dart test test/xlsx_reader_test.dart test/xlsx_staging_test.dart --reporter expanded`：**43/43 PASS**，包含实际文件暂存重开、未完成隔离、分页、原始值、全部发现回归、取消原异常、默认/显式行预算及最后未选 entry CRC 失败不能发布前面行。

读取实现者生成的 `artifacts/development/xlsx-web-run.log` 和 `xlsx-web-smoke.json`：真实 Chrome OPFS SQLite **14 场景 PASS**，完整浏览器进程重启后 profile/raw cells/shared string 及行分页仍可读取。已核对 runner 的进程重启和对应断言；本审查通道没有另开或独立重跑浏览器。最后两个 brace 修正相对浏览器快照仅为格式变化。

未覆盖业务导入 coordinator、来源重选与消费摘要最终绑定、确认封存、预览 UI、收据事务、XLSX writer、WPS/Excel 真实编辑往返、普通大型工作簿、完整 bundle、多卷工作集或 T11 峰值内存。XML profile 不声称支持所有合法 SpreadsheetML 扩展。Windows/Android 设备验证按用户要求延期，不计本限定基础切片阻塞。

### Recommendation

**APPROVE — 仅上述有界 reader / staging 范围，无未解决发现。**

## 追加：现有 WPS 文件的窄扩展兼容

同日追加复核 `xlsx_reader.dart`、定向测试及浏览器 smoke 的增量，并读取/独立运行 `artifacts/development/xlsx-existing-smoke.dart`。实际触发扩展的是 `artifacts/supplier-probe/supplier-wps-roundtrip.xlsx`，不是无该扩展的 `supplier-sample.xlsx`。

兼容仅覆盖两条结构明确的非业务元数据路径：

- `workbook/extLst/ext` 的 URI `{B58B0392-4F1F-4190-BB64-5DF3571DCE5F}`，且内容只能为 2018/calcfeatures namespace 的 `calcFeatures/feature`；feature 仅允许非空 name 属性。
- `styleSheet/extLst/ext` 的 URI `{EB79DEF2-80B8-43e5-95BD-54CBDDF9020C}`，且内容只能为 2009/9/main namespace 的空 `slicerStyles`，仅允许非空 defaultSlicerStyle 属性。子节点或非空文字明确拒绝，不声称支持切片器内容。

根位置、深度、完整 namespace 与 local name、属性集合均检查；扩展内不能塞入主命名空间的业务节点。离开扩展后立即恢复原命名空间限制。没有全局放行 namespace 或忽略未知子树，也不执行公式或放宽公式缓存规则。

`mc:Ignorable` 仅校验前缀绑定，不赋予跳过业务元素的权限；其他 MC 属性（包括 MustUnderstand、ProcessContent、Preserve* 和未知属性）明确 unsupported，AlternateContent 仍由命名空间边界拒绝。这是有限 profile，不是通用 MC 预处理器；[Microsoft MC 说明](https://learn.microsoft.com/en-us/office/open-xml/general/introduction-to-markup-compatibility)亦将兼容规则和 alternate content 视为需要解释的处理语义。本次窄兼容有明确外部格式边界、错误路径及正反回归，不是吞错后重试宽松解析。

**追加独立验证：59/59 VM PASS；核心五文件 analyze 无问题。** 新回归覆盖正确元数据、错误 URI/位置、主命名空间穿透、未知 QName、非空文字/样式内容、额外属性、MC 指令及 Ignorable 不能隐藏业务节点。独立实物 probe 两个文件均 PASS，均选择 quotations 表并精确断言 D2=`12.340001`、Q2=`000123-A`、R2=`2026-09-16T14:30:00.123+08:00`；不是只打印 profile。对应 SHA-256 分别为 `89e8b4ad5b1fbccd947db96fe55a901553de44eda692e57487e5118062f78e34`、`feaa65a30d6e433cbd83bd2507c9fe08d5239b6be06d1f49bb84022c485453fb`。

已读取更新后的实现者 Chrome 日志/JSON：**17 场景及完整浏览器重启重开 PASS**，并核对新增元数据、MustUnderstand、Ignorable 断言。本通道未另开浏览器。此证据是当前 reader 对已有实物的读取，不是本轮新执行 WPS/Excel 编辑往返；其余 T7、普通大工作簿和工作集实测边界不变。**追加范围 APPROVE，无新增未解决发现。**
