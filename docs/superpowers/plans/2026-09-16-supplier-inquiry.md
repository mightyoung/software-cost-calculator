# Supplier Inquiry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付Windows、Android、Web本地优先供应商询价系统，支持精确报价、业务Excel编辑回流、完整分卷同步和人工冲突解决。

**Architecture:** Flutter界面调用共享Dart应用服务，Drift/SQLite存储不可变修订与可重建投影。单写事务承载业务提交；文件适配器流式输入输出，暂存与业务数据隔离。普通表格回执与正式因果同步使用不同契约。

**Tech Stack:** Flutter/Dart、Drift/SQLite、Web SQLite WASM、XLSX/ZIP/XML适配器、SHA256与限定领域JCS编码。阶段0的Flutter 3.47.4/Dart 3.13.3及Drift 2.35.0、excel 4.0.6仅为起始候选；T1通过平台能力门后锁定实际版本，禁止绕过平台失败继续宣称支持。

**Spec:** [已确认设计1.0](../specs/2026-09-16-supplier-inquiry-design.md)。设计提交：2187831。当前任务只生成计划，以下文件、接口、测试命令是待创建目标；不能当成已有实现或已通过结果。

编制于2026-09-16，完成自检于2026-09-17（Asia/Shanghai）。

## Global Constraints

- 首版平台：Windows、Android、Web；iPhone 后续支持。
- 本地优先，无业务服务器、账户、权限或登录。
- 每条报价独立保存项目和询价信息，不建立项目/询价单主表。
- 日常新建：项目名称/编号至少一项、询价时间、询价人必填；地点选填。
- 用户显式选择历史资料模式后可缺上下文字段，保留缺失标记。
- 支持仅日期和具体时刻；未知时间不能补造为00:00。
- 首版全量历史，ZIP内含多个Excel分卷；全部验证后一次业务提交。
- 只记录已取得价格的报价，不做待回复/不报价流程。
- 目标基准：100,000条报价，10,000供应商、20,000产品、20,000联系人、累计500,000修订。
- 初始工程工作集参数：每xlsx卷最多5,000数据行、8MiB压缩、32MiB实际展开，取先触达者；每envelope≤24,000 UTF-16单位、每单元格≤32,767；每卷最多2048 ZIP条目。
- 不改写旧 `.omx` 规范、旧golden和阶段0源代码；引用小样时移植已验证规则及回归，不把空库restore当同步仓储。
- 图/业务规则不可依赖Flutter、dart:io或平台时钟；平台文件、锁、空间估计和持久化能力由适配器提供。
- 不作自动联网同步、增量包、附件、订单库存或权限模块；不自动裁剪历史。

---

## 文件结构与责任

```text
apps/supplier_app/                 Flutter产品工程；Windows/Android/Web壳
  lib/main.dart                    启动、活动库选择、服务组装
  lib/platform/                    文件选择/读写、写锁、空间及生命周期
  lib/features/records/            供应商、联系人、产品、报价表单/详情
  lib/features/query/              分页搜索、筛选、比价
  lib/features/exchange/           普通导入、分卷同步、冲突、批次进度
  lib/features/backup/             备份、恢复、存储状态
  integration_test/               真平台流程和生命周期验证
packages/supplier_core/
  lib/src/contracts.dart          下列公共接口、值对象和错误类型
  lib/src/domain/                 字段校验、日期精度、JCS、图/状态规则
  lib/src/data/                   Drift定义、迁移、投影、统一事务
  lib/src/application/            Record/Exchange/Backup服务
  lib/src/query/                  筛选、候选与比价查询
  lib/src/exchange/               XLSX有界适配、分卷manifest、回执、暂存
  lib/supplier_core.dart          明确导出公共接口
  test/fixtures/v2/               新协议固定样例；与旧golden分开
  test/support/                  已知样例、数据库故障注入和TestRig
  test/                          纯领域及宿主SQLite/文件集成测试
tools/                            基准数据、测试矩阵和证据汇总脚本
docs/verification/               每次版本/平台/fixture绑定的实际结果
```

不预建通用Controller/Repository基类或每字段一个服务。一个任务内负责实现及测试文件；不同代理不能同时修改同一个公共接口文件。Drift生成文件由命令生成，不手改。

## 公共接口契约（T2建立；后续任务不能自行改名）

输入JSON是跨边界DTO，进入服务前转换为已校验的不可变模型；仓储内部不用任意Map拼SQL。所有List/Map结果返回不可变副本。

