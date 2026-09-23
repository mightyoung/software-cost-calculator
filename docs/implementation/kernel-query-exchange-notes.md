# 内核、查询与交换交接笔记

日期：2026-09-17。独立代码审查通道的只读准备材料，供后续 owner 使用。
**不是完成实现、最终代码审查或平台发布结论。** 未据此批准未完成的 `data/**`；接口/依赖选择仍由主集成者协调。Windows/Android 实机验证按用户要求延期，不阻断当前准备工作。

## 依据与证据级别

- 批准契约：`.omx/plans/prd-supplier-ralplan.md` §§3.1–3.4、T3–T9。
- 验收：`.omx/plans/test-spec-supplier-ralplan.md`，尤其 A08–A13、A15、U03、I01/I02/I04/I07、O01。
- 业务规格：`docs/superpowers/specs/2026-09-16-supplier-inquiry-design.md` §§3、5、7、8。
- 任务细则：`docs/superpowers/plans/2026-09-16-supplier-inquiry.md` T3–T9。
- **运行证据**仅指已有测试/产物，不外推新适配器；**源码确认**指读取当前锁定版本实现；**候选路径**仍需实现、官方格式核对及运行验证。

## T3/T4 提交与持久图验收

1. **权威入口**：未安装正式 T4 验证器时产品提交拒绝；安装后正常路径与非法图均测试。fixture、公开可构造的诊断报告/预览令牌、恒成功回调不能成为正式授权。
2. **封存与绑定**：封存后修订、父边、决定不能静默修改并继续使用旧证明。首次图读取前绑定 instance/epoch/generation/job/sealed digest；扫描结束及持锁事务内复核，提交另核 decisions/schema/validator version/expected heads。分别测试篡改各字段、同 generation 换 instance、页间改根/head、恢复激活。
3. **锁序**：应用写锁 → 活动身份检查 → SQL 事务 → 再校验 → commit → unlock。不得 SQL 内等待应用锁；持锁备份不得重拿非重入锁；旧 epoch 连接不能写。
4. **一次原子提交**：revision/parent/head/projection/relation、成功批次、双回执与 generation 同一事务生效；每页只执行语句，不 commit。首/中/末页及 COMMIT 前故障后关闭重开，比较全部业务表和 generation；COMMIT 后响应丢失只返回原成功结果。
5. **确认幂等**：confirmation_event_id 在最终提交前持久登记并绑定封存决定；双击/重启复用同事件、同结果 ID。事件不得改绑其他 job/decisions；明确另一次询价才产生新事件。回执结果 cursor 重开后仍有效，不能指向已清理的临时图工作表。
6. **有界并集**：同 revision identity 去重且核对 canonical/hash，同 ID 不同内容拒绝；重复父边不能重复计入度。revision/entity/children/neighbors 使用稳定索引 keyset 页；roots/indegree/ready/visits/walks/anomaly/affected entities 留在数据库。单实体长历史、多 heads 也不能整批装入 Dart 集合。
7. **图语义**：持久适配器与独立小图 oracle 比较单 put 根、父同实体/闭包、全历史引用、无环、heads、当前 heads 的双向 redirect 分量。覆盖 100 seeded DAG、深链、宽 fan-out、重复并集；不按时间选胜者，不让已被后继取代的 redirect 污染当前分量。
8. **失败隔离**：stale/error 丢弃整轮工作表且不产生证明；cleanup 失败保留原始/清理错误及堆栈，并持久隔离 run，重开仍不能复用或发布。成功图报告也不是提交成功。
9. **结构与范围**：每个写连接启用 FK；schema/DDL 迁移原子，失败重开保留旧库；staging 不对业务查询可见且不递增业务 generation。T5 尚未接入时，不把裸提交称为完整非空库导入备份路径。

### 现有纯端口的接入陷阱

源文件：`packages/supplier_core/lib/src/contracts.dart`、`domain/revision_graph.dart`。

