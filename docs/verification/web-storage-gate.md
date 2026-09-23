# T1 Web SQLite 能力探针（局部通过，平台门仍关闭）

2026-09-17，独立非产品原型 `prototypes/web_storage_gate/`。所有数据库、锁、OPFS 文件名均带 `nonproduct-t1-` 前缀；未修改旧 prototype、产品 app 或旧 golden。测试先编写浏览器断言，再实现 Dart 适配；初次预期 abort 的 IndexedDB error 冒泡导致测试失败，修正测试事务事件处理后重跑通过。

## 实测环境与依赖

Dart 3.13.3，Drift **2.35.0**、sqlite3 Dart 包 **3.6.0**（完整解析见原型 `pubspec.lock`）；macOS 上独立临时 profile 的 Chrome headless 152。COOP `same-origin` / COEP `require-corp`，本地 HTTP 安全上下文。实际后端 **opfsLocks**，实际 SQL `sqlite_version()` **3.53.4**，`PRAGMA journal_mode` **delete**；缺失探测项 `dedicatedWorkersInSharedWorkers`。这不是 WAL 实验，也不代表其他后端或浏览器通过。

WASM/worker 从旧 `prototypes/supplier_probe/web/` 精确复制，旧文件未修改。以下摘要固定本次实际执行资产；不以 Dart 包版本冒充 SQLite 引擎版本，也不宣称重新验证了历史下载来源：

| 资产 | SHA-256 |
|---|---|
| sqlite3.wasm | `13d3f11d05b39ba0618a7115fb41640a5d48b6300f5d3f325f554b42bd6688a4` |
| drift_worker.js | `df0066e75363a9bed59a14eedbbded421c1f5910f8379812df164716aa2e6eed` |

## 已通过的可执行断言

| 检查 | 结果及边界 |
|---|---|
| 后端门 | 拒绝 `inMemory` / `unsafeIndexedDb`；本机实际选择 opfsLocks |
| SQLite 有界读快照 | 单个显式 Drift SQL 事务，首次 SELECT 固定 instance/generation；1025 行，每行 256 字符，主键 keyset 每页最多 64 行，共 17 页。所有页和结束 generation 均在同一事务 |
| 写入交错 | 独立顶层页面中另一个 Drift 连接先取得 Web Lock、核对元指针，再发起 SQL 写事务。读快照暂停期间确认它已到达 SQL 入口但未提交；导出全部是 generation 1 的原数据；读事务结束后写入提交，全部 1025 行更新、generation 变为 2 |
| 流式导出证据 | 每页 JSON 写入 OPFS 流并 await，增量 SHA-256，不调用 `exportDatabase`，不收集整库 Uint8List/Blob。await close 后文件 286952 bytes；测试以 64 KiB slices 重读完成文件，Python 增量 hash 与独立生成的 fixture hash 和快照 hash 三方一致：`304a25d12c363aeba43ad83fa3d54e2aa3b9667d6137aa6270d33e2a8cda759f` |
| 锁和 epoch fence | 两个同源顶层页面的 Web Locks 竞争失败；独立 IDB 单事务 abort 保留 epoch 1，commit 更新为 2；旧连接再次提交在 SQL 前拒绝 `STALE_EPOCH`，generation 保持 4 |
| 双顶层写入竞争 | CDP 确认两个不同 `page` target；主页面持应用锁，第二页面实际请求提交且尚未到达 SQL；主页面提交并释放后第二页面提交，generation 2 → 4，两个提交各完成一次 |
| 页面刷新 | 真正 `Page.reload` 重建连接，SQL generation 4、1025 行变更及元指针 epoch 2 仍在 |
| 整个浏览器正常重启 | `Browser.close` 后等待 Chrome 主进程 exit 0，同一临时 profile、同一 origin 启动不同 PID；SQL generation 4、epoch 2 持久，OPFS 分段重读摘要不变。随后新提交到 generation 5，验证重开后可取得锁并写入 |
| 未提交 SQL 事务期间强杀 | 等待真实 SQL UPDATE 行和 generation 执行完但事务仍未提交，SIGKILL 专属新建进程组，Chrome exit -9；同 profile 新 PID 重开仍为 generation 5、1025 行已提交内容、epoch 2，`PRAGMA integrity_check=ok`；随后提交到 generation 6 证明锁恢复 |
| 静态与构建 | `dart analyze` 无问题；`dart compile js` 成功；`node --check web/harness.js` 成功 |