```dart
typedef JsonObject = Map<String, Object?>;
enum CaptureMode { standard, historical }
enum InquiryPrecision { date, instant, unknown }
enum RowAction { modify, newInquiry, skip }
enum JobState { created, parsing, validating, previewReady, committing,
                committed, cancelled, failed }

class DomainFailure implements Exception {
  final String code, message;
  final String? field;
  const DomainFailure(this.code, this.message, {this.field});
}
class RevisionRecord {
  final String id;
  final JsonObject envelope;
  const RevisionRecord(this.id, this.envelope);
}
class ImportPreview {
  final String jobId;
  final int generation;
  final JsonObject counts;
  const ImportPreview(this.jobId, this.generation, this.counts);
}
class CommitResult {
  final String jobId;
  final int generation;
  final JsonObject counts;
  const CommitResult(this.jobId, this.generation, this.counts);
}
class RowDecision {
  final String rowKey;
  final RowAction action;
  final String? targetId;
  // fieldOps每键为 {op: keep|clear|set, value: ...}；只set带value。
  final JsonObject fieldOps;
  const RowDecision(this.rowKey, this.action, this.targetId, this.fieldOps);
}
class QueryPage {
  final List<JsonObject> rows;
  final String? nextCursor;
  const QueryPage(this.rows, this.nextCursor);
}
abstract interface class InputSource {
  String get displayName;
  Future<int> length();
  Stream<List<int>> openRange(int start, int endExclusive);
}
abstract interface class OutputTarget {
  Future<void> write(Stream<List<int>> bytes);
  Future<void> publish(); // 发布临时文件/发起下载；不代表Web物理落盘
  Future<void> abort();
}
abstract interface class RecordService {
  Future<String> createEntity(String entityType, JsonObject payload);
  Future<String> correctEntity(String type, String id, JsonObject payload,
      {required Set<String> expectedHeads});
  Future<String> createQuotation(JsonObject payload); // 强制standard
  Future<String> copyQuotation(String id, JsonObject overrides); // 新ID/standard
  Future<void> deleteEntity(String type, String id, Set<String> expectedHeads);
  Future<void> restoreEntity(String type, String id, JsonObject payload,
      Set<String> expectedHeads);
  Future<void> resolve(String type, String id, JsonObject completePayload,
      Set<String> expectedHeads);
  Future<void> mergeEntities(String type, String source, String target,
      JsonObject targetPayload, Map<String, Set<String>> expectedHeads);
  Future<void> repairAliases(String type, Set<String> ids, String keeper,
      JsonObject keeperPayload, Map<String, Set<String>> expectedHeads);
}
abstract interface class QueryRepository {
  Future<QueryPage> quotations(JsonObject filters, {String? cursor, int limit=50});
  Future<JsonObject> entity(String type, String id);
  Future<List<JsonObject>> candidates(String type, JsonObject source);
}
abstract interface class ExchangeService {
  Future<String> beginBusiness(InputSource source,
      {required CaptureMode mode, required JsonObject mapping,
       required JsonObject batchDefaults});
  Future<String> beginBundle(InputSource source);
  Future<ImportPreview> prepare(String jobId);
  Future<CommitResult> commit(String jobId, int expectedGeneration,
      {List<RowDecision> decisions=const []});
  Future<void> exportBusiness(OutputTarget target, JsonObject filters);
  Future<void> exportBundle(OutputTarget target);
  Future<void> cancel(String jobId);
  Future<ImportPreview> resume(String jobId, InputSource source);
  Stream<JsonObject> watchJob(String jobId); // state/phase/processed/total/error
}
abstract interface class BackupService {
  Future<void> create(OutputTarget target);
  Future<String> prepareRestore(InputSource source); // 新库验证后返回令牌
  Future<void> activateRestore(String token);
}
```

`createEntity`只接受supplier/contact/product，quotation必须走专用入口；generic纠错quotation仍执行capture_mode不可降级和完整schema检查。historical根只能由显式历史导入/阶段0迁移创建。`resolve`是完整put选择，选择删除调用deleteEntity并传全部heads；所有expectedHeads执行比较交换。查询filter允许键固定为设计§7字段及as_of，不接受任意SQL。

固定错误码：VALIDATION、UNSUPPORTED_FORMAT、MISSING_VOLUME、CORRUPT_VOLUME、IDENTITY_COLLISION、MISSING_PARENT、STALE_PREVIEW、STALE_HEADS、NEEDS_RESOLUTION、SPACE_REQUIRED、NON_PERSISTENT、CANCELLED、IO_FAILURE。错误携带字段或卷/行位置，失败不返回CommitResult。协议合法的并发状态不是格式错误，可提交后待解决。