- `ValidatedChangeSet._()` 是 library-private；独立 `data/*.dart` library 不能直接调用。需协调真实权威边界，不能为绕过编译问题开放可信公共构造或生产 fixture bypass。
- `GraphBinding` 只有 database/job/sealedDigest，没有 decisions/schema/validatorVersion；`GraphValidationReport` 可公开构造且明确只用于诊断。两者不能单独替代完整内部提交证明。
- `GraphWorkspace.currentBinding()` 应读取真实当前元数据/封存身份；若只返回 `resetWork` 保存的值，末尾 stale 检查永远相等。固定快照可保留自己的版本，协调器仍须独立核对活动库。
- `GraphRevision(id, envelope)` 不检查 id 等于 canonical hash；这是适配器前置责任。测试 synthetic IDs 和 `INSERT OR IGNORE` 不能掩盖生产身份碰撞。
- `ScanPage` 只检查页大小/空页 cursor；validator 另检查 cursor 递增。排序、无重漏、binary collation、结束位置与索引覆盖由适配器保证。
- `findCommittedEvent(id)` 不表达事件绑定核验；幂等分支仍须核对持久事件归属。合法已提交重试应先被识别，不能因该事件自身提交已提升 generation 而仅返回 stale。

## T6 查询验收准备

### 筛选白名单与数据语义

设计 §7 明确的语义字段：供应商/联系人；产品名称/品牌/型号；项目名称/编号；询价日期范围/精度/缺失；询价人；报价日期；价格范围；历史缺失状态。最终 Dart 参数名尚未冻结。

T6 示例还明确 `product_id`、`view: history/confirmed_lowest`、`currency`、`unit_snapshot`、`as_of`；比价必须表达完整 tax_mode/min_qty/含税 tax_rate 口径。不要仅因 payload 存在 category/notes/inquiry_location/lead_time_days 等字段，就扩成任意字段 SQL 过滤接口。

- 复用 `domain/quotation.dart` 的 `missingContext`：项目名称和编号均为空才缺项目，另有询价人、询价日期、报价日期。价格不可缺；零价有效。historical 模式不等于仍缺字段。
- 询价日期使用保存的 `inquiry_date`，不随查看设备时区改变；date/instant 同日成组，unknown 可筛选；date 不伪造午夜参加日内排序。
- 原值保持 NFC、型号标点及编号前导零；候选 search key 可做 NFKC、大小写折叠、空白合一。exact/prefix 与 substring 分路。查询值参数绑定；作为文字的通配符须转义，输入不能控制字段或 ORDER BY。
- 候选返回稳定 ID、显示名和匹配理由，不返回自动合并决定。

### 比价分组与资格

- 分组为 canonical product + unit_snapshot + currency + tax_mode + canonical min_qty；included 再区分 tax_rate，null 不与已知税率混组。单位采用报价快照，不采用产品当前单位。
- confirmed_lowest 排除未知税制、未知/未来 quoted_on、过期、supplier/product 失效或关系异常、报价冲突。valid_until 未知显示待确认，不能称已确认有效；不因 historical 模式本身一刀切排除。
- 规格允许 tax_rate null，只要求含税时区分税率，未规定 null 一律拒绝；不要擅加该条件。联系人失效保留 contact_snapshot，不直接套供应商/产品的排除规则。
- 所有被排除记录仍在 history 可见；不能 inner join active-only 实体表而丢历史。canonical/当前关系状态来自 T4，不在 T6 另造图解析规则。
- 每供应商最新按 quoted_on，同日全部并列；ID 可稳定分页，不能判业务先后。最低价同价结果不能被任意 LIMIT 1 隐去。
- 价格排序/范围用 `domain/values.dart` 的 `ExactDecimal.sortKey`（12+6）及 `Quotation.priceKey`，不用浮点或 SQL REAL 比较。

### 游标与索引证据

默认 50 条，limit 1–200。cursor 包含完整 ORDER BY 键及最后实体 ID，seek 条件与排序方向/NULL 次序一致；先过滤排序再 LIMIT。固定数据的逐页串接应等于独立全序 oracle，覆盖同日、同价、空日期及 1/50/200 页界，关联加载须批量化。

**待接口冻结说明**：默认排序列、NULL 次序、跨业务写入分页采用 snapshot 还是 stale/其他明确语义。若一行对应一个 conflict head 而非一个 entity，单 entity ID 不足以唯一排序，须明确 head 身份尾键。上述细节不是现有规格已经选定的答案。

以下是应保存 EXPLAIN 的逻辑索引路径，不是要求盲建全部候选 DDL：

