# Supplier Hub / 公司资料中心

首批 Rust 中心端：明确发布供应商和历史报价，查询来源与版本，按配置将全部已发布资料通过指定目录单向投递到内网。客户端的本地数据库和现有交换方式保持独立。

提供内嵌 Web 管理端、HTTP API、CLI 和目录后台任务。管理页面沿用现有询价台账的颜色、侧栏、表格与详情模式，支持桌面和窄屏、系统深浅色。无需 Node 或独立前端服务即可部署。Flutter 中心资料页、技术要求自主选型、附件交换和项目成果专用发布是后续范围。

## 本机运行

需要 Rust 1.93.1 和目标平台 C 编译工具（用于 bundled SQLite）。以下命令在本目录运行。

```sh
cargo build --locked
cargo run --locked -- serve examples/local.toml
```

浏览器打开 `http://127.0.0.1:8080/admin/`（根路径也可进入）。配置访问令牌时在页面连接框输入；令牌只保留在当前页面内存中，刷新或断开后清除，不存入浏览器持久存储。

### 管理端页面

- **工作台**：共享资料、保留版本和交换记录统计，以及常用入口。
- **供应商 / 历史报价**：关键词检索、分页、包含已撤回筛选；报价保留精确金额字符串、供应商、型号与询价条件。详情可查看完整关联资料和发布历史。本中心当前版本可经确认撤回或恢复；历史版本和外部中心资料只读。
- **发布资料**：选择 Dart 桥接工具生成的 JSON，服务端仅校验预览；查看正文与关联范围并明确勾选后，点击确认发布才写库。失败重试复用原发布身份，避免重复创建。
- **同步与交换**：实际配置和最近一次本地任务结果；不把投递计数当作远端接收确认。
- **服务设置**：只读查看当前配置、连接和诊断信息。交换开关与目录仍通过 TOML 修改并重启，不提供假开关。

前端文件位于 `web/`，通过 `include_str!` 编入可执行文件；修改后重新构建、重启服务并刷新浏览器。公开静态页面不含业务数据；所有业务接口仍使用原有令牌鉴权。页面禁用内联脚本与外部资源，业务内容作为文本呈现。

另一个终端发布示例资料并检索：

```sh
curl --fail-with-body -H 'Content-Type: application/json' \
  --data-binary @examples/supplier.json http://127.0.0.1:8080/v1/publications
curl --fail-with-body 'http://127.0.0.1:8080/v1/publications?kind=supplier&limit=20'
```

默认仅监听回环地址、关闭双网同步，不需要交换目录。配置路径相对 TOML 文件解析。正式部署应自行生成稳定且唯一的中心 UUID v4，不能给两个独立中心使用同一个 ID；程序拒绝用不同中心 ID 打开同一中心数据库，也拒绝把客户端或其他应用数据库初始化为中心库。

配置 `HUB_API_TOKEN` 后，所有 `/v1` 接口都要求 `Authorization: Bearer <token>`；令牌至少 32 字节且不能包含空白。非回环监听强制配置令牌。共享令牌代表该部署的接入权限，不代表单个同事身份；共享者评价来自发布内容，不能当作已核实的个人身份。跨机器访问建议在现有 HTTPS 反向代理后运行服务，令牌不应经不可信的明文网络传输。`/healthz` 只返回进程就绪，不包含业务数据。

## 双网部署

```text
本网客户端 → A 中心 → A outbox → 既有单向文件搬运 → B inbox → B 内网中心
                                                    内网客户端 ↔ B 中心
```

两端运行同一个可执行文件，分别参考 `examples/source.toml` 和 `examples/intranet.toml`。由运维预先在两端配置相同的 `HUB_SYNC_KEY`（至少 32 字节的随机密钥）；B 的 `trusted_origin` 必须是 A 的中心 UUID。API 令牌可以两端不同。密钥通过环境注入，不放进 TOML 或交换文件。

```sh
# 在各端的运行环境中安全设置 HUB_SYNC_KEY 和所需的 HUB_API_TOKEN。
# B 的目录由文件搬运设施管理，启动前先创建。
mkdir -p data/inbox
./target/debug/supplier-hub serve examples/source.toml
# 在内网端运行：
./target/debug/supplier-hub serve examples/intranet.toml
```