beginBusiness/beginBundle只创建任务并绑定输入，立即返回jobId；界面先订阅watchJob，再调用prepare触发解析与预览，确保解析完成之前已有进度。resume用于已知任务ID的恢复；同步与普通表共用prepare但不混淆校验规则。

测试支持：T2建立`fixture(String name)`读取`test/fixtures/v2/$name.json`并深拷贝；`revisionFixture(String name)`和`graphFixture(String name)`返回List<RevisionRecord>，前者是固定修订列表，后者是带父关系的列表。T3建立`TestRig.open()`（临时文件库）、`close()`、`reopen()`、`seed()`（从固定修订经commit协调器写S1/C1/P1及Q1）、`logicalSnapshot()`（不含失败日志/暂存）、`failAt(String point)`（一次故障）、`heads(type,id)`及`generation()`；暴露`committer`，T4/T6再分别接入`records`/`query`，T5/T7/T9逐步组装`backups`和`exchange`。测试数据库与故障注入不能进入产品公开API。

## 依赖与交付

T1 → T2 → T3 → T4；T5、T6在T4后可并行。T7依赖T5/T6；T8依赖T7，形成M1。T9依赖T4/T5/T7，可与T8并行；T10依赖T8/T9，形成M2。T11贯穿规模测试并在T10后收口；T12完成M3。单写者提交器和协议schema各由单一任务所有者维护。

### T1：三端工程与能力门

**Files:** Create `apps/supplier_app/`、`packages/supplier_core/pubspec.yaml`、`apps/supplier_app/integration_test/platform_probe_test.dart`、`docs/verification/platform-capabilities.md`。

**Interfaces:** Consumes阶段0报告及同一报价fixture；Produces可构建Flutter工程、path依赖supplier_core、持久存储/文件选择/导出能力报告。公共文件接口由T2冻结，本任务仅验证平台能力，不自建业务表作为最终仓储。

- [ ] 在独立实现分支建立Flutter壳，声明Android/Windows/Web；保留原小样目录。把官方版本、工具链、WASM与worker资源散列写入能力报告。
- [ ] 写平台集成断言，先运行未接适配的测试，预期能力未实现而失败：

```dart
testWidgets('platform persists the canonical sample', (tester) async {
  final before = await platformProbe.writeSample();
  await platformProbe.closeAndReopen();
  expect(await platformProbe.readSample(), before);
  expect(await platformProbe.fileRoundtrip(before), before);
});
```

`platformProbe`是本文件的测试夹具，分别打开Drift临时持久库和系统文件入口；不得用内存Map替代。关闭重开连接测试与退出应用重启测试分开记载。

- [ ] 接通三端真实适配并重跑：`flutter test integration_test/platform_probe_test.dart -d <实际设备ID>`；Windows构建只在Windows，Android真机运行，Web额外浏览器退出重启。缺环境记录BLOCKED，不填PASS。
- [ ] 运行`flutter analyze`、`flutter build windows`、`flutter build apk --release`、`flutter build web`，各自在合法宿主执行。核对打开文件、选择保存位置、下载失败可见、WASM资源加载和离线缓存能力。
- [ ] 提交工程与能力报告。若候选依赖不能满足任何首版平台，本任务不通过；先修适配或重选依赖，记录ADR，不借Web替代原生。

### T2：领域值、正式schema与黄金样本

**Files:** Create `lib/src/contracts.dart`、`lib/src/domain/{quotation.dart,text.dart,decimal.dart,inquiry_time.dart,canonical_json.dart,revision.dart,schema_v2.dart}`、`lib/supplier_core.dart`、`test/support/fixtures.dart`、`test/fixtures/v2/`、`test/domain_test.dart`（路径均相对packages/supplier_core）。

**Interfaces:** Produces上面公共契约；纯函数`JsonObject normalizeQuotation(JsonObject input)`、`String canonicalEnvelope(JsonObject envelope)`、`String revisionId(JsonObject envelope)`、`String sourceFingerprint(JsonObject source)`、`String operationFingerprint(JsonObject operation)`。normalize验证payload本身，操作权限/创建语义由RecordService和ExchangeService校验。

- [ ] 创建完整标准报价fixture并将所有省略项按schema显式写null：

