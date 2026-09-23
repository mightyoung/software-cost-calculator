# 原生数据库宿主独立代码审查

日期：2026-09-17。范围仅为原生宿主启动、身份、失败关闭与连接清理。产品代码由主集成者编写，本通道只读审查并维护本报告。

## Code Review Summary

**Files Reviewed:** 2（另核对 1 个 core 公共 getter）  
**Total Issues:** 0 unresolved  
**Recommendation:** APPROVE，限本报告的原生宿主范围。

### By Severity

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 0

## 范围与依据

- `apps/supplier_app/lib/platform/native_database_host.dart`
- `apps/supplier_app/test/native_database_host_test.dart`

上下文只读核对：`native_file_ports.dart` 的写锁实现；core 的数据库创建、版本查询及协调器身份检查；本地缓存 Drift 2.35.0 的 `NativeDatabase(enableMigrations: false)` 和迁移引擎。

另核对 `packages/supplier_core/lib/src/data/database.dart:13` 新增的 `SupplierDatabase.requiredTableNames` getter：从现有 schema 派生不可修改的表名集合；无需跨包导入内部 DDL 文件，也未把表存在性包装成完整 schema 验证。

最终两个文件 SHA256：宿主 `cf0f38dcdb43d94078837d41583afee9132224c2cf7a85619440475226d71990`；测试 `854b4f8d080abb50a1201967313b5034b3c4365f93e1e2074fa8d98441c6ee59`。

依据为批准 PRD §3.4 的锁序、活动身份、设备身份隔离与恢复边界，以及 T3/T5 的本地持久化要求。本报告不重新评审整个 core 或已另行审查的文件端口。

## 已关闭发现

| 原严重度及问题 | 修复与证据 |
| --- | --- |
| HIGH：已有活动文件只检查长度；合法的非零 SQLite `user_version=0` 文件会被普通 Drift `onCreate` 初始化为新业务库 | 活动分支先用禁止迁移、query-only 的连接核对 schema 版本、实例、epoch 及必要表，再打开业务连接。非零空 SQLite 与含无关表的 schema-zero SQLite 两项真实文件回归均拒绝且逐字节不变 |
| MEDIUM：新增预检的 `finally close()` 可能覆盖原始失败 | 预检捕获原始异常和堆栈；关闭再失败时用 `FileOperationFailure` 同时保留主错误与清理错误。源码复核通过；本范围没有注入底层 SQLite close 双重失败的运行证据 |

根因防护已核对：没有以重新建库、忽略 schema 错误或返回成功来处理上述失败。

## 源码核对结果

- 首次 metadata SQL、业务库创建/检查及 bootstrap 指针发布均位于应用写锁内。Drift 执行器构造是延迟打开；没有先开启业务事务再等待写锁。
- device_id 存在独立 installation 数据库，业务库保存 instance/epoch/generation；正常重开维持两种身份与业务记录。
- bootstrap 意图先持久写入，业务库完成检查后，发布 active 与删除 bootstrap 在同一 metadata 事务。已有完成候选、尚未发布指针的重开路径被测试覆盖。
- 活动文件缺失、零字节、schema-zero、身份/epoch 不匹配均显式拒绝；丢失 installation metadata 而留有业务文件时拒绝创建替代业务库。
- 成功连接与失败候选有关闭路径；主错误不会被普通候选/metadata/probe 的二次关闭失败覆盖。
- 必要表存在性检查不是完整 schema 定义等价验证；启动检查也不是恢复候选的完整图、投影与摘要验证。

## 验证证据

主集成者日志 `artifacts/development/native-database-host-tests.log` 最终归档 **10/10 PASS**，本通道已读取测试源码与日志：重开身份和业务持久化、epoch 不符、活动文件缺失/空、安装 metadata 缺失、已完成 bootstrap 恢复、两个非零 schema-zero 文件反例、损坏字节及缺少必要表。后两项也核对拒绝后文件字节不变。

本通道最终独立执行 `dart analyze lib/platform/native_database_host.dart test/native_database_host_test.dart`：**No issues found!**。

公共 getter 所在 `database.dart` 单文件 analyze：getter 无诊断；另报告该文件现有 `cleanupStaging` 两处括号风格 info（125、134 行），属于本次宿主改动范围之外，不记作全 core analyze clean。

本通道独立测试尝试记录：首次加载因并行 T6 编辑中的 Dart 引号语法错误失败；随后可编译，但沙箱 Flutter VM 在 `cpuinfo_macos.cc:42` 发生 SIGABRT，均未执行测试断言。不能把这些独立尝试算作通过；最终运行证据采用主集成者可运行环境的日志并明确归属。修复过程中的跨包 `src` 导入 info 已通过上述公共 API 关闭，最终静态诊断无遗留项。

## 结论边界

这是 macOS 开发宿主的有界审查，不是完整 T5、M1 或发布验收。active-pointer CAS、恢复候选验证/备份/原子切换、进程中断恢复矩阵及跨平台耐久性仍由后续恢复集成验证。当前 bootstrap 回归构造持久中间状态，不是实际断电或进程 kill 测试。Windows/Android 实机按用户要求 DEFERRED，不记 PASS。
