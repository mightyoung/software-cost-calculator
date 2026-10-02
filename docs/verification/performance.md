# T11 规模与故障验证

更新：2026-09-27。**整体状态：PARTIAL（10 万查询、当前版分进程全链路正确性与独立 oracle 已通过；性能和其余压力门槛未齐）**。
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

深链样本通过真实 `CommitCoordinator.commitStaged`，每 200 条写暂存事务，只保留上一个修订 ID。最终验证总数、唯一头和重开后的头存在；未用内存图 oracle。工具可配置 `--depth=500000`；本轮实测结果见下文。

共享字符串样本的每个值以唯一序号开头；默认其余为重复填充，`--string-pattern=high-entropy` 则用固定 SHA-256 种子生成 base64url 文本。两种模式均逐行核对精确文本。构建单卷夹具有独立固定 40 MiB 内容上限。夹具本身在内存中构造，**计入 RSS**；不把它称为流式大文件生成器，也不推导当前受限 XLSX 适配器能解析任意大工作簿。

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
| 5000 高熵 unique strings × 2000 字符（2026-09-27） | PASS；5001 行含表头/5000 个 shared strings 逐行精确核对；压缩体 7,771,029 bytes，解析 9.355 s；含夹具构造的进程峰值 494,829,568 bytes（约 472 MiB）；源码摘要前后一致。宿主 Dart 3.13.4；只覆盖该单卷边界内样本 | [report.json](../../artifacts/benchmark/strings-high-entropy-5000-2000-20260927/report.json) |
| 5000 高熵 unique strings × 4000 字符（2026-09-27） | 预期拒绝已观察；工具记录 FAIL/exit 1，`CORRUPT_VOLUME: compressed size exceeds volume limit`；未越过单卷默认 8 MiB 压缩上限，不能作为适配成功；4.298 s、峰值 496,107,520 bytes，源码摘要前后一致 | [report.json](../../artifacts/benchmark/strings-high-entropy-5000-4000-20260927/report.json) |
| 5000 unique strings × 8192 字符 | 预期拒绝已观察；工具记录 FAIL/exit 1，`CORRUPT_VOLUME: expanded limit or invalid local header`；802 ms、峰值 488.6 MiB。声明展开量已经超限，是 ZIP 结构预检拒绝，不能单凭此证明虚报大小保护 | `artifacts/benchmark/strings-5000-8192-20260921/{report.json,failure.txt}` |
| 1 万单实体修订（当前分页提交） | PASS；提交约 9.4 s，全程约 12 s，峰值约 509 MiB；与旧报告使用的提交分页配置不同 | [report.json](../../artifacts/benchmark/deep-10k-page200-20260924/report.json) |
| 50 万单实体修订（当前分页提交） | STOPPED；约 29 分 25 秒时仍在提交，未完成最终头与重开校验，不能据部分库判定正确性或性能达标 | [STOPPED.md](../../artifacts/benchmark/deep-500k-page200-20260924/STOPPED.md) |

2026-09-21 回归命令 `dart test test/large_data_test.dart --reporter expanded` 的原始日志为 `artifacts/benchmark/large-data-tests.log`（5/5 PASS）；新增工具/测试静态分析 `dart analyze tool/run_benchmarks.dart test/large_data_test.dart` 为 `artifacts/benchmark/analyze.log`（No issues found）。`python3 -m py_compile tool/verify_evidence.py` 通过，独立 oracle 已在完成的 1 万报价库上实际执行。

2026-09-23 查询执行的[控制台日志](../../artifacts/benchmark/query-100000-20260923-console.log)与[独立 oracle 日志](../../artifacts/benchmark/query-100000-20260923-oracle.log)均已保留。oracle 仅保留一行，SQLite 缓存 8 MiB；完整修订摘要为 `083745fb860d66132f3f9748724be782400629fe9a503e08b184e8ba7b4ce045`，报价排序 ID 摘要为 `2876e4706249451275be10f73712fbee978b0ece34ed6d0dc2c6141e8a89092f`，均与生产查询报告一致。

