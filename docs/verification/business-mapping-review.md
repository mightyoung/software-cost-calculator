# T7 单元格映射基础独立审查

日期：2026-09-18。**APPROVE，限纯转换基础；不是 T7 完成或真实 XLSX 往返验收。**

## Code Review Summary

**Files Reviewed:** 2  
**Total Issues:** 0 unresolved

### By Severity

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0

## 范围与发现闭环

审查 `packages/supplier_core/lib/src/exchange/business_mapping.dart` 与 `test/business_mapping_test.dart`。依据批准设计 §3.2、§3.3、§6 的普通 Excel 转换规则以及测试规格 A03/A04/U02；同时读取现有 ExactDecimal、InquiryTime 和 normalizeText 作为行为上下文。

关闭一项 LOW：Excel serial 转换的最终 UTC 时间超出 9999 年时，原先直接传播 InquiryTime 错误，丢失单元格坐标。现仅包装该 FormatException 并附坐标；新增 `2958465.999`、offset -840 的回归确认错误包含 C7，未放宽日期边界。

## 核对结果

原始 cell kind、lexical 与 formula 独立保存；任何公式缓存、布尔值或错误值均不能冒充业务值。缺列、空白和值保持三态，数字零不会变空；数值型编号/电话明确拒绝猜测，文字编号保留前导零。构造时先验证 XML 字符再判空，非法控制字符不能被 trim 隐去；blank kind 携带非空词法值直接拒绝。

数值单元格科学计数法以有界字符串展开，ExactDecimal 执行 12 位整数/6 位小数和正数约束，未经过 double；原始数值词法、指数和输出位移均有门限。Excel 日小数以 BigInt 分子/分母计算，最近毫秒转换前的最终结果至多一天毫秒量，转 int 不涉及 JS 不安全整数。日期整数受支持日数上界约束，最终 DateTime 的毫秒范围也在 JS 安全整数内；本结论是源码数值路径核对，不代替浏览器执行。

1900 系统拒绝 serial 60 及其日内小数，1904 系统允许 0 并正确处理实际闰日。默认 date 转换只有日历日期；非零日小数不能被日期映射静默丢弃。instant 映射要求显式批次 UTC offset，保留本地日期及 UTC 时刻；不读取设备时区，拒绝舍入跨日与 UTC 年界越界。

Excel serial 的非整毫秒转换返回 `millisecondsRounded`，并以精确余数判定是否舍入。这是专门的序号转换预览路径，不放宽普通文本时间只接受 0–3 位小数秒的规则。**后续必须把转换结果和舍入提示实际呈现在预览，并绑定用户确认；后台保存 flag 本身不等于已告知用户。**

## 验证与边界

独立执行两文件 `dart analyze`：**No issues found!**；独立执行 `dart test test/business_mapping_test.dart --reporter expanded`：**13/13 PASS**。覆盖最大金额科学计数法、过精度、前导零、公式缓存、三态、两个日期系统、显式偏移、毫秒舍入/跨日拒绝、UTC 年界坐标和 XML/长度/空单元格约束。

本通道未另开浏览器，未把 VM 结果声称为独立 Chrome 运行。已读取主集成者 `artifacts/development/business-mapping-chrome.log` 的 **12/12 PASS**；该日志尚未包含新增 UTC 年界坐标用例，不冒称最终 13 项均已在 Chrome 通过。尚未接入 XLSX reader、ExchangeService、预览 UI、封存确认或真实文件往返；不证明工作簿样式识别、共享字符串解析、日期系统元数据来源、ZIP/XLSX 包级资源边界或完整导入事务。Windows/Android 设备验证仍按用户要求延期。

### Recommendation

**APPROVE — 仅上述纯映射范围，无未解决发现。**