| 查询路径 | 需核对的索引列族/证据 |
| --- | --- |
| 产品比价、供应商历史与最新 | product/supplier/quoted_on 和稳定 ID；证明各常用前导条件均有路径，不能认为一个组合索引覆盖任意前导条件 |
| 项目编号、询价人组合筛选 | project_number search/equality key + inquiry_date + ID；inquirer key + inquiry_date + ID |
| 精确比价 | 全部等值口径 + price_key + ID；supplier latest 的 quoted_on 路径单独核验；状态/有效期条件是否 partial index 依冻结投影和计划决定 |
| 名称/型号/联系人候选 | supplier name/alias、contact 归属+姓名/联系方式、product name/brand/model 的 exact/prefix key；alias 多行应去重 |
| 每页关系与快照显示 | canonical supplier/product/contact 与 entity/type/state 的索引 join；不能逐行递归 redirect |

项目名称及单询价日期等实际查询按计划补足，不加未使用索引。substring 单独保存 EXPLAIN/耗时，不能缩小结果掩盖扫描成本。T6 交 query tests、固定种子 1万/10万 fixture、字段长度/重复分布/修订数、EXPLAIN 和初测；正式 p95/峰值结论属于 T11，见 test-spec 容量与性能节。

## T5/T7/T9 有界 ZIP/XLSX 本地源码调查

### 已有证据与可复用材料

- `prototypes/supplier_probe/pubspec.yaml` 锁 `excel 4.0.6`、`archive 3.6.1`、`xml 6.6.1`。本机缓存根：`/private/tmp/supplier-inquiry-toolchain/pub-cache/hosted/pub.dev/`。
- `prototypes/supplier_probe/lib/xlsx.dart` 的 CRC、实际展开计数、方法 0/8、加密拒绝，以及公式/重复坐标/行号/merged-cell 防护可复用为规则和回归素材。`test/probe_test.dart` 有对应负例；真实样本位于 `artifacts/supplier-probe/supplier-wps-roundtrip.xlsx`。
- 原型仍用整条目 `XmlDocument.parse`、Excel book 和 `encode()` 字节列表；旧 20MiB 整包/200MiB 展开默认不适用于正式按卷协议。WPS styles workaround 也不能直接搬成新的流式入口。
- 缓存 excel 的 `lib/src/excel.dart` 保留 XML map，`parser/parse.dart` 把 sharedStrings/worksheets 解析为 DOM，`save/save_file.dart` 最后返回整包 ZipEncoder 结果。`decodeBuffer` 不改变这个模型；没有可直接复用的 streaming workbook API。
- `prototypes/storage_gate/lib/file_gate.dart` 的范围读、临时输出/close/publish 与失败诊断有 macOS 私有目录测试证据；不是正式平台 InputSource/OutputTarget，不能外推 Web、任意用户目录或断电持久性。

### archive 3.6.1：源码确认的可用分支与陷阱

- `lib/src/zip_encoder.dart` 提供 `startEncode(OutputStreamBase)`、`addFile`、`endEncode`。`ArchiveFile.stream(name, size, InputFileStream)..compress=false` 走 STORE；CRC 及 `OutputFileStream.writeInputStream` 分块读取（1MiB），payload 写后引用清除。可逐卷文件加入外包，不用 `encode(Archive)` 的总包列表。
- `lib/src/io/zip_file_encoder.dart` 的 `addFile(file, name, ZipFileEncoder.STORE)` 是另一入口；仅 `create(level:0)` 不保证后续文件 STORE，addFile 默认压缩。`addDirectory` 的 listSync/Future.wait 不适合受控逐卷输出。
- 普通 compress 分支调用 `InputStreamBase.toUint8List()` 再压缩，不能把名字含 stream 当成有界证明。
- `lib/src/zlib/deflate.dart` 的 `Deflate.buffer(InputStreamBase, output: ...)` 可以连接文件输入/输出；尚未有本项目结束语义、取消、峰值证据。原生 SDK `lib/io/data_transformer.dart` 另有 `ZLibEncoder(raw:true)` 分块转换，但不能用于 Web。
- 预压缩条目可用 `ArchiveFile(name, uncompressedSize, compressedInputStream, ArchiveFile.DEFLATE)` 并设置原内容 CRC，走 `addFile` 的 compressed passthrough。CRC/真实原长度缺失可能触发内容物化；此组合只有源码确认，尚未运行验证。
- `ZipEncoder` 在 `_data.files` 保留全部中央目录元数据；`zip/zip_directory.dart` 会把整中央目录转 Uint8List 再建 fileHeaders。不是任意外包恒定内存。内层须在构建目录前校验 entry 数、目录字节与偏移；外层目录/manifest 也需持久分页/临时记录路径或明确有界证据，不能偷加总包大小限制。ZIP64 大偏移/大量卷兼容性仍需验证。
- `Inflate.stream` 的输出需要 `subset(-distance)` 提供 LZ 历史（`zlib/inflate.dart`），普通只写 sink 不能直接替代。OutputFileStream 有 subset，但性能/故障尚未实测。`inflateNext` 会捕获错误返回 null，不可直接作为严格 EOF/成功判据。