另运行既有 `dart test test/bounded_zip_test.dart --reporter expanded`，日志 `artifacts/benchmark/bounded-zip-tests.log`，覆盖恶意缩小声明后的真实解压超限拒绝；未修改这些现有测试。

2026-09-21 为释放共享磁盘，仅删除该批次生成的已验证/失败/中断查询 SQLite 和中断 journal，保留 JSON/日志/摘要。准确路径及大小列在 `artifacts/benchmark/fixture-cleanup.md`。这些旧批次重新运行 Python oracle 需要先用固定 seed 重新生成到新目录；该历史清理记录不表示 2026-09-23 新数据库已删除。

峰值使用 `ProcessInfo.maxRss`，是整个 Dart 进程的 OS RSS 高水位，包含 native 分配，非 Dart heap。无法分解为各环节独立峰值，不推导 Web page/worker/WASM 总内存。首轮查询基准使用 `/usr/bin/time -l` 时，macOS 沙箱禁止 `sysctl kern.clockrate`，生成已完成但计量包装失败；原 `query-10000-20260921` 的 FAIL、time 日志保留。后改为生成与验证同进程，重新生成并验证，未把首次失败掩盖为通过。

2026-09-24 的 2.5 万修订暂存 A/B 使用相同夹具和 200 行事务：[逐行报告](../../artifacts/benchmark/formal-import-5k-scalar-staging-v2-20260924/report.json)与[批量报告](../../artifacts/benchmark/formal-import-5k-batch-staging-20260924/report.json)分别为 4162/4166 ms，独立 oracle 均 PASS 且权威摘要一致。批量写入未显示收益，实验代码已撤回；生成库在 oracle 后按[清理记录](../../artifacts/benchmark/temporary-import-db-cleanup-20260924.md)删除。

## A17 小样本并发与终止

[2026-09-23 报告](../../artifacts/benchmark/a17-concurrency-checkpoint-20260923-v2/report.json)为 **9/9 PASS**：9 个真实 XLSX 分卷，在第 1/5/9 卷分别执行 complete、cancel、实际 SIGKILL。原生 SQLite 独立连接的并发修改重开后均保留；complete 发布成功，cancel/SIGKILL 均未发布。每项记录 frozen generation 1、active generation 2，快照与活动库各 589,824 bytes，观测 WAL 为 0。

这是小样本宿主文件目标验证，不测时间/RSS或大 WAL 上界。冻结副本在关闭源库后准备，未覆盖平台快照创建流程；未走系统 picker、浏览器 worker 或原生 UI。SIGKILL 可能留下私有临时文件，本次未验证启动清理。**A17 整体仍为 PARTIAL**，不能将这 9 项外推为规模/平台通过。

## 未满足的验收与停止条件

