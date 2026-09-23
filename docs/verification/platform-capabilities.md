# T1 平台能力验证（部分实测，设备验证已延期）

2026-09-17 Asia/Shanghai。早期平台实验位于 `artifacts/development/platform/`，后续内核与原生宿主证据位于 `artifacts/development/`。App 位于 `apps/supplier_app/`；当前正式内核与原生启动基础已实现，尚未接入业务 UI，原 prototype 保持原样。

## 最新执行覆盖

用户明确要求暂缓 Android/Windows 验证并继续完整开发。Windows/Android 实际设备测试现记 **DEFERRED（用户明确延期）**，覆盖此前以设备缺失阻止 T3/T4 开发的门；不将延期标为 PASS。G001 与 G002（T3/T4）均已由官方 checkpoint 标记 complete，G003（T5/T6）in_progress，原生聚合目标 active。正式仓储已完成当前内核交接，主集成者继续 T5 备份/平台接入，core_storage 通道负责 T6 查询；M1/M2/M3 尚未完成。

此决定不改写历史日志，不代表 T1 全项实测通过。正式原生适配在启动时实际打开持久 SQLite、取得可靠应用写锁并完成活动库指针初始化，即可开放对应业务写入，不以历史 Windows/Android 验证报告 PASS 为前置条件；内存回退或跨写者锁不可用仍运行期拒绝写入。工程壳的默认 BLOCKED 探针将由真实启动流程替换，不能硬编码 PASS。设备安装、生命周期与文件环路保留为后续验证，首版支持与发布结论仍待对应证据。本文旧 BLOCKED 运行记录仅解释当时结果。

## 当前内核与原生基础验证

| 检查 | 结果 | 证据与范围 |
|---|---|---|
| 核心全套 / 分析 / 可执行 smoke | PASS | [107 tests](../../artifacts/development/kernel-tests.log)、[analyze clean](../../artifacts/development/kernel-analyze.log)、[SQLite exe smoke 构建及运行](../../artifacts/development/kernel-build.log)；T3/T4 宿主范围，不证明三端或规模目标 |
| 内核独立审查 | APPROVE | [kernel-review.md](kernel-review.md)；独立39项针对性测试通过，范围限定于已列 T3/T4 文件 |
| 原生文件端口 | PASS，8 tests | [native-file-ports.md](native-file-ports.md)及其新鲜日志；私有任务目录发布与单 owner isolate 锁，不是外部用户文件路径 |
| 原生数据库宿主 | PASS，6 tests | [native-database-host-tests.log](../../artifacts/development/native-database-host-tests.log)；持久身份重开、epoch/缺失/空库拒绝、缺元数据保护、候选启动恢复；运行期 bootstrap 基础，尚未接入 UI，不是完整 T5 恢复 |

下方工具链、5项工程壳测试及隔离实验均保留历史范围；它们不替代上表当前代码证据，也不扩展为 M1 完成。

## 版本与环境

- Flutter 3.47.4，framework `9584c6713b`，engine `06a2e2a110`，Dart 3.13.3；完整机器输出 `flutter-version.json`，SDK 固定记录 `apps/supplier_app/toolchain.json`，依赖解析锁定 `pubspec.lock`。
- 宿主 macOS 26.5.2 25F84 arm64（本轮以 `uname -m` 纠正早期记录）；Chrome 152.0.7977.84。`flutter-doctor.log` / `flutter-devices.log` 仅列出 macOS 与 Chrome，没有 Windows 或 Android 设备。
- Android runner minSdk 29，AGP 9.1.0、Kotlin 2.4.0、Gradle 9.3.1；初始用户SDK缺cmdline-tools/JDK；本轮已在独立临时工具链补齐并构建arm64 debug APK，见[Android构建报告](android-build-gate.md)。Windows runner 已生成，当前 macOS 主机不能执行 Windows build。
- 早期独立原型锁定 Drift 2.35.0、sqlite3 Dart 3.6.0，实测引擎 3.53.4、journal_mode=delete，详见下方补充实验。当前正式核心仓储与原生数据库宿主基础已有上表验证，UI 尚未接入，Web 产品适配仍待完成；不把原型引擎版本直接当成各生产适配实测版本。Flutter 渲染器 WASM 不是 SQLite WASM。