```json
{"supplier_id":"11111111-1111-4111-8111-111111111111","product_id":"22222222-2222-4222-8222-222222222222","price":"12.340001","currency":"CNY","tax_mode":"included","unit_snapshot":"件","min_qty":"1","quoted_on":"2026-09-16","contact_id":null,"contact_snapshot":null,"tax_rate":"13","lead_time_days":null,"valid_until":null,"notes":null,"project_name":"配电改造","project_number":"000123-A","inquiry_location":null,"inquirer_name":"张三","inquiry_precision":"date","inquiry_date":"2026-09-16","inquired_at":null,"inquiry_utc_offset_minutes":null,"capture_mode":"standard"}
```

- [ ] 先写并运行失败测试：

```dart
test('date only never becomes midnight', () {
  final q = normalizeQuotation(fixture('quotation-standard'));
  expect(q['inquiry_precision'], 'date');
  expect(q['inquired_at'], isNull);
  expect(q['project_number'], '000123-A');
});
test('standard missing person fails, historical unknown remains unknown', () {
  final q = fixture('quotation-standard')..['inquirer_name'] = null;
  expect(() => normalizeQuotation(q), throwsA(isA<DomainFailure>()));
  q.addAll({'capture_mode':'historical', 'inquiry_precision':'unknown',
    'inquiry_date':null, 'quoted_on':null});
  expect(normalizeQuotation(q)['inquiry_date'], isNull);
});
```

- [ ] 实现设计§3完整字段校验，包括金额边界、Unicode、date/instant/unknown、本地日期与偏移一致、历史例外和valid_until依赖；移植小样已验证规则及反例，保留原测试。
- [ ] 生成正式schema：四类put、delete、redirect、bundle manifest、投影固定列、三个版本号分别定义。采用限定领域JCS：键名固定ASCII、有界整数、规范十进制字符串、NFC、无浮点、无孤立代理项；固定fixtures由第二实现独立核算，不以同一函数生成再验证。
- [ ] `dart test test/domain_test.dart`、`dart analyze`通过；新增历史/日期精度/JCS所有正负例后提交。旧golden的哈希必须保持原值。

### T3：Drift权威历史、投影与事务

**Files:** Create `lib/src/data/{database.dart,tables.dart,migrations.dart,commit_coordinator.dart,projection_writer.dart}`、`test/support/test_rig.dart`、`test/storage_test.dart`。

**Interfaces:** Consumes T2 RevisionRecord；Produces `CommitCoordinator.commitRevisions(List<RevisionRecord>, {required int expectedGeneration, required String jobId})`返回CommitResult，以及支持批量分页扫描/受影响投影的内部仓储。公开服务不得直接调用散落的INSERT。

- [ ] 先建故障测试并确认失败：

```dart
test('business rows and successful receipt roll back together', () async {
  final r = await TestRig.open();
  await r.seed();
  final before = await r.logicalSnapshot();
  r.failAt('after_revision_insert');
  await expectLater(r.committer.commitRevisions(revisionFixture('quotation-new-root'),
    expectedGeneration:await r.generation(), jobId:'fault-case'),
    throwsA(isA<DomainFailure>()));
  await r.reopen();
  expect(await r.logicalSnapshot(), before);
  await r.close();
});
```

- [ ] 实现identity/revision/parent/head/四类projection及local辅助表，FK类型存在性检查、唯一键、generation；补增删列/版本原子迁移。暂存另有batch_id/volume索引，业务查询禁止读暂存。
- [ ] 事务协调器在单次事务中写修订、投影、generation和成功回执，失败摘要在外写。故障注入覆盖第一/中间/末尾写入、版本更新、磁盘满模拟；数据库关闭重开必须一致。
- [ ] `dart test test/storage_test.dart`、`dart analyze`通过；检查`foreign_key_check`与迁移重试、持久化重开，再提交。

### T4：图合并与所有记录操作

**Files:** Create `lib/src/domain/{revision_graph.dart,aliases.dart}`、`lib/src/application/record_service.dart`、`test/{graph_test.dart,record_service_test.dart}`。

**Interfaces:** Produces RecordService全方法，纯图接口`Set<String> findHeads(Iterable<RevisionRecord> revisions)`；大规模导入使用索引仓储的分批图验证，不调用小规模纯函数一次装下全库。

- [ ] 写失败性质测试，用同一fixture根r0构造rA/rB及继承两者的rM：