导出允许编辑发起但写提交等待整个读事务；属于计划 3.3 的显式长读事务降级候选，不是独立快照库复制。正常成功路径已验证释放读事务后写入完成。单个未提交写事务的强杀恢复已测；读快照取消/异常释放、完整恢复协议和真实配额错误仍需另测。

`evidence/browser-results.json` 保存运行时间、UA、SQL结果、输入文件摘要与存储估算；`browser-test.log`、`dart-analyze.log`、`dart-build.log` 为原始输出。origin usage 从 314159 增至 605562 bytes，包含 SQL/IDB/OPFS；这是浏览器估算，并非精确峰值或 SQL journal 峰值。未据 1025 行推断 50 万修订规模。

## 真实候选库与元指针崩溃实验

新增独立入口 `restore.html`、`restore.dart`、`restore_harness.js` 和 `tool/restore_test.py`，没有把前述哨兵指针微实验冒充真实切库。新实验旧库 `old` 有 1025 行、generation 1；真实独立 SQLite 候选库 `candidate` 有 17 行、generation 42。候选先完整提交、检查行内容/主键范围/数量及 `integrity_check`，关闭候选连接，然后才能激活。重开根据 IDB 的 instance 选择实际数据库名称，核对身份、内容及完整性后才开放实验写入口。不存在的活动库不能静默作为空库开放写入。

所有激活/写入/回退先取得同一应用锁。激活内部携带同一个持锁 context 到元指针 helper，不递归申请锁、不在 SQL 事务内等应用锁；关闭本页面旧连接后在独立 IDB 单事务切换 pointer。另一个顶层页面保留的旧连接仅能读取旧库，其实验写入口必须在应用锁内核对绑定 instance/epoch。旧库始终保留。

每个场景使用全新隔离 Chrome profile，强杀后只在该场景原 profile 重开：

| 强杀点或条件 | 实际结果 |
|---|---|
| 错范围候选（17 行、validRows 17、minId 2、maxId 18） | 激活拒绝且旧 pointer/旧库不变；故障注入将 pointer 指向该坏候选后，实际 restoreReopen 拒绝，实验写入口保持关闭 |
| 候选已验证、旧连接已关闭、指针切换前 | exit -9；新 PID 按 pointer 打开完整 old / epoch 1 / generation 1 / 1025 行 |
| IDB put 已成功、写事务尚未完成 | 用持续排队 IDB get 保持真实事务 pending，确认多次请求后强杀；重开 pointer 仍是 old / epoch 1，1025 行完整 |
| IDB pointer 提交后、新连接校验前 | 强杀重开按 pointer 打开 candidate / epoch 2 / generation 42 / 17 行；内容及完整性通过 |
| 成功激活后的旧顶层连接写入 | 拒绝 `STALE_EPOCH`；旧库保持 generation 1 与完整 1025 行 |
| 新库接受后续写入后尝试自动回退 | 新库 generation 43，拒绝 `NEW_WRITES_PREVENT_ROLLBACK`；再次强杀并重开仍为 candidate / epoch 2 / generation 43，回退仍被拒绝 |
| 指针切换后候选校验失败、安全回切 | 在 candidate pointer 提交后用真实 SQL 将主键改为 2..18（generation 仍 42）；重开校验拒绝、写入口关闭；同一应用锁 context 内回切 old / epoch 3，1025 行完整。三个顶层页面中 epoch 1 旧库连接和 epoch 2 候选连接均拒绝 `STALE_EPOCH`；随后强杀重开仍为完整 old / epoch 3 |
| 回切 IDB 元事务中强杀 | put old/epoch 3 后保持事务 pending，强杀 exit -9；重开仍为 candidate / epoch 2、17 行、SQLite integrity ok，但范围校验失败，writeEnabled=false，实际写入被拒绝；重新取得应用锁继续回切后 old / epoch 3 完整可用 |
| 回切 IDB 提交后、重开旧库前强杀 | 强杀重开直接解析到完整 old / epoch 3 / generation 1，完整性与 1025 行内容校验通过才开放写入口 |


本轮 `evidence/build-manifest.json` 记录 Dart SDK、实际编译命令、源码及 `main.dart.js` / `restore.dart.js` 产物 SHA-256；恢复结果嵌入此 manifest，核对编译资产未变化，并标明实际入口 `restore.dart.js`。它只标识当前构建，不补造历史 `browser-results.json` 当时未记录的编译产物摘要。