## 早期工程壳与平台实验

| 检查 | 结果 | 证据与范围 |
|---|---|---|
| `flutter analyze` | PASS | `flutter-analyze.log`，No issues found |
| `flutter test` | PASS | `flutter-test-verified.log`，5 tests；默认关闭、缺证据/失败不放行、证据不可变、壳界面 |
| `flutter build web` | PASS | `flutter-build-web.log`；只证明工程编译，含 Cupertino 字体告警，不证明业务/离线持久化 |
| `flutter build windows` | DEFERRED | 历史 `flutter-build-windows.log` 为 BLOCKED：只支持 Windows hosts；用户已延期 Windows 验证，尚无成功构建/运行证据 |
| Android 构建/真机 | 构建 PASS；真机 DEFERRED | 本轮 `flutter-build-android-isolated.log` 成功生成arm64 debug APK；aapt确认API29/36，apksigner验证通过。初次缺Java的失败日志保留；用户已延期真机验证，无真机安装/能力证据 |
| Web Locks 页面与独立 Worker 竞争 | PASS（基础实验） | `browser-results.log`：持锁时 Worker ifAvailable 未取得锁，释放后取得 |
| OPFS 有界写入、close、分段读取 | PASS（8 MiB 样本） | 128 次复用 64 KiB 缓冲写入，await close，读取中部 64 KiB 验证；`browser-results.log` |
| 独立 IndexedDB 元指针 abort/commit/reopen | PASS（基础实验） | abort 后旧指针，commit 后新指针，关闭连接重开核对；`browser-results.log` |
| 元指针页面刷新后重读 | PASS（仅页面刷新） | `browser-reload-results.log`；不是浏览器进程退出/强杀 |

首轮 `flutter test` 因沙箱 CPU 信息 syscall 导致引擎 SIGABRT，首轮沙箱外运行又受本机代理影响 WebSocket；均保留原始失败日志。最终在允许引擎运行且设置 `NO_PROXY=localhost,127.0.0.1,::1` 后 5 项通过。不可将早期失败误报为业务断言失败。

截图验证 BLOCKED：DevTools 导航到已构建壳成功，但截图输出路径被其 workspace roots 策略拒绝；不写文件的返回图像调用超时后取消。没有桌面／手机截图可供视觉通过证明。`integration_test/platform_probe_test.dart` 已提供，但未在 Windows／Android 真设备运行，也未把单元测试当真实集成通过。

## 保留的验证项目与缺口

1. **Windows / Android：DEFERRED（用户明确延期）。** 后续验证目标仍为 Windows 11 x64 构建/运行主机与 Android 10+ arm64 真机；独立 SDK/JDK 已补齐并完成debug构建。持久化重启、强杀、跨进程锁、文件授权丢失和真实流读写尚未实测；本轮不以接入设备阻止后续开发，不用 macOS 或 Web 替代其证据。
2. **Web 数据库：部分实验通过。** 独立探针已锁定 Drift/SQLite worker/WASM/hash，并测得实际 sqlite_version、opfsLocks 和 delete journal；Chrome/Edge 当期及前一稳定版矩阵、升级仍未完成，产品适配尚未安装。
3. **一致有界 SQLite 快照：有限夹具通过。** macOS 文件库在应用锁内分页复制；Web 在同一读事务内分页导出并让并发写等待，generation与摘要绑定。尚无50万修订与峰值空间证据。
4. **原子恢复与旧连接隔离：部分实验通过。** macOS独立元库事务及真实进程退出恢复通过；Web已有旧epoch SQL拒写，真实候选库与切换各崩溃点测试见专门报告。业务完整图、投影与回执恢复尚未实现。
5. **真实用户导出文件：BLOCKED（未测）。** OPFS工作文件和宿主私有临时目录不等于用户选择的外部文件；还需授权丢失、close失败/取消以及大包内存测量。下载发起不等于写入完成。
6. **浏览器进程重启与跨标签：有限场景通过。** 两顶层页面SQL写锁竞争、Browser.close后同profile不同PID重开、未提交SQL期间强杀后回滚并继续写入均通过。Worker升级、离线启动和浏览器版本矩阵尚未完成。

