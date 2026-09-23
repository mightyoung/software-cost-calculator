# T11 规模与故障验证

更新：2026-09-23。**整体状态：PARTIAL（10 万查询与独立 oracle 已通过，完整规模链路尚无完成结果）**。
本记录覆盖当前 macOS 宿主机上的 Dart/native SQLite。Android、Windows 实机验证按用户决定延期；不能据此记录通过。

## 范围与可复现命令

当前 `.omx/plans/test-spec-supplier-ralplan.md` 的规模条款编号是 **A15**；A16 是原生平台环路，A17 是并发导出快照，I05 是展开量/长字符串/单行/空间失败边界。

以下保留 2026-09-21 的历史命令与结果；其中 10 万样本当时中断/受空间门阻断，不能将对应 oracle 命令视作已通过。命令从 `packages/supplier_core` 执行；重跑必须使用不存在的新输出目录，工具不会覆盖旧基准库。2026-09-23 完成批次的实际命令与 oracle 结果见下方新报告。

```sh
export PUB_CACHE=/private/tmp/supplier-inquiry-toolchain/pub-cache
export XDG_CONFIG_HOME=/private/tmp/supplier-inquiry-toolchain/config
export PATH=/private/tmp/supplier-inquiry-toolchain/flutter/bin:$PATH
dart test test/large_data_test.dart --reporter expanded
dart analyze tool/run_benchmarks.dart test/large_data_test.dart
dart run tool/run_benchmarks.dart --mode=query --count=10000 --out=../../artifacts/benchmark/query-10000-r2-20260921
python3 tool/verify_evidence.py ../../artifacts/benchmark/query-10000-r2-20260921
dart run tool/run_benchmarks.dart --mode=query --count=100000 --out=../../artifacts/benchmark/query-100000-20260921
python3 tool/verify_evidence.py ../../artifacts/benchmark/query-100000-20260921
dart run tool/run_benchmarks.dart --mode=deep --depth=10000 --out=../../artifacts/benchmark/deep-10000-20260921
dart run tool/run_benchmarks.dart --mode=strings --count=5000 --length=4000 --out=../../artifacts/benchmark/strings-5000-4000-20260921
dart run tool/run_benchmarks.dart --mode=strings --count=5000 --length=8192 --out=../../artifacts/benchmark/strings-5000-8192-20260921
```

最后一个命令是有意超过当前 32 MiB 展开量适配边界的失败样本，预期非零退出，不代表普通大工作簿已支持。报告记录实际错误，不预填通过。

工具现有空间门：先用 `df -Pk` 读取输出位置的可用空间；查询库按每报价 24 KiB（高于本次实测约 19.6 KiB）估算，再保留同等大小 journal 和临时工作空间，合计加 20%。10 万样本需要 **8,847,360,000 bytes（8.24 GiB）**；2026-09-21 清理旧查询数据库后仅有 **3,408,764,928 bytes（3.17 GiB）**，当时在生成前返回 `BENCHMARK_SPACE_BLOCKED`。2026-09-23 新批次开始时可用 **30,427,164,672 bytes**，已通过空间门并完成查询验证；旧空间阻断不再代表本轮查询状态，也不证明完整导入/导出链路有足够空间或已通过。

该门限是保守启动估算，不是实际磁盘满实验，也不保证其他进程不会随后占用空间。深链按每修订 8 KiB 估算；字符串按原始字符数四倍估算；主库估算最小 64 MiB，各模式同样加 journal/temp/20%。

`tool/run_benchmarks.dart` 复用既有固定种子 `641921` 查询 fixture。1 万报价伴随 5 万修订；10 万报价伴随 50 万修订。供应商/产品/联系人分别是报价数的 10%/20%/20%，每条报价有 4 或 5 个修订。该工具直接构建结构及投影，使用 `synchronous=OFF`，因此只证明查询/扫描，不能作为产品导入、提交、恢复或持久性吞吐证据。

查询全遍历使用 200 行 keyset 页；摘要增量 SHA-256，不保存全库 ID 集。独立 Python oracle 使用 SQLite 游标逐行验证 envelope 哈希及完整摘要，并以 payload 十进制整数/百万分之一独立排序（不使用生产 `price_key`）核对全部报价 ID 顺序。Python 缓存 8 MiB、排序临时表落盘，最多保留一行。

深链样本通过真实 `CommitCoordinator.commitStaged`，每 200 条写暂存事务，只保留上一个修订 ID。最终验证总数、唯一头和重开后的头存在；未用内存图 oracle。工具可配置 `--depth=500000`，是否实际运行另行记录。

共享字符串样本的每个值以唯一序号开头，其余是重复填充，逐行核对精确文本；这是可压缩的唯一长文本样本，未覆盖高熵不可压缩字符串。构建单卷夹具有独立固定 40 MiB 内容上限。夹具本身在内存中构造，**计入 RSS**；不把它称为流式大文件生成器，也不推导当前受限 XLSX 适配器能解析任意大工作簿。