- A15：10 万报价/50 万修订的结构查询、遍历和独立 oracle 已通过。[正式全链路原运行](../../artifacts/benchmark/full-chain-100k-20260923/INTERRUPTED.md)完成源库提交与备份，但在隔离恢复期间因执行会话中断而终止，无最终报告。[分进程续跑报告](../../artifacts/benchmark/full-chain-100k-resumed-20260923/report.json)与[独立 oracle](../../artifacts/benchmark/full-chain-100k-resumed-20260923/oracle.json)均 PASS：源/恢复/重开摘要一致，50 万有效修订、10 万报价、123 卷、源与备份文件哈希在运行前后相同，源库无 WAL/journal/shm。续跑用时 145.6 分钟、进程峰值 RSS 约 0.49 GiB；其中备份恢复 44.7 分钟、导出及自校验 84.0 分钟。这是旧版本分进程全链路正确性证据，不能与中断前的导入拼成不中断总耗时。[当前版完整 10 万正式导入报告](../../artifacts/benchmark/formal-import-100k-current-uncapped-20260924/report.json)及[独立 oracle](../../artifacts/benchmark/formal-import-100k-current-uncapped-20260924/oracle.json)均 PASS：50 万修订、10 万报价、权威摘要、回执、SQLite 完整性一致；进程峰值 RSS 463,421,440 bytes。但暂存加提交耗时 **1345.6 秒**，超过桌面 600 秒目标；此轮只到源库摘要，未重跑当前版备份/恢复/分卷全链路。图重置与初始化至约 339.9 秒，拓扑至约 696.1 秒，安装与提交至约 1068.4 秒（均从图提交起算）。此前[限时轮](../../artifacts/benchmark/formal-import-100k-topology-fixed-20260924-time-gate.json)为 TIME_GATE_FAIL，确实在 600 秒内无法完成。[当前版 5 万正式导入](../../artifacts/benchmark/formal-import-50k-topology-fixed-20260924/report.json)及[独立 oracle](../../artifacts/benchmark/formal-import-50k-topology-fixed-20260924/oracle.json)也 PASS，暂存加提交 344.3 秒；两种规模的拓扑耗时分别约 36.3/356.2 秒，仍需定位超线性增长。当前版缓存对照见下项；两种缓存都未让 10 万样本达到 600 秒门槛。50 万单实体深链已尝试但中途停止，仍未完成。
- 缓存对照：[5 万、16 MiB 报告](../../artifacts/benchmark/formal-import-50k-cache16m-20260924/report.json)与[独立 oracle](../../artifacts/benchmark/formal-import-50k-cache16m-20260924/oracle.json) PASS，暂存加提交 254.3 秒、拓扑约 15.3 秒、峰值 RSS 565,821,440 bytes；相同当前版默认缓存的 5 万样本为 344.3 秒、拓扑约 36.3 秒、RSS 518,684,672 bytes。[10 万、16 MiB 限时轮](../../artifacts/benchmark/formal-import-100k-cache16m-gate-20260924-time-gate.json)仍为 TIME_GATE_FAIL，600 秒时只安装 31 万/50 万修订，图拓扑约 187.4 秒。[10 万、32 MiB 限时轮](../../artifacts/benchmark/formal-import-100k-cache32m-gate-20260924-time-gate.json)也失败，600 秒时只安装 3 万修订，拓扑约 248.6 秒。[10 万、64 MiB 限时轮](../../artifacts/benchmark/formal-import-100k-cache64m-gate-20260924-time-gate.json)也失败，600 秒时安装 22 万修订，拓扑约 209.2 秒；三轮中断均无最终摘要或 oracle。缓存增加改善了部分阶段，但未达到 600 秒门槛，也未改变产品默认配置。
- 拓扑元数据有界预取后，[5 万默认缓存报告](../../artifacts/benchmark/formal-import-50k-metadata-20260924/report.json)与[独立 oracle](../../artifacts/benchmark/formal-import-50k-metadata-20260924/oracle.json) PASS，暂存加提交 290.4 秒；但[10 万、16 MiB 限时轮](../../artifacts/benchmark/formal-import-100k-metadata-cache16m-20260924-time-gate.json)仍 TIME_GATE_FAIL，图拓扑约 193.4 秒，600 秒时仅安装 23 万/50 万修订，未产生最终摘要或 oracle。该优化在目标规模未呈现稳定收益，不据 5 万结果宣称性能门通过。
- 投影复用同一单头修订后，[5 万正式导入报告](../../artifacts/benchmark/formal-import-50k-projection-reuse-20260924/report.json)及[独立 oracle](../../artifacts/benchmark/formal-import-50k-projection-reuse-20260924/oracle.json) PASS，摘要与前述同规模轮一致；投影安装阶段由前一轮约 51.4 秒降至约 29.7 秒，暂存加提交为 238.1 秒。这是单次同配置对照，尚不足以推断 10 万性能门通过。
- 曾试验只在本次连接存在的图元数据 TEMP 缓存：[5 万报告](../../artifacts/benchmark/formal-import-50k-temp-metadata-20260924/report.json)与[独立 oracle](../../artifacts/benchmark/formal-import-50k-temp-metadata-20260924/oracle.json)虽 PASS，但暂存加提交增至 318.1 秒，图提交区间由前一轮约 150.7 秒增至 218.4 秒；实现已撤回，不作为当前版能力或性能证据。