```dart
test('old and reordered revisions cannot discard concurrent heads', () {
  final rows = graphFixture('parallel'); // r0,rA,rB，T2固定fixture
  expect(findHeads(rows), {rows[1].id, rows[2].id});
  expect(findHeads(rows.reversed), findHeads(rows));
  expect(findHeads([...rows, ...rows]), findHeads(rows));
});
```

- [ ] 实现根唯一、父闭包/同实体/无环、重复集合并集、heads比较交换、put/delete/redirect与关系状态。对大规模图用暂存索引和分批拓扑/引用校验，避免递归栈及全量DOM式内存图。
- [ ] 实现新增/纠错/复制、删除恢复、目标put+来源redirect原子合并、重定向环修复；standard不能降为historical，复制强制standard，历史补齐转标准通过纠错提交新修订。
- [ ] 固定种子100组DAG验证幂等/交换/结合；覆盖三端未知分支再次冲突、同内容并发、跨实体父、根碰撞、删除旧包、别名环及关系异常。运行`dart test test/graph_test.dart test/record_service_test.dart`并提交。

### T5：文件边界、备份与持久任务恢复

**Files:** Create `lib/src/application/backup_service.dart`、`lib/src/exchange/{job_store.dart,staging_store.dart,space_budget.dart}`、`apps/supplier_app/lib/platform/{input_source.dart,output_target.dart,storage_capabilities.dart,write_lock.dart}`、`test/backup_job_test.dart`。

**Interfaces:** Implements InputSource、OutputTarget、BackupService；job store提供`create/transition/load`，transition只接受设计状态图的合法边；space budget输出声明量、已使用量和预测需求，不保证预测能防止真实I/O失败。

- [ ] 先写恢复切换故障测试：

```dart
test('failed activation keeps the previous database active', () async {
  final r = await TestRig.open(); await r.seed();
  final before = await r.logicalSnapshot();
  final token = await r.backups.prepareRestore(fileSource('backup-valid'));
  r.failAt('before_active_pointer_commit');
  await expectLater(r.backups.activateRestore(token), throwsA(isA<DomainFailure>()));
  await r.reopen(); expect(await r.logicalSnapshot(), before); await r.close();
});
```

`fileSource`由测试支持实现为InputSource读取已知fixture文件；backup-valid通过独立已知修订集合生成并核验，不把当前库当唯一预期来源。

- [ ] 原生采用一致逻辑备份或SQLite一致备份机制；Web实现临时库、验证令牌和活动库指针，保留旧库至重开校验。包含本地回执/设置，排除设备ID、缓存与锁。
- [ ] 文件源支持范围读取与取消；写目标使用临时文件/流式落地，成功后publish。Web不能依赖整包Blob常驻内存来满足大包目标；验证所选浏览器可用的持久暂存与文件流路径，缺可靠路径则平台门失败。
- [ ] 验证失去文件访问后的重新选择/hash匹配、未完成卷清理重试、generation过期、下载发起失败、迁移备份失败、指针切换各故障点及已提交后重开。`dart test test/backup_job_test.dart`通过后提交。

### T6：十万规模的查询与候选基础

**Files:** Create `lib/src/query/{query_repository.dart,comparison.dart,search_keys.dart,candidates.dart}`、`test/query_test.dart`、`tools/generate_benchmark.dart`。

**Interfaces:** Implements QueryRepository；filter固定字段见设计§7，游标包含完整排序键+最后ID，limit范围1—200。候选返回稳定实体ID、显示名和匹配理由，不返回自动合并决定。

- [ ] 写失败比价测试：

```dart
test('comparison excludes uncertain rows but history stays visible', () async {
  final r = await TestRig.open(); await r.seedComparisonCases();
  final all = await r.query.quotations({'product_id':p1, 'view':'history'});
  final ranked = await r.query.quotations({'product_id':p1,
    'view':'confirmed_lowest', 'currency':'CNY', 'unit_snapshot':'件',
    'as_of':'2026-09-16'});
  expect(all.rows.length, greaterThan(ranked.rows.length));
  expect(ranked.rows.every((q) => q['currency']=='CNY' && q['unit_snapshot']=='件'), isTrue);
  await r.close();
});
```

`seedComparisonCases`生成同口径两价及USD/箱/未知税制/过期/未知日期等已知行；p1为fixture产品UUID。