### xml 6.6.1：源码确认的事件接口

`lib/xml_events.dart` 提供 `Stream<String>.toXmlEvents(...)`、`XmlEventDecoder`、`XmlEventEncoder` 和 `Stream<List<XmlEvent>>.toXmlString()`；缓存 README 有流解析示例。必须显式开启 `validateNesting`/`validateDocument`，默认均为 false；需要定位时开启 withLocation。

直接消费事件，保留 cell 坐标、类型、v 的原始数值词法、style index 和 formula 存在性；不要把整 worksheet 转为 nodes/DOM。decoder 的 carry 保留未完成 token，小 chunk 不保证恶意长 token/depth 有界，需在扩大 token/文本聚合前执行预算并验证截断输入。以上尚非项目端到端 SAX 运行证据。

### 最小复用候选路径（非已选定实现）

1. 从同一快照 keyset scan，逐 row/cell 写 OOXML skeleton 与 worksheet 临时文件。事件编码转 UTF-8；导出 inlineStr 可避免全局 sharedStrings 字典，须核对 xml:space、转义、文本精度及 WPS/Excel 实际互操作。禁止整 sheet StringBuilder。
2. XML part 逐个落盘压缩，记录真实原长度/CRC，再走预压缩 ZIP passthrough；完成一个 xlsx 卷后计算最终字节 hash。最终卷含目录/headers 超 8MiB 时按原快照边界缩卷重试，不截断记录。
3. 外包逐卷 STORE 写入，manifest 与中央目录 metadata 也受工作集约束；完成自验和 close 后 publish，不保留所有卷字节或总包 Blob。
4. 导入从外包 range 读取单卷至持久隔离暂存，核对卷 hash；受检 inner directory 后逐 entry 计数解压落盘，再事件解析。sharedStrings 逐 si 写 job+index 持久表，worksheet 按索引查询；rich text 只在单 cell 限额内聚合。
5. styles/numFmt/relationships 同样受预算或落盘索引。保留 workbook date1904、1900 假闰日拒绝，金额不经 double；旧 stage0 全文本拒绝规则不能用于排除 T7 合法数字日期/科学计数输入。

### 预算、原子性与待验证事项

每卷最多 **5000 数据行、8MiB 最终 XLSX、32MiB 全 entry 实际展开、2048 内层 ZIP entries**，任一触顶分卷；header 另计。单 cell 32767 UTF-16、envelope 24000。单条仍超限则准确失败，不丢内容。声明量不能代替实际计数/CRC/hash；覆盖重复/异常路径、加密、方法、伪小元数据。

沿用 T5/T7/T9 的任务恢复与发布契约：首/中/末卷中断、未完成卷清理、单条超限、唯一长 strings、转义大 cell、close 失败和取消均须测试；所有卷验证后一次业务提交，输出自验后发布。

尚无本项目 streaming codec、最坏峰值或完整格式互操作通过证据。后续官方研究优先核对 OOXML inline/rich text/样式数值日期、ZIP64、XML tokenizer 边界及 Web 持久 sink/压缩/背压。包 metadata 指向官方源码：`github.com/brendan-duncan/archive`、`github.com/renggli/dart-xml`、`github.com/justkawal/excel`。本次只查本地锁定源码，未联网。