原始结果在 `evidence/restore-results.json` / `restore-test.log`，包含每个阶段、实际 PID/exit code、元指针、数据库状态、IDB pending 请求次数与源码摘要。每个场景另有 Chrome 日志。早期四场景测试通过，但独立审查随后复现校验缺口：17 行、内容正确、generation 42 而主键范围 2..18 的候选可被激活。已修复激活前和激活后的完整候选条件，并将身份/generation/数量/内容/范围/完整性校验复用于实际 restoreReopen；重开失败保持禁写。新增真实 SQL 错范围候选负例并通过五场景矩阵；随后增加安全回切及回切事务中/提交后强杀，本轮八场景 fresh 矩阵全部通过，新增回切场景首次运行无失败。错范围负例首轮因测试直接匹配 Dart 异常字符串而失败，诊断确认 reopen 实际已拒绝且 writeEnabled=false；Dart 转为 JS Promise 后异常被包装。测试改为检查实际 Promise 拒绝、禁写及后续写入拒绝，包装错误作为证据保留；原始两次失败记录在 `restore-negative-first-failure.json` / `restore-negative-wrapper-failure.json`。Chrome headless 的显示设备诊断输出不代表断言失败，最终以结构化结果为准。

恢复失败的启动路径仅加载非产品诊断接口，记录 `restoreValidationError`，保持 `restoreWriteEnabled=false`；`probeReady` 表示测试接口可调用，不表示失败候选可编辑。断言实测写入拒绝后，恢复 runner 显式调用持应用锁的回切入口继续恢复。回切通过独立 IDB 原子更新 pointer，**没有跨 old/candidate 两个 SQL 数据库假设一笔原子事务**。回切只允许候选仍为本夹具准备时 generation 42；后续业务实验写入至 43 后，原有“重启前后禁止回退”场景继续通过。

**范围严格限于小型结构/内容夹具**：这里没有供应商业务图、父闭包/投影验证、恢复文件解析、candidate 内容摘要令牌、正式回执、完整旧库备份或资源预算。不宣称业务图恢复或 T5 完成。IDB 事务保持 pending 是可控故障注入，不代表断电或所有实际时序。

## 仍阻塞的内容与下一缺口

- 本次仅验证可完整读取但主键范围错误的候选回切；未覆盖不可打开/物理损坏数据库、丢失旧库、回切目标损坏、身份篡改、真实 I/O 失败。不能从逻辑夹具校验失败推断这些错误同样可恢复。
- 未测 COMMIT 应答丢失、系统断电、浏览器驱逐、离线升级或 worker 更新。当前通过的 SQL 与 pointer 强杀点不等于完整故障矩阵。
- OPFS 只是工作文件，不是用户手势选择的外部目标；没有文件授权丢失、close 失败、读快照取消/异常释放或取消发布验证。
- 未测 Chrome/Edge 当期及前一稳定版矩阵、真实存储配额耗尽、规模、内存及临时日志峰值；不能从 1025 / 17 行推断 50 万修订支持。
- Windows、Android 真机能力仍 BLOCKED；T1 总门、T3 生产适配和发布门保持关闭。本 lane 在本次可复现证据完成后交接独立审查。

## 复现

在仓库根执行（使用当前可用 SDK；Chrome 路径为本机 macOS 路径）：

```sh
export PUB_CACHE=/private/tmp/supplier-inquiry-toolchain/pub-cache
export PATH=/private/tmp/supplier-inquiry-toolchain/flutter/bin:$PATH
dart pub get --directory prototypes/web_storage_gate
dart analyze prototypes/web_storage_gate
python3 prototypes/web_storage_gate/tool/build.py
node --check prototypes/web_storage_gate/web/harness.js
python3 prototypes/web_storage_gate/tool/browser_test.py
node --check prototypes/web_storage_gate/web/restore_harness.js
python3 prototypes/web_storage_gate/tool/restore_test.py
```

Python 需要已有 `websocket-client`。`tool/build.py` 默认使用本机上述 SDK，可通过 `DART` 指定相同版本的 dart 可执行文件。runner 自建临时本地 HTTP server、独立临时 Chrome profile，每次启动创建独立 OS session/process group；正常退出使用 CDP Browser.close，强杀只作用于 runner 创建的那个组，同一 profile 完成两次重开后才删除。结束后关闭 HTTP server，不访问用户日常浏览器数据。受沙箱限制时 Chrome 无输出退出，本次允许本地测试进程执行后验证通过。编译产物忽略入库；WASM/worker、锁文件、源代码和证据保留。

官方参考：[Drift Web 文档](https://drift.simonbinder.eu/platforms/web/) 描述后端选择、worker/WASM匹配与 COOP/COEP；当前包源码 `drift-2.35.0/lib/wasm.dart` 用于核对实际 API。参考仅解释实验设计，不代替上述实测证据。