- [ ] 实现关联批量查询、稳定分页、历史缺失筛选、项目和询价人组合条件、同日并列、date与instant的日内未知显示、精确price_key；supplier/product失效排除有效比价而不丢历史，联系人失效显示快照。
- [ ] 建索引并保存EXPLAIN QUERY PLAN；生成1万和10万报价fixture，固定种子并记录字段长度、重复分布和修订数。区分prefix和substring路径，禁止用LIMIT掩盖错误排序。
- [ ] `dart test test/query_test.dart`及基准查询初测通过；正式时延由T11验收，提交查询闭环。

### T7：业务Excel编辑回流与回执

**Files:** Create `lib/src/exchange/{xlsx_reader.dart,xlsx_writer.dart,business_mapping.dart,receipts.dart,business_import.dart}`、`lib/src/application/exchange_service.dart`、`test/{xlsx_test.dart,business_import_test.dart}`。

**Interfaces:** Implements beginBusiness、prepare、commit(decisions)、exportBusiness、cancel/resume/watchJob的普通表分支；共享XLSX适配逐行提供原始单元格类型/词法及坐标，不经double转换金额。源文件大小、展开量、shared strings和行暂存有界，普通大表不能直接套小样整包DOM读取。

- [ ] 写重导反例并先看到失败：

```dart
test('same incoming row is recognized after local value or alias changes', () async {
  final r = await TestRig.open(); await r.seed();
  await r.importBusinessCase('blank-notes-preserve-A');
  await r.changeLocalNotesToBAndMergeSupplier();
  final job = await r.exchange.beginBusiness(fileSource('same-row-renamed'),
    mode:CaptureMode.standard, mapping:fixture('mapping'), batchDefaults:{});
  final p = await r.exchange.prepare(job);
  expect(p.counts['already_imported'], 1);
  expect(p.counts['new'], 0);
  await r.close();
});
```

夹具helper严格按RecordService公开操作实施，不直接SQL制造预期。same-row-renamed只改变文件名/行顺序，不变规范来件。

- [ ] 实现标准/历史模式、缺列/空白/有值三态、显式批次默认、1900/1904日期、无时区时批次选择、科学记数的原始数字精确处理、非法精度/损坏编号拒绝。公式不读缓存；合并单元格及解析器改写风险使用已有负例锁定。
- [ ] 建source指纹优先查回执、operation指纹及原绑定/数量结果；用户明确修改/新增/清空/排除才生成最终计划。既有ID状态分流，未知ID仅提示；同内容多次询价可显式保留，首次候选允许批量确认。
- [ ] 保存预览generation，确认事务重新核验；成功回执与业务一起提交。验证旧导出基线、本地已改、已删/合并后重导、缺必填历史例外、新建拒绝、排除错误行子集原子性。
- [ ] 用真实WPS与Microsoft Excel分别导出编辑再导入，记录版本及fixture摘要；小样WPS特定兼容不可外推。`dart test test/xlsx_test.dart test/business_import_test.dart`通过再提交。

### T8：本地工作版UI（M1）

**Files:** Create `apps/supplier_app/lib/features/{records,query,exchange,backup}/`、`apps/supplier_app/test/local_workflows_test.dart`、`apps/supplier_app/integration_test/local_workflows_test.dart`。

**Interfaces:** 只依赖RecordService、QueryRepository、ExchangeService普通表分支、BackupService。UI不得直接写projection或自行制造revision_id。

- [ ] 先写行为测试：

```dart
testWidgets('new quotation requires context while historical import labels gaps', (tester) async {
  await tester.pumpWidget(testApp());
  await tester.tap(find.text('新增报价'));
  await fillKnownPriceOnly(tester);
  await tester.tap(find.text('保存'));
  expect(find.text('请填写项目名称或编号'), findsOneWidget);
  await openHistoricalFixture(tester);
  expect(find.text('历史资料：存在缺失信息'), findsOneWidget);
});
```

`testApp`注入隔离TestRig服务；两个helper走真实表单/导入组件交互，不直接设最终状态。

- [ ] 桌面分页表格+详情、手机搜索列表+分步录入；实现所有字段、日期/时刻切换、缺失提示、复制新报价、联系动作和批量映射。记录ID及偏移格式只在必要诊断/高级显示中出现。
- [ ] 交互支持加载/空结果/错误/取消/恢复，不把失败当空列表；删除显示影响数量，备份明确生成与下载状态。键盘和窄屏验证不裁切必填项/确认按钮。
- [ ] `flutter test test/local_workflows_test.dart`及三端local_workflows集成通过，形成可使用M1；明确此里程碑尚无正式多端同步发布承诺。提交UI与操作说明。