## 当前结果

环境：macOS 26.5.2 (25F84)，8 逻辑处理器，Dart 3.13.3 macos_arm64，SQLite 3.53.4，`journal_mode=delete`。机器并非隔离性能实验室，其他开发任务可能运行；数据是此次宿主机观察值。新报告保存依赖锁文件及关键实现文件 SHA-256、开始/结束源码摘要、Git HEAD、命令和日期；早期深链报告尚无源码摘要，应以当前工具重跑补充来源。

| 样本 | 实测结果 | 证据 |
| --- | --- | --- |
| 分层回归 | 5/5 PASS：257 修订深链、257×4096 unique strings、32767 接受、32768 拒绝并隔离重开、夹具分配上限 | `test/large_data_test.dart` |
| 1 万报价 / 5 万修订 | 完整扫描 19.205 s；全部报价分页 1.128 s；Python 独立摘要/排序一致 | `artifacts/benchmark/query-10000-r2-20260921/{report,oracle,generation}.json` |
| 1 万报价查询 | 3 次预热、20 次前 50 项；p95 history 1.985 ms、price 2.243 ms、prefix 7.588 ms、contains 7.302 ms，均满足各自 500/2000 ms 门限 | 同上 |
| 1 万报价进程内存 | 519.6 MiB 峰值 RSS，包含同进程生成、扫描、查询及 native SQLite；低于本机观测使用的 1 GiB 对照门限 | 同上 |
| 1 万单实体修订 | 暂存生成 4.617 s，真实提交 7.267 s，唯一最终头及重开通过；峰值 364.6 MiB | `artifacts/benchmark/deep-10000-20260921/report.json` |
| 10 万报价 / 50 万修订（2026-09-21） | 历史 BLOCKED；首次生成至最后日志 3 万报价/18.5 万修订时因空间不足主动中断，exit 130；当时新增空间门在生成前拒绝 | `artifacts/benchmark/query-100000-20260921/interrupted.json`、`query-100000-console.log`、`query-100000-space-gate-20260921/report.json` |
| 10 万报价 / 50 万修订查询（2026-09-23） | PASS；全修订扫描 250.026 s；全部报价分页 16.093 s，最大扫描页 200；独立 oracle 核对 50 万修订及 10 万报价排序一致 | [report.json](../../artifacts/benchmark/query-100000-20260923/report.json)、[oracle.json](../../artifacts/benchmark/query-100000-20260923/oracle.json)、[generation.json](../../artifacts/benchmark/query-100000-20260923/generation.json) |
| 10 万报价查询时延（2026-09-23） | 3 次预热、20 次前 50 项；p95 history 2.470 ms、price 3.206 ms、prefix 64.711 ms、contains 62.046 ms，全部满足各自 500/2000 ms 门限 | 同上；oracle 的 `query_targets_failed` 为空 |
| 10 万报价进程内存（2026-09-23） | 峰值 RSS 511,623,168 bytes（约 487.9 MiB）；包含同进程生成、扫描、查询和 native SQLite。数据库 1,965,375,488 bytes，总运行 933.391 s | 同上；这是结构查询 fixture，不是产品写入吞吐或持久性成绩 |
| 5000 unique strings × 4000 字符 | PASS；5001 行含表头/5000 个 shared strings 精确核对；解析 10.776 s；峰值 632.7 MiB | `artifacts/benchmark/strings-5000-4000-20260921/report.json` |
| 5000 unique strings × 8192 字符 | 预期拒绝已观察；工具记录 FAIL/exit 1，`CORRUPT_VOLUME: expanded limit or invalid local header`；802 ms、峰值 488.6 MiB。声明展开量已经超限，是 ZIP 结构预检拒绝，不能单凭此证明虚报大小保护 | `artifacts/benchmark/strings-5000-8192-20260921/{report.json,failure.txt}` |

2026-09-21 回归命令 `dart test test/large_data_test.dart --reporter expanded` 的原始日志为 `artifacts/benchmark/large-data-tests.log`（5/5 PASS）；新增工具/测试静态分析 `dart analyze tool/run_benchmarks.dart test/large_data_test.dart` 为 `artifacts/benchmark/analyze.log`（No issues found）。`python3 -m py_compile tool/verify_evidence.py` 通过，独立 oracle 已在完成的 1 万报价库上实际执行。

2026-09-23 查询执行的[控制台日志](../../artifacts/benchmark/query-100000-20260923-console.log)与[独立 oracle 日志](../../artifacts/benchmark/query-100000-20260923-oracle.log)均已保留。oracle 仅保留一行，SQLite 缓存 8 MiB；完整修订摘要为 `083745fb860d66132f3f9748724be782400629fe9a503e08b184e8ba7b4ce045`，报价排序 ID 摘要为 `2876e4706249451275be10f73712fbee978b0ece34ed6d0dc2c6141e8a89092f`，均与生产查询报告一致。

