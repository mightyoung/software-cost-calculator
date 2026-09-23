## Code Review Summary

独立审查角色：code-reviewer。结论仅覆盖阶段 0 隔离小样，不代表正式业务系统、完整同步协议或全部目标平台已验收。

**Files Reviewed:** 14（小样 12 个手写源码、测试、配置及说明文件；阶段 0 增补与有界清理说明 2 个上下文文件）。另外检查实际 WPS 保存 fixture 和依赖解析器源码用于故障定位。
**Total Issues:** 0 unresolved（本轮发现的 HIGH 1、MEDIUM 1 已修复并独立复验）。

### By Severity

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0

### Issues

无未解决代码问题。已关闭的问题：

- 原 HIGH：`lib/xlsx.dart` 只检查 cell 坐标，未检查父 row 坐标。把报价数据行 r=2 改为 r=0 后，旧代码导入成功但 quotations 为空。最终版本在库解析前拒绝缺失、零、超界、重复父行号，以及父子行号不一致；只变报价数据行的回归覆盖这些情况。独立原始复现 `/private/tmp/supplier-review-rowzero.xlsx` 现在 exit 255，定位 sheet5 行号错误，未进入业务恢复。
- 原 MEDIUM：单段 inlineStr 中的 CRLF 被 excel 4.0.6 改为 LF。最终版本显式拒绝此已知解析器限制并记录于 README，不改变业务文本规范。独立原始复现 `/private/tmp/supplier-review-crlf.xlsx` 现在 exit 255，明确定位 sheet5.P2；回归只改业务 P2，保持标题及 manifest 有效。

### Specification and root-cause checks

项目名称、文本项目编号、UTC 毫秒询价时刻及原偏移、地点、询价人均进入完整报价快照；项目不作唯一键，也不引入用户实体。金额和数量使用精确十进制文本；联系人快照、引用约束、空库恢复、事务回滚、nullable 迁移均有实现及验证。未加入正式 DAG 合并或普通 Excel 筛重的虚假成功路径。

Web 非安全持久模式禁用业务写入及下载，错误显示为 FAIL。导入在解析前限制 ZIP 实际展开量、校验行号、拒绝公式、合并单元格与非文本值；异常不会转换为成功默认值。SQL 数据使用参数绑定，未发现硬编码凭据、动态业务 SQL 拼接或 HTML 注入路径。

WPS 兼容边界已核对：原始 ZIP 和原始单元格先校验，只从内存副本的样式直接声明中移除未被 cellXfs 直接或 xfId 继承使用的 41–44 内置格式声明；其它低编号、直接/继承使用及数字单元格显式拒绝。源文件和业务单元格不变，README 说明 excel 4.0.6 限制，真实 WPS 文件与四种负向变体均有回归。此为有依据的窄版本兼容处理，不是捕获任意失败后重试的宽泛回退。

有界清理计划及回退分类合理，无需为了清理增加重构。独立审查发现后的修复属于正确性修复，应由主报告区别于原“无改动清理检查”记录。

### Validation

在最终冻结源码上独立运行（Dart 3.13.3，PUB_CACHE 使用隔离工具链缓存）：

- `dart analyze`：No issues found，exit 0。
- `dart test`：19 tests passed，exit 0。覆盖真实 WPS 文件及兼容边界、建库/升级 DDL 与版本回滚、合并单元格、Unicode、CRLF、父行坐标、完整快照、时区、精确金额、SQLite 重开及导入回滚。
- `git diff --check`：exit 0；新文件内容另已直接检查。

最终核心 SHA-256：

```text
lib/database.dart 196b486cd906328407c3cc2aee30b6c31c9d08caa180ba7ed3cb1448b1a80f0b
lib/model.dart ef8dfb78784ce202dfce7a5a46025fc9db4dbbfeb9e220c0a9ab2deb3eed2e95
lib/xlsx.dart 0e034a6df828da9affbeb8fc4649e44070b7928390cbfb65c245bbaa1409ac8f
test/probe_test.dart 9ae6c530e817870d1f7afdc33e56632aa305676c686a51c58bfc0076e4bd977d
web/main.dart 066c634bf766dd56a03016c4850271dc44f70f788823042b4ec8661d0e78bce4
bin/probe.dart 052f87dca1f7e00592a3643df60c9836ba22225de55bd38540f25c0aae505230
```

### Recommendation

**APPROVE — code-reviewer lane，限阶段 0 隔离小样。**

不阻断以明确平台缺口交付小样。Windows/Android/iOS 实机、目标浏览器持久性、Microsoft Excel、容量极限与正式同步预算的覆盖范围须由主报告逐项如实记录；本审查未替代这些验收，也未提供 Architect lane 的批准。