### T9：分卷完整同步内核

**Files:** Create `lib/src/exchange/{bundle_manifest.dart,bundle_export.dart,bundle_import.dart,projection_digest.dart}`、`test/{bundle_test.dart,export_snapshot_test.dart}`、`test/fixtures/v2/bundles/`。

**Interfaces:** Implements beginBundle、prepare、exportBundle及commit/resume的同步分支；复用T5暂存与T7有界XLSX，遵守T2冻结schema。分卷压缩/展开/行数阈值均走同一配置，编码实际超限必须缩卷而非截断。

- [ ] 先写最小双卷失败测试：

```dart
test('missing final volume never commits earlier volumes', () async {
  final r = await TestRig.open(); await r.seed();
  final before = await r.logicalSnapshot();
  final job = await r.exchange.beginBundle(fileSource('missing-last-volume'));
  await expectLater(r.exchange.prepare(job),
    throwsA(isA<DomainFailure>().having((e)=>e.code,'code','MISSING_VOLUME')));
  expect(await r.logicalSnapshot(), before);
  await r.close();
});
```

- [ ] 实现STORE外层ZIP、逐卷字节hash、逻辑全局摘要、固定表头与投影，所有输出基于一致快照；任务临时输出完成并自验后publish。编码器超限缩卷重试只改变边界，不改变记录顺序/内容。
- [ ] 实现逐卷暂存、缺/多/重复路径、总量与实际展开检查、JCS/hash/闭包/DAG/投影验证；确认时generation核验后一次业务事务提交。单卷永远不能独立提交，不能用包ID替代集合幂等。
- [ ] 测旧包、三端排列互导、并发分支、损坏卷、未来版本、同UUID多根、预算异常、导出中并发修改、中断残包、提交前后终止与重试。`dart test test/bundle_test.dart test/export_snapshot_test.dart`通过后提交。

### T10：同步、冲突与修复UI（M2）

**Files:** Create `apps/supplier_app/lib/features/exchange/{sync_preview.dart,conflict_resolution.dart,alias_repair.dart,job_history.dart}`、`apps/supplier_app/integration_test/sync_workflows_test.dart`。

**Interfaces:** 使用beginBundle、prepare、commit、watchJob及RecordService.resolve/deleteEntity/repairAliases；界面展示完整版本选择，不在UI拼接parents或忽略未知分支。

- [ ] 先测试A/B并发→互导→选择完整结果→第三端导入的行为，断言可见冲突数量、各版本金额/项目/时间精度、解决后head集合；用户未选择前不写解决修订。
- [ ] 同步入口明确与业务Excel、备份恢复区分；展示新增/旧版/并发/删除/疑似重复统计，缺卷不允许确认。重开显示committed或可恢复任务，不重复提示提交。
- [ ] 实现同内容并发一键确认、并行删除、目标状态无效、重定向环修复、预览失效重新计算、取消已提交时显示准确结果。
- [ ] `flutter test integration_test/sync_workflows_test.dart -d <实际设备ID>`通过，发布M2测试包，仍等待规模与全矩阵放行；提交界面及证据。

### T11：容量、性能与故障验收

**Files:** Create `tools/run_benchmarks.dart`、`tools/verify_evidence.py`、`packages/supplier_core/test/large_data_test.dart`、`docs/verification/performance.md`。

**Interfaces:** Consumes T6固定种子数据生成器及实际服务接口；Produces每设备JSON记录（版本、fixture hash、报价/修订数、源/展开字节、耗时、内存指标及测量范围、PASS/FAIL/BLOCKED）。不通过修改fixture字段长度掩盖性能退化。

- [ ] 用1万、10万报价和50万修订分别跑全量导入/导出/备份/恢复/查询，校验最终图与投影摘要。长文本、唯一字符串、转义、重复候选密集场景分别运行。
- [ ] 先把性能门写为可判定断言，再测：

```dart
expect(metrics.indexedQueryP95Ms, lessThanOrEqualTo(500));
expect(metrics.substringP95Ms, lessThanOrEqualTo(2000));
expect(metrics.progressFirstMs, lessThanOrEqualTo(1000));
expect(metrics.parseCancelFeedbackMs, lessThanOrEqualTo(2000));
expect(metrics.logicalDigestAfter, metrics.expectedDigest);
```