因此 T1 全项实测仍未通过；按最新用户决定，设备缺失不再阻止 T3/T4 和后续开发。开发阶段完成、启动期能力检查与历史平台验收分别记录。原工程壳默认 BLOCKED 是历史实现状态；正式应用依据真实初始化结果开放界面与写入，不能因历史设备报告未 PASS 阻止使用，也不把本文件的部分基础实验当首版发布证明。

## 复现

从 app 目录运行 `flutter pub get`、`flutter analyze`、`flutter test`、`flutter build web`。当前工具链位于 `/private/tmp/supplier-inquiry-toolchain/flutter/bin`，`PUB_CACHE=/private/tmp/supplier-inquiry-toolchain/pub-cache`，`XDG_CONFIG_HOME=/private/tmp/supplier-inquiry-toolchain/config`。最终测试另需上述 localhost 代理绕过；宿主沙箱不能查询引擎 CPU 信息时需允许本地测试进程执行。

独立浏览器实验从仓库根 `python3 -m http.server 8766 --bind 127.0.0.1`，打开 `/artifacts/development/platform/browser-probe.html`，控制台 `await runProbe()`；刷新后 `await checkReopen()`。实验只写专用 `supplier-t1-isolated-meta-v1` IndexedDB 与临时 OPFS 文件；OPFS 文件在 finally 删除，元数据库保留仅供刷新检查。测试不访问产品数据。全部输入/预期/实际含在脚本和日志中。原始日志记录时间和浏览器，`base-commit.txt` 记录运行基线；工作树文件摘要见 `source-sha256.txt`。

设计依据只解释实验，不代替运行证据：[Web Locks API](https://developer.mozilla.org/en-US/docs/Web/API/Web_Locks_API)、[createWritable](https://developer.mozilla.org/en-US/docs/Web/API/FileSystemFileHandle/createWritable)、[IDB abort](https://developer.mozilla.org/en-US/docs/Web/API/IDBTransaction/abort)。

## 本轮补充：真实数据库实验

2026-09-17 早期新增两条隔离能力实验，当时未改变工程壳默认 BLOCKED 状态；当前原生启动基础见上表：

- [本机 SQLite 报告](storage-gate.md)：21 项通过；磁盘重开、应用锁跨进程竞争、事务回滚、分页同快照、真实 SQLITE_FULL、原子元指针及进程退出恢复。macOS 证据不能代替 Windows/Android。
- [Web SQLite 报告](web-storage-gate.md)：真实 opfsLocks/SQLite 读事务内绑定 generation，1025 行按64行分页导出与并发写等待，导出/分段重读/独立样本摘要一致，IDB epoch 拒绝旧写入及刷新后持久化。双顶层标签页与完整浏览器重启、强杀回滚已补测通过，以该报告及原始结果为准。

上述新证据取代前文“快照尚无任何实现”的早期状态；完整产品恢复、外部用户文件、浏览器版本矩阵仍有验证缺口，Windows/Android 实机为 DEFERRED。此前按 PRD 第4节关闭的 T3 生产存储开发及 T4 服务集成依赖门，现由最新用户决定解除；运行期能力验证与发布证据边界保持。

延期前复查 `adb devices -l` 没有连接设备；检测到Android模拟器配置不当作arm64真机。Parallels CLI无法连接本地服务，未发现可用Windows运行证据；未启动或修改用户虚拟机。这是历史环境记录，延期后不再继续设备检查。