最新投影复用版的[10 万正式导入报告](../../artifacts/benchmark/formal-import-100k-projection-reuse-uncapped-20260924/report.json)与[独立 oracle](../../artifacts/benchmark/formal-import-100k-projection-reuse-uncapped-20260924/oracle.json)均 PASS：50 万修订、10 万报价、权威摘要、回执与 SQLite 完整性一致；暂存加提交 **989.7 秒**，仍超过桌面 600 秒门槛。[正式备份准备](../../artifacts/benchmark/formal-import-100k-projection-reuse-uncapped-20260924/backup-preparation.json)PASS，源库文件前后哈希一致、备份 678,088,851 bytes。[当前版分进程全链路报告](../../artifacts/benchmark/full-chain-100k-projection-reuse-resumed-20260927/report.json)及[独立 oracle](../../artifacts/benchmark/full-chain-100k-projection-reuse-resumed-20260927/oracle.json)也 PASS：源库、恢复库及重开摘要一致，50 万修订、10 万报价、123 卷，输入与关键源码运行前后哈希一致；生产自校验覆盖 XML/投影，独立 oracle 覆盖 SQLite、回执与 ZIP 分卷。续跑缺原进程导入/备份计时，不能构成连续全链路时间证据；其导出阶段计时从日志约 1,473.5 秒跳至 65,392.2 秒，期间活动不可归因，不能作为可靠吞吐基准。桌面导入性能门及 Web 总内存等仍未通过。
- 2026-09-27 安装分页同版对照：[5 万、安装页 5000 报告](../../artifacts/benchmark/formal-import-50k-install-page5000-20260927/report.json)和[独立 oracle](../../artifacts/benchmark/formal-import-50k-install-page5000-20260927/oracle.json)、[安装页 200 报告](../../artifacts/benchmark/formal-import-50k-install-page200-control-20260927/report.json)和[独立 oracle](../../artifacts/benchmark/formal-import-50k-install-page200-control-20260927/oracle.json)均 PASS、摘要一致。安装区间分别约 40.0/63.8 秒，但图初始化及拓扑大幅波动，完整暂存加提交分别为 350.4/322.4 秒；只证明该次局部区间可能受益，不证明总性能改善或 10 万门槛通过。独立安装页参数保留为实验入口，默认仍为原 200 行。
- 有界 Drift 批量暂存实验：[5 万批量报告](../../artifacts/benchmark/formal-import-50k-staging-batch-20260927/report.json)和[独立 oracle](../../artifacts/benchmark/formal-import-50k-staging-batch-20260927/oracle.json)、[1 万批量](../../artifacts/benchmark/formal-import-10k-staging-batch-20260927/report.json)与[逐条对照](../../artifacts/benchmark/formal-import-10k-staging-control-20260927/report.json)及各自 oracle 均 PASS、同规模摘要一致。5 万写入事务 50.4 秒，高于近邻逐条轮的 18.9 秒；1 万为 3.64/3.06 秒。未观察到稳定收益，且运行期间未改阶段也明显波动；批量 API 与实验开关已撤回，正式路径保持逐条写入。
- 图拓扑 frontier 单独分页实验：[5 万默认 200 报告](../../artifacts/benchmark/formal-import-50k-topology-page200-control-20260927/report.json)、[1000 报告](../../artifacts/benchmark/formal-import-50k-topology-page1000-20260927/report.json)、[5000 报告](../../artifacts/benchmark/formal-import-50k-topology-page5000-20260927/report.json)及各自独立 oracle 均 PASS、摘要一致。拓扑区间分别约 24.8/53.4/52.2 秒；放大 frontier 未获收益，实验参数及测试改动已撤回，图校验保持原 200 行路径。
- 两阶段权威安装实验：[5 万报告](../../artifacts/benchmark/formal-import-50k-two-pass-20260927/report.json)、[1 万报告](../../artifacts/benchmark/formal-import-10k-two-pass-20260927/report.json)、[1 万单阶段对照](../../artifacts/benchmark/formal-import-10k-one-pass-control-20260927/report.json)及各自独立 oracle 均 PASS、同规模权威/业务摘要一致，源文件哈希前后一致。5 万两阶段正式 fixture 约 797.3 秒；1 万两阶段/单阶段安装区间约 11.8/24.7 秒，但对照的安装前图阶段约 56.8 秒，亦为两阶段轮 25.2 秒的 2.3 倍，机器状态显著漂移，不能归因为两阶段优化。实验开关与第二次扫描已撤回，默认单阶段路径保留；A15 的 600 秒门槛仍未通过。
- 权威安装内部计时：[1 万报告](../../artifacts/benchmark/formal-import-10k-install-steps-20260927/report.json)、[5 万报告](../../artifacts/benchmark/formal-import-50k-install-steps-20260927/report.json)和各自独立 oracle 均 PASS，源码哈希前后一致。1 万安装总约 7.46 秒，其中 `stagingPage` 5.25 秒；5 万总约 80.19 秒，其中 `stagingPage` 40.66 秒、实体/修订/父边 SQL 合计 38.96 秒，碰撞及回执查询不足 0.5 秒。重复读取不是可单独解释 100k 总耗时超标的瓶颈；这只是两次不同负载的单次观察，不可外推线性。临时计时钩子已撤回，报告保留定位证据。
- A17：上述第 1/5/9 卷小样本并发写、取消、SIGKILL 已通过；平台快照创建、规模时间/RSS/WAL、启动清理和实际产品文件交互仍缺证据。
- I05：[macOS 64 MiB HFS+ RAM 卷真实 ENOSPC](../../artifacts/benchmark/i05-native-disk-full-20260924-final/report.json)小样本 PASS：提交中途空间耗尽，重开后权威库未变，释放空间重试只有一份回执；原生备份失败未发布目标或残留私有文件，重试可解码；卷已卸载分离。高熵单卷 5000×2000 字符已在上限内通过，5000×4000 由压缩体门限拒绝；完整分卷交换配额耗尽、其他介质/平台和超门限文本的缩卷或拒绝产品流程仍未齐。浏览器恢复链路另用 Chrome CDP 将站点配额压到 1 byte 并观察 `QuotaExceededError`，见 `artifacts/development/web-restore-smoke.json`。
- Web 正式适配器的真实 OPFS 业务表/同步包、取消/损坏输入无回执、进程重启后安全备份定位读取和同回执重试已 [PASS](../../artifacts/development/web-exchange-smoke.json)。[小样本界面时延](../../artifacts/development/web-ui-latency-20260924-final.json)在 20 次预热后观测中，单报价查询首屏最大 105.385 ms、1 万重复行解析忙碌反馈最大 59.160 ms、取消反馈最大 56.310 ms；满足各自 1/1/2 秒门限，但语义节点加两帧只提供绘制机会，不能作为像素证据。文件选择器由测试注入；这些数据不能代替[受阻的系统 picker 链路](../../artifacts/development/web-exchange-ui.json)、10 万报价首屏、worker 退出或总内存验证。
- Excel/WPS 保存与回流仍 BLOCKED。[WPS 尝试记录](../../artifacts/development/office-roundtrip-wps-attempt.json)确认 macOS WPS 7.5.1 可启动且版本查询成功，但 AppleEvent 文档/窗口操作在 5–10 秒内超时（-1712）；副本与源文件字节相同，未证明实际保存或正式回流。Android/Windows 原生环路继续按用户要求 DEFERRED。

仅当上述未延期门槛都有新鲜证据才能把 T11 整体改为 PASS。报告 `status=PASS` 表示该模式的执行/正确性校验通过；必须另查 `queries.*.meets_target` 和整体覆盖，不能据单个报告解除发布门槛。