`metrics`由基准程序记录真实计时；native峰值内存用平台进程工具，Web分别记录页面/worker可观察指标，不混成统一RSS。桌面导入≤10分钟、Android≤20分钟；桌面≤1GiB、Android≤512MiB。无法测量标BLOCKED，不当PASS。

- [ ] 验证实际磁盘不足、配额拒绝、只读存储、卷恢复、备份失败、强制终止、无效写锁和长导出持有快照的空间开销。调优顺序为缩卷/释放对象/索引与批量读/有界流式解析，禁止放宽正确性或静默删历史。
- [ ] `dart test test/large_data_test.dart`及真机基准通过，固化工作集参数与依赖版本；未达到的首版平台不放行。提交基准、原始结果与解释。

### T12：三端发布矩阵与交接（M3）

**Files:** Create `apps/supplier_app/integration_test/release_loop_test.dart`、`docs/verification/release-matrix.md`、`docs/user-guide.md`、`docs/release-checklist.md`。

**Interfaces:** Consumes全部服务与固定fixture；Produces可安装Windows包、Android APK和可部署Web构建，以及验证报告。部署/分发按后续明确执行授权进行，本计划不把本地构建当上线。

- [ ] 执行Windows→Android→Web→Windows实际文件环路，每端导入、筛选000123-A、新增报价、退出重启、导出；比较未冲突业务及修订集合，验证A01—A18。
- [ ] Microsoft Excel和WPS分别往返业务表；日期精度、历史缺失、长编号、小数、同内容新增/纠错必须逐项比对。同步卷手动重存后应报损坏/不匹配，不走静默普通导入。
- [ ] 验证Web首次联网后断网重启、资源升级一致、浏览器退出重启、第二标签只读/可靠锁、下载失败、清库后的备份恢复；Windows和Android验证实际安装升级/文件权限/后台返回。
- [ ] `flutter analyze`、`flutter test`、`dart analyze`、`dart test`和各平台release build全部通过；独立code-reviewer和architect审阅修订、事务、导入与恢复，不以本设计评审代替代码审核。
- [ ] 指南说明备份与同步区别、历史例外、精度、冲突/筛重、磁盘不足及不支持项。发布检查点要求零已知数据丢失、误合并或错误持久化声明；保留fixture/hash/版本/真实输出。提交发行文档与证据。

## 需求覆盖与执行纪律

| 设计验收 | 实施与测试任务 |
|---|---|
| A01—A05 新建/历史/精度/精确值/身份 | T2、T4、T7、T8、T12 |
| A06—A07、A18 编辑回流与旧表回执 | T2、T7、T8、T12 |
| A08—A12 多端图/整包/并发/修复 | T3、T4、T5、T9、T10、T12 |
| A13—A14 恢复/浏览器生命周期 | T1、T3、T5、T8、T12 |
| A15 规模性能 | T6、T9、T11 |
| A16 三端真实环路 | T1、T10、T12 |
| A17 一致快照导出 | T5、T9、T11、T12 |

每项任务遵循失败测试→最小实现→针对性复测→检查诊断→独立可评审提交。每条源码步骤只实现当前任务契约，提交前列出实际修改路径，不能用`git add .`夹带现有小样或无关文件。若失败揭示接口需要变更，由当前集成负责人更新设计/公共契约及受影响测试后再继续。

初始估算以任务与退出门为准，不承诺没有设备基准支撑的日历工期；T1与T2完成后按实际吞吐给出排期，T11不能因时间压力省略。首版不包含iOS、增量包、后台网络同步及未报价流程。

## 计划自检

- [x] 已确认设计的全部18项验收均映射到任务。
- [x] 公共服务、源/目标、返回对象及错误类型集中定义，后续任务引用同名接口。
- [x] 原型已测、正式待开发、真机待验收三种状态分开。
- [x] 数据库与单卷容量分离；一致快照导出和全包原子导入有独立测试。
- [x] 历史缺失、日期精度、来件/操作双指纹均有具体反例测试。
- [x] 任务按文件责任和依赖可分工；不让UI、Excel及同步同时修改权威写入内核。

本轮实际文档验证（2026-09-17）：12项任务顺序完整；5份设计/研判/计划文档本地链接及空白检查通过；JSON报价fixture可解析；提取公共Dart契约单独执行`dart analyze`，结果No issues found。该检查仅验证接口声明语法，不代表任何待开发服务或任务测试已经实现。

推荐后续执行采用原生子代理按上述文件所有权推进，每任务先规格检查再代码审核；也可按相同依赖在本任务逐项执行。此处交付开发计划，不启动实现。
