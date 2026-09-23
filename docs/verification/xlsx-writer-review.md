# XLSX 单卷写出基础组件独立审查

日期：2026-09-18。**APPROVE，仅单卷 writer 与发布基础组件。**

## Code Review Summary

**Files Reviewed:** 5  
**Total Issues:** 0 unresolved

### By Severity

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0

## 范围与发现闭环

完整审查 `packages/supplier_core/lib/src/exchange/xlsx_writer.dart`、`test/xlsx_writer_test.dart`、`lib/supplier_core.dart` 的新增导出，以及 `apps/supplier_app/tool/web_xlsx_writer_smoke.dart`、`web_xlsx_writer_test.py`。生产 reader、staging、既有 ZIP 限额与已锁定 archive 库的输出/编码路径作为上下文；本次没有修改这些实现。

关闭一项 LOW：原 worksheet name 允许原始 CR/LF/tab，写入 XML 属性后可能因标准属性空白规范化改变名称。最终 `xlsx_writer.dart:63` 按受限名称 profile 明确拒绝三者，新增三条独立回归；未引入宽泛兼容或静默替换。

## 核对结果

所有非 null 单元格写为 inlineStr/text style，公式外观保持文本，金额、编号与 UTC 字符串不经过浮点/日期转换。null 与空字符串保持不同 cell kind；列宽错误明确失败。XML 字符检查、UTF-16 上限及单次 ST_Xstring 解码对应的编码保持词法，包括重叠 `_x005F_x0041_`、CR/LF、组合字符和前导零。

默认同步策略最多 5000 数据行，表头另计；普通受限策略要求显式行预算，两者均不能提高 8 MiB 压缩、32 MiB 实际展开、2048 entries 的字节/条目上限。输出为六个固定 ZIP parts；worksheet 和 ZIP 写入路径分别计量实际字节，包括 XML 转义和 ZIP 目录。没有将声明大小替代实际累计，也没有失败后放宽策略的回退。

只有完整 ZIP 经正式 reader 验证、文件 SHA/counts 一致，再通过有界 SQL 分页重新计算坐标/kind/lexical 摘要成功，才返回私有构造的 volume。输出范围至多 64 KiB 且复制字节，调用者不能修改已验证内容。`publishTo` 从调用起拥有 target：写入、取消或发布失败均尝试 abort，并保留原异常/stack 与清理异常/stack。encode 本身不接管调用者预先打开的 target，此责任已明确文档化。

barrel 仅增加本组件所需类型出口；33 列 quotation 模板包含 payload 与四项非权威匹配提示，没有将提示升级为同步身份或业务写入授权。

## 验证来源

- 独立执行最新 `dart test test/xlsx_writer_test.dart --reporter expanded`：**25/25 PASS**，包含三项名称回归、真实 5000 行边界、实际压缩/展开限额、取消、源失败、发布失败、双异常和 sink mutation。
- 独立执行 writer、barrel、test 的 `dart analyze`：**No issues found**。
- 阅读实现者 `xlsx-writer-web-smoke.json` / `xlsx-writer-web-run.log`：**7 Chrome cases PASS**，实际 OPFS 发布后正式 reader 读回；完整浏览器重启后再次验证的是持久 staging 内容，导出临时文件在重启前已 dispose，不能称为该导出文件跨重启存留测试。最后三项名称拒绝仅 VM 重跑，未声称 Chrome 再次覆盖。
- 阅读 Web smoke scoped analyze：clean。独立以 Python ZIP CRC 与标准 XML parser 检查 `business-export-v1.xlsx`：六 entries、所有 parts 可解析、两行各 33 cells、无公式节点、2704 bytes，SHA 与 `xlsx-writer-artifact.json` 一致（`6633e6048097a2c0e9f33b2e7882cdc9f32b5f74c8c2b9ece28ffc249f7d5677`）。这不是新 Excel/WPS 编辑回流测试。

本实现保留一个有上限的 worksheet/volume；32 MiB 展开限制不是峰值内存承诺，压缩一个受限 entry 期间也不能逐指令取消。自动分卷、全量普通大文件导出、外层 bundle 流、业务快照/导出服务、任务/回执/UI 集成及新 Excel/WPS round trip 均不在本轮结论内，不据此宣称 T7 完成。

### Recommendation

**APPROVE — 当前限定范围无未解决发现。**
