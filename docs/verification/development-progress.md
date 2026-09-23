# 实施进度

执行依据：`.omx/plans/prd-supplier-ralplan.md` 与 `test-spec-supplier-ralplan.md`，产品事实以 `docs/superpowers/specs/2026-09-16-supplier-inquiry-design.md` 为准。

用户于2026-09-17明确要求开始开发。旧交接 authorized:false 仅代表当时的规划任务，不阻止本次授权。旧设计、计划、原型与 golden 保持原样。

## 依赖与责任检查

| 任务 | 检查结果与当前状态 |
|---|---|
| T1 | 平台探针与工程壳已实现，基础实验部分通过；T1 BLOCKED，详见平台报告 |
| T2 | 领域/schema/公共契约与v2固定样例已实现并验证；T2 COMPLETE |
| T3 | 等T1+T2，不绕过能力门创建生产存储 |
| T4 | 等T3集成，完整图校验不由外键替代 |
| T5 | 等T4；统一锁序与原子恢复指针 |
| T6 | 等T4；查询必须有界 |
| T7 | 等T5+T6；双回执与一次确认事件 |
| T8 | 等T7；UI仅调用正式服务 |
| T9 | 等T4+T5+T7；同快照分卷与单事务 |
| T10 | 等T8+T9；冲突人工解决 |
| T11 | 等T10；真实规模及故障验证 |
| T12 | 等T11；三端真实安装/文件环路 |

| 共享面 | 生产者/消费者 | 执行决定 |
|---|---|---|
| core pubspec | T1/T2 | 集成负责人单独持有，领域代理不改依赖 |
| payload schema | T2领域/协议 | payload不重复保存实体ID，身份由envelope携带 |
| contracts | T2/T3/T4/T5/T7/T9 | 单一负责人；暂存提交不接受全量List |
| validator与事务 | T3/T4 | T3写框架，T4安装验证器后才放行业务写 |
| platform目录 | T1/T5 | T1完成后交接，当前不同时修改 |
| exchange目录 | T5/T7/T9 | 顺序开发，不并行改回执/提交逻辑 |
| UI服务调用 | T7/T8/T9/T10 | 服务冻结后实施界面 |

本次在现工作目录的独立 codex/supplier-implementation 分支实施，以保留未提交且已批准的计划和原型；不迁移或清理既有未跟踪文件。Ultrawork 缺少引用的 references/agent-tiers.md（已搜索安装目录）；使用当前可调用原生 executor 角色，不猜测缺失指南。App 不启动 tmux 工作流。

验收：core dart test + dart analyze；app flutter test + flutter analyze +可执行目标构建；平台缺失标 BLOCKED，不能标通过。阶段性单元通过不等于M1/M2/M3交付。

## 实施决策与审查

- T2 payload 不重复保存 ID，修订 envelope 拥有身份；完整图/引用存在性与实际历史导入权限仍由 T4 服务承担。
- 原生子代理额度拒绝新增审查者，改由领域作者审查协议/契约、协议作者审查领域，保持不同作者的审查边界。发现联系人快照内清空联系方式绕过确认，已补失败回归并修复。
- 真实 Chrome 测试揭示 Dart VM/Web 对 `1.0 is int` 的区别。整数参数统一接受有限、安全范围内数学整数并规范为 int；小数、NaN、无穷和超范围拒绝。金额保持严格十进制字符串。标准序列化仍输出整数词法，严格持久 envelope 通过字节重编码拒绝非规范词法。依据：[Dart 数字表示官方文档](https://dart.dev/resources/language/number-representation)。
- 扫描页在复制前检查上限；预览版本不以 generation 单独识别数据库。
- 旧三份 Ralplan 文档 SHA256 已与既有 handoff 逐项核对，均未改变。原型及旧 golden 未编辑。

## 本次最终验证

| 范围 | 结果 | 证据 |
|---|---|---|
| Dart VM 全内核 | 30 tests PASS | artifacts/development/core-tests.log |
| Chrome 真实浏览器核心规则 | 17 tests PASS | artifacts/development/core-browser-tests-verified.log |
| 核心静态分析 | No issues found | artifacts/development/core-analyze.log |
| v2独立固定向量 | Python验证通过，旧supplier-root摘要不变 | artifacts/development/core-golden.log |
| Flutter app | 5 tests PASS，analyze PASS，Web build PASS | artifacts/development/platform/ |
| T2交叉审查 | 已知清空漏洞与跨端整数问题修复；固定向量/长度边界缺口补齐 | 本记录及回归测试 |

Chrome核心测试覆盖领域、契约和无IO协议值测试；读取fixture文件的协议测试在VM执行，不能把17项说成浏览器运行了整个30项套件。测试组含多个字段边界断言，数量为测试框架报告的测试用例数。

尚未交付M1业务工作版。T1仍有真实设备缺失及数据库快照/恢复等未实现实验，按照批准计划停止在T3生产适配之前；T3至T12没有标完成。下一入口为平台报告的六类能力门，补全T1后继续T3仓储及T4验证器，不直接跳到可变CRUD界面。

代码保留在 codex/supplier-implementation 分支工作区，未提交或推送；旧计划、设计、README及原型未改动。原生子代理完成后不保持后台任务；工程壳预览仍可在本机8767端口访问。