`[sync]` 配置：

| 字段 | 含义 |
| --- | --- |
| `enabled` | 开关，默认 false；修改后重启生效 |
| `role` | `export` 或 `import`，每实例单一跨网方向 |
| `directory` | 本角色的投递/接收目录 |
| `trusted_origin` | 导入时必填的来源中心 UUID |
| `interval_seconds` | 扫描/生成周期，1–86400 秒，默认 30 |
| `resend_seconds` | 已导出的每个发布版本再次投递的间隔，默认 86400 秒 |
| `max_files_per_tick` | 每次处理上限，1–1000，默认 50 |

服务重启或首次开启时，未导出的存量与关闭期间发布的版本自动进入任务。开启后全部已发布版本参与投递，没有额外跨网勾选；客户端未发布的草稿不在其中。关闭不会删除既有投递文件，外部搬运机制可能继续搬运。

可单次运行后台任务，供诊断或外部调度器使用：

```sh
./target/debug/supplier-hub tick examples/source.toml
./target/debug/supplier-hub tick examples/intranet.toml
```

单次导入遇到坏文件会继续处理其他文件、记录失败并返回非零退出码。常驻服务下一轮仍会检查半包或修复后的文件。不要同时启动多个调度器操作同一目录/数据库；首版按每中心单实例部署。

### 文件合同与恢复

`.hubpkg` 为 UTF-8 JSON 封装，单个包包含一个完整的发布快照及其必要关联记录。不是旧的 SQLite 交换文件，不能直接交给客户端的旧文件导入界面。

- 协议版本、包 UUID、来源、原始载荷和内容摘要均参与 HMAC-SHA256 校验；摘要单独不证明来源。
- 一个载荷最多 1 MiB、256 条记录；封装最多 4 MiB。不解压归档，不接收附件或任意文件路径。
- A 在投递目录旁的暂存目录生成完整文件，文件刷盘后原子放入投递目录；目录需位于普通本地文件系统且其父目录可写。目录访问权限由运维配置，程序不强制设置私有权限。程序只生成自己的 UUID 文件名，不覆盖已有包；Unix 额外同步目录元数据，其他平台的断电持久性仍需目标环境验证。
- B 对常规 `.hubpkg` 文件进行有界读取，以内存中的完整副本校验，忽略符号链接；半文件或非法包不会半入库。接收目录必须由可信运维/搬运进程管理，此检查不提供对恶意文件系统所有者的隔离。
- 接收账本与发布记录在一个数据库事务提交。重复包、不同文件名的重投、不同包携带相同发布版本均幂等；相同版本不同内容拒绝。
- 旧版本晚到只增加历史，不能覆盖较新版本。资料按来源中心区分，A 的更新不覆盖 B 本地发布的资料。
- 导入按持久文件名游标轮转，坏文件不会永久阻塞后续文件；重启重扫并使用持久账本去重。
- A 只记录“文件已投递到目录”，不宣称 B 已接收。B 独立记录导入结果。

首版不清理 outbox、inbox 或历史版本。每个保留版本定期重新投递，相当于持续分批补齐保留资料，尚无单独的压缩全库基线包。重复投递会增长目录文件与接收账本，运维须按容量和最长中断窗口制定保留策略；先验证接收与备份，再清理文件。若原始资料和可重发文件均已被删除，程序不能恢复它们。服务不能从无回程链路判断接收端具体缺了哪些包。

## 发布与检索 API

| 接口 | 行为 |
| --- | --- |
| `POST /v1/publications` | 接收一个 `PublicationDraft`，来源由服务端中心 ID 赋值；新版本 201，相同重试 200，不同内容或跳版本 409 |
| `POST /v1/publications/preview` | 验证完整合同并返回规范化草稿、标题与记录数；不写数据库 |
| `GET /v1/publications` | 当前版本列表，默认隐藏已撤回；支持 `q`、`kind=supplier\|quotation`、`supplier_id`、`limit`、`offset`、`include_withdrawn=true` |
| `GET /v1/publications/{origin}/{id}` | 完整当前快照；`?revision=N` 获取指定历史版本 |
| `GET /v1/publications/{origin}/{id}/history` | 分页历史版本摘要 |
| `GET /v1/status` | 本地存储统计和目录任务结果；不包含密钥或远端回执 |
| `GET /healthz` | 进程就绪探针 |