另运行既有 `dart test test/bounded_zip_test.dart --reporter expanded`，日志 `artifacts/benchmark/bounded-zip-tests.log`，覆盖恶意缩小声明后的真实解压超限拒绝；未修改这些现有测试。

2026-09-21 为释放共享磁盘，仅删除该批次生成的已验证/失败/中断查询 SQLite 和中断 journal，保留 JSON/日志/摘要。准确路径及大小列在 `artifacts/benchmark/fixture-cleanup.md`。这些旧批次重新运行 Python oracle 需要先用固定 seed 重新生成到新目录；该历史清理记录不表示 2026-09-23 新数据库已删除。

峰值使用 `ProcessInfo.maxRss`，是整个 Dart 进程的 OS RSS 高水位，包含 native 分配，非 Dart heap。无法分解为各环节独立峰值，不推导 Web page/worker/WASM 总内存。首轮查询基准使用 `/usr/bin/time -l` 时，macOS 沙箱禁止 `sysctl kern.clockrate`，生成已完成但计量包装失败；原 `query-10000-20260921` 的 FAIL、time 日志保留。后改为生成与验证同进程，重新生成并验证，未把首次失败掩盖为通过。

## A17 小样本并发与终止

[2026-09-23 报告](../../artifacts/benchmark/a17-concurrency-checkpoint-20260923-v2/report.json)为 **9/9 PASS**：9 个真实 XLSX 分卷，在第 1/5/9 卷分别执行 complete、cancel、实际 SIGKILL。原生 SQLite 独立连接的并发修改重开后均保留；complete 发布成功，cancel/SIGKILL 均未发布。每项记录 frozen generation 1、active generation 2，快照与活动库各 589,824 bytes，观测 WAL 为 0。

这是小样本宿主文件目标验证，不测时间/RSS或大 WAL 上界。冻结副本在关闭源库后准备，未覆盖平台快照创建流程；未走系统 picker、浏览器 worker 或原生 UI。SIGKILL 可能留下私有临时文件，本次未验证启动清理。**A17 整体仍为 PARTIAL**，不能将这 9 项外推为规模/平台通过。

## 未满足的验收与停止条件

- A15：10 万报价/50 万修订的结构查询、遍历和独立 oracle 已通过。[正式全链路原运行](../../artifacts/benchmark/full-chain-100k-20260923/INTERRUPTED.md)完成源库提交与备份，但在隔离恢复期间因执行会话中断而终止，无最终报告；源库已独立核验 50 万有效修订、10 万报价和正式回执。正在从不可变源库及备份[分进程续跑](../../artifacts/benchmark/full-chain-100k-resumed-20260923/report.json)，其报告不得当作不中断的总耗时。完整导出/恢复仍未标 PASS；原正式导入已明显超过桌面 ≤10 分钟目标。单实体 50 万深链尚未运行，1 万深链结果不能外推。
- A17：上述第 1/5/9 卷小样本并发写、取消、SIGKILL 已通过；平台快照创建、规模时间/RSS/WAL、启动清理和实际产品文件交互仍缺证据。
- I05：真实磁盘满未执行。浏览器恢复链路已用 Chrome CDP 将站点配额实际压到 1 byte 并观察 `QuotaExceededError`，原库与回执保持，证据见 `artifacts/development/web-restore-smoke.json`；该受控配额故障不等于完整分卷交换的配额耗尽，也不能替代真实介质耗尽。
- Web 正式适配器的真实 OPFS 业务表/同步包、取消/损坏输入无回执、进程重启后安全备份定位读取和同回执重试已 [PASS](../../artifacts/development/web-exchange-smoke.json)。这是小样本功能链路；原生文件选择器被绕过，不能代替[受阻的 Flutter UI picker 链路](../../artifacts/development/web-exchange-ui.json)、大规模交换、总内存、首屏、进度或大文件取消 ≤2 秒验证。
- Excel/WPS 保存与回流仍 BLOCKED。[WPS 尝试记录](../../artifacts/development/office-roundtrip-wps-attempt.json)确认 macOS WPS 7.5.1 可启动且版本查询成功，但 AppleEvent 文档/窗口操作在 5–10 秒内超时（-1712）；副本与源文件字节相同，未证明实际保存或正式回流。Android/Windows 原生环路继续按用户要求 DEFERRED。

仅当上述未延期门槛都有新鲜证据才能把 T11 整体改为 PASS。报告 `status=PASS` 表示该模式的执行/正确性校验通过；必须另查 `queries.*.meets_target` 和整体覆盖，不能据单个报告解除发布门槛。