列表默认 20 条、最多 100 条。`q` 最多 200 字符，按文本子串检索（不是语义搜索）；字面 `%` 和 `_` 不作为通配符。不换算汇率、不平均不同条件的价格、不生成虚构可靠度评分。供应商已有评级与说明、报价日期/税价口径等作为来源事实呈现，实际使用时应核对有效期和条件。

发布合同见 `examples/supplier.json`：

- `publication_id`：发布对象 UUID v4，首次发布自行生成，后续修订复用。
- `revision`：该中心内此发布对象从 1 连续增加；独立于客户端 `source_version`，不能直接使用多设备本地版本作为全局顺序。
- `withdrawn`：新发布版本设置 true 表示撤回，当前搜索隐藏，历史及既有引用保留；不会删除另一端独立资料。
- `root`：明确选择的 supplier 或 quotation。
- `records`：当前记录快照，含实体类型、UUID、客户端版本和原始 `data`；必要引用必须齐全，不接受无关记录。

首版接收关联类型 supplier/contact/product/project/quotation/project_item/inquiry。金额、税率与数量使用十进制字符串，保留 Dart 当前精度；不使用浮点价格。Rust 校验已覆盖字段类型、大小、引用、核心金额与日期条件，不声称完全重现所有客户端业务规则。`product_param/spec_*`、附件传输尚未实现，遇到不支持的内容明确拒绝。

## 从现有客户端数据库选取资料

在 `packages/supplier_core` 目录运行：

```sh
dart run tool/hub_export.dart /path/to/supplier.db quotation \
  <记录UUID> <发布UUID> 1 > publication.json
```

工具只读打开当前 schema 10 数据库，使用现有校验与引用关系读取一致快照；不迁移、不修改数据库、不导出字段变更历史、不自动上传。它会在 stderr 列出记录范围。检查 JSON 后再通过 `POST /v1/publications` 明确发布。

选择供应商不自动扩展所有联系人；选择报价会带入其引用的物料、供应商、项目和相关资料。若报价引用询价，该询价引用的供应商及清单也属于必要闭包，务必核对范围。报价正文中的联系人快照、询价人和备注属于所选资料正文，会保留。非空附件引用会报错，不能静默剥离附件后冒充完整报价。

## 备份与恢复

```sh
./target/debug/supplier-hub backup examples/local.toml /backup/hub-20260929.sqlite
```

采用 SQLite 在线备份接口并执行完整性校验；目标必须不存在。不要直接复制正在使用的主数据库文件而遗漏 WAL。

恢复时停服务，保留旧数据库及其伴随文件，把已验证备份复制到一个新的数据库路径，配置该路径并保留原中心 ID 后启动。备份包含发布历史、接收账本和导出进度。文件目录与密钥需要独立保留；B 恢复后可重扫仍然存在的包，A 恢复后可能重复投递，由 B 去重。不要同时运行恢复副本与原实例并共用中心身份。

## 验证

```sh
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked
cargo build --locked
python3 tool/smoke_test.py target/debug/supplier-hub
```

管理端开发检查（Node 22，仅测试需要）：`node --check web/app.js`、`node --experimental-default-type=module --test web/app.test.mjs`。页面设计和浏览器验收记录见 `docs/design/2026-09-29-hub-admin-ui.md`。

跨语言测试：先运行 Dart 的 `test/hub_export_test.dart`，设置 `HUB_EXPORT_FIXTURE=/tmp/hub-quote.json`；再给烟测加 `--quote-json /tmp/hub-quote.json`。烟测使用临时数据库、随机测试凭据和本机端口，验证两进程目录传输、半文件、重复导入、强制重启、关闭再开启补投、备份恢复和原始报价精度。

实际运行结果记录在 `docs/superpowers/plans/2026-09-29-central-hub-v1.md`。CI 配置用于 Linux/macOS/Windows 验证，不代表这些平台已在本次本机运行中全部验证。真实跨网搬运设备、长期运行规模和正式部署还需在目标环境验收。
