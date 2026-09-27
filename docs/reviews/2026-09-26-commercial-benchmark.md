# 询价台账：对标成熟商用软件（第二轮调研）

日期：2026-09-26
上一轮：[2026-09-26-benchmark-review.md](2026-09-26-benchmark-review.md)（以开源软件和方法论为主）。本轮只看成熟的商用产品，并据此修正上一轮的结论。

资料可信度说明：SAP、Oracle、金蝶、Procore、Sage 的内容主要来自官方帮助文档或培训材料，可信度较高。Coupa、用友、甄云、企企通、Precoro 的内容多为厂商宣传，只用来看"它们认为什么重要"，不作为功能事实。

---

## 一、调研对象

| 产品 | 类型 | 本轮关注点 |
|---|---|---|
| SAP S/4HANA 采购（采购信息记录、ME49 报价比较） | 大型 ERP | 价格记录的数据模型：有效期、数量阶梯、毛价/净价/有效价 |
| SAP Ariba Sourcing | 寻源平台 | 比价分析、对照历史价和预算、授标方案（含拆分授标） |
| SAP MDG / Oracle Product Hub | 主数据治理 | 查重的时机、阈值和合并策略 |
| SAP Mobile Offline OData / Dynamics 365 Field Service | 离线同步 | 冲突怎么检测、怎么交给用户处理 |
| Coupa Sourcing Optimization | 寻源平台 | AI 报价归一化为成本构成、授标决策留痕 |
| Procore Bidding | 工程投标管理 | 标准化报价表单、调平比较、缺项与不含项、预授标 |
| Sage Estimating / Autodesk ProEst | 工程估算 | 价格库更新是否影响已有估算、生效日期 |
| 广联达 广材网 / 云计价 | 国内造价 | 价格来源分类、多期加权、企业价格库 |
| 金蝶云星空 采购价目表 | 国内 ERP | 价目表的生效与失效、数量区间、取价优先级、价格来源控制 |
| 用友 BIP 采购云、甄云、企企通 | 国内 SRM | 历史成交价比对、一物一码与 AI 比价的关系 |
| Precoro / Procurify | 中小企业采购 | 小团队需要什么、不需要什么 |

## 二、商用软件的核心做法（每条都附出处）

### 1. 核心对象是"价格记录"，而不是一张张零散的报价单
- **SAP 采购信息记录**：以"供应商 × 物料"为单位，价格条件带有效期，可以设置数量阶梯；报价或订单里的条件可以自动回写到信息记录。价格分三层：毛价、净价（扣除折扣、加上附加费）、有效价（再加运费和不可抵扣税）。
- **金蝶采购价目表**：按"组织 + 币别 + 供应商 + 物料 + 单位"定价，生效区间包含生效日、不包含失效日，数量区间同样有明确的边界规则。取价时，指定了供应商的价目优先于通用价目；比价结果可以直接"更新价目表"，并记录最近调价日期。系统参数里还可以控制价格来源：不控制、仅预警、强制按价目表取价。
- **Odoo、ERPNext**（上一轮）：订单确认后自动记下成交价，下一次询价时给出参考。

**共同点**：报价只是过程，经过确认的成交价或协议价才是日后取价的依据。

### 2. 比较的是"有效价"或"总成本"，不只是单价
- SAP ME49 可以把折扣、运费等条件计入比较，并给出"平均价报价"和"最低价报价"作为参照。
- Ariba 可以按总成本排名，并把报价与历史支出、基准预算对照，显示偏差。
- Coupa 用 AI 把供应商的 PDF 报价拆成材料、人工、模具、管理费等成本构成后再比较。
- ERPNext 的文档专门提醒：单价低但运费高的供应商，总成本可能更贵。

### 3. 先把报价范围标准化，再谈调平比较
- Procore 用"报价表单"规定每家都要按同一套行项报价，分为基本报价和替代方案两部分。调平时能直接看到每家的缺项和不含项，允许对缺项做补齐调整后再比较，也能追踪某一家报价从提交到签约的变化。
- 可以先"预授标"（只标记为已授标、暂不签合同），授标后会立即更新预算。

### 4. 授标是一条明确的决策记录
- Ariba 支持单家授标、按行拆分授标，也支持"最低总成本"这类优化方案；授标可以走审批。
- Coupa 保留从设置、沟通、提交、评估、审批到授标的完整审计轨迹。
- Precoro 在 2026 年 8 月推出了按行的比价矩阵：每一行高亮最低价，可以整单授给一家或按行拆分，授标结果自动带入采购订单。

### 5. 查重发生在新建和导入时，清理时不做硬删除
- Oracle Product Hub 在新建、编辑、导入物料时都会弹出疑似重复。系统参数决定是否允许在找到匹配时仍然新建；导入时，管理员可以选择"更新已有物料"而不是新建。从业者的经验是：重复物料通常不直接合并，而是停用重复项，再用交叉引用和替代关系把它们连到保留项上。
- SAP MDG 设有两个阈值：高于下限算"疑似重复"，高于上限算"相同"，但两种情况都会交给人确认。字段可以按模糊程度和权重打分。有一个已知的坑：如果把几个字段分别做模糊匹配后按"或"组合，只有一个字段相似也会被判为重复。

### 6. 离线同步：不要"最后写入者胜出"，冲突要交给人处理
- SAP Mobile Offline OData 用版本标记检测冲突，被拒绝的修改放进"错误档案"，由用户查看和处理。SAP 明确不推荐"后写覆盖"，因为会丢数据。它更推荐从流程上避免冲突，例如同一条记录只指派给一个人编辑。
- Dynamics 365 Field Service 只能按整条记录检测冲突：技术员改了开始时间、调度员改了结束时间，也算冲突。这是颗粒度粗的反面例子。

### 7. 价格库更新不回改已有估算，改动都有生效日期
- Sage Estimating 批量更新价格只影响之后新建的估算，已有估算不变；更新前可以预览，可以暂停、撤销，官方建议先备份。第三方最佳实践还要求每次调价都写明生效日期和说明，避免"静默修改"。
- 广联达的材料价格分为信息价（政府造价站发布）、专业测定价（多渠道加权）、市场价（厂商真实报价，带来源），可以按多期加权平均载入；人工询价明确标注"仅供参考，不作为结算依据"。

### 8. 国内 SRM 的 AI 比价，都建立在"一物一码"之上
- 企企通接入 DeepSeek 后，宣传重点是先做物料主数据治理（智能去重、属性补全、一物一码），再做多供应商比价。
- 用友的 AI 助理在比价时会调出各供应商的历史成交价，判断本次报价是否偏离。
- 甄云的宣传也集中在"历史价格 + 市场行情"辅助定价。
- 可以得出的结论是：没有干净的物料数据，AI 比价就无从谈起。

## 三、对照现状：新发现的问题

以下问题是上一轮没有覆盖，或者这一轮用商用软件的证据修正了判断的。

**C1（P0）系统里只有"报价"，没有"成交价"或"价目"。**
- 现状：预算取的是"最低有效报价"。可报价往往是谈判前的开价，最终成交价通常更低，而成交价在系统里无处记录。
- 后果：
  - 历史价格库（上一轮的 P1-8）只能建立在开价上，参考价值打折扣；
  - "有更便宜报价"的提醒是拿开价和开价比；
  - 决算时也无法对比"预算和实际"。
- 商用做法：SAP 的信息记录、金蝶的价目表、Odoo 的供应商价格表，都会由确认或授标自动更新价格记录。
- 建议：新增"定标价"，即授标时确定的价格（可以不同于报价）。定标价带生效和失效日期，写入"供应商 × 物料"的价格记录。预算取价顺序为：本项目的定标价 → 有效的价格记录 → 最低有效报价。

**C2（P0）预算取价和比价都没有考虑起订量。**
- 证据：`budget.dart` 和 `compare.dart` 中都没有用到 `min_qty`。
- 后果：一条起订量为 100 的报价会被用在只需要 2 台的项目上，成本被低估，而且界面上没有任何提示。SAP 和金蝶都把数量阶梯或数量区间作为取价条件。
- 建议：预算取价时跳过起订量大于项目数量的报价；比价页显示起订量，并把"不满足起订量"列为排除原因。改动很小，收益很直接。

**C3（P0，修正上一轮的 P0-1）合并重复数据时不能直接删除。**
- 证据：导入时的引用检查（`checkAllReferences`）只看被引用的记录是否存在，被删除的记录仍然作为"墓碑"保留在库里。
- 后果：假设 A 机把重复的供应商 S2 合并到 S1 并删除了 S2，而 B 机上仍有引用 S2 的报价。这些报价导入到 A 机后会被标成"供应商已删除"，并悄悄退出最低价的比较。
- 商用做法：Oracle 的经验是停用重复项，再用交叉引用把它连到保留项。
- 建议：合并时，把被合并的记录标记为"已并入 X"并保留下来；所有读取和比较都沿着这个标记找到 X；导入时遇到引用被合并记录的数据，自动改指向 X。"已并入"标记本身也随交换传播，这样合并在所有设备上都能收敛到同一结果。

**C4（P1）比较的只是单价，而不是有效价。**
- 现状：报价只有一个价格字段。运费、安装调试、包装、质保等"含不含"的信息只能写进备注，无法参与比较。
- 商用做法：SAP 区分毛价、净价、有效价；Ariba 比总成本；Procore 调平时专门处理缺项和不含项。设备类报价最常见的差别恰恰是"含不含运输、安装、调试"。
- 建议：
  - 报价增加结构化的"包含项"勾选：运输、安装、调试、培训、税费，以及质保年限；
  - 增加可选的"附加费用"字段；
  - 比价时显示"有效单价 = 单价 + 附加费用 ÷ 数量"，并把"不含安装"这类差异高亮出来；
  - 智能导入提取时一并识别这些字段。

**C5（P1，强化上一轮的 P1-10）需要一张标准化的询价表单，并记录授标。**
- 商用做法：Procore 的报价表单（基本报价加替代方案）、ERPNext 的询价单、Ariba 和 Precoro 的授标。
- 建议：
  - 询价批次 = 项目 + 行项（名称、规格要求、数量，可以直接用预算中"待询价"的行）+ 邀请的供应商 + 截止日期；
  - 导出给供应商的 Excel 行项是固定的，回收时能自动对上行；
  - 比价用行 × 供应商的矩阵，每行高亮最低有效价，标出缺项；
  - 授标可以按行拆分，写入定标价（见 C1）并回填预算，同时要求填写理由。
- 这一条会把现有的"待询价清单导出""报价模板导入""比价""预算"四个孤立功能串成一条链。

**C6（P1，细化上一轮的 P0-2）交换冲突要有一个"冲突箱"，并且可以指定负责人。**
- 商用做法：SAP 的错误档案，以及"用流程避免冲突"（同一条记录只由一个人维护）。
- 建议：
  - 在字段级合并之外，把"同一字段两边都改过"的情况放进"冲突箱"，列出双方的值、设备和时间，由用户选择保留哪个；
  - 可选地给供应商和物料设置负责人：冲突时默认采用负责人的修改，其他人的修改进入冲突箱。
- 对 30 个人来说，这比任何自动合并算法都更容易理解。

**C7（P1）新建时就应该查重，而不只在导入时查。**
- 现状：只有智能导入会列出候选；手工新建供应商或物料时没有任何查重提示。
- 商用做法：Oracle 在新建、编辑、导入三个入口都会查重，并且可以配置为"发现匹配时禁止新建"。SAP MDG 分"疑似"和"相同"两档阈值。
- 建议：在新建表单上实时显示"可能已存在"的列表，可以一键改为使用已有记录；"相同"级别（统一写法后型号相同）默认阻止新建，需要确认才能继续。

**C8（P2）价格没有区分来源和性质。**
- 商用做法：广联达把价格分为信息价、测定价、市场价，并注明"仅供参考"；金蝶可以强制只用价目表取价。
- 建议：报价增加"价格性质"：正式书面报价、口头或聊天询价、网上参考价、历史成交价。预算默认只采用正式报价和定标价，其余性质的价格只作参考并显示出来。现有的 `capture_mode`（标准 / 历史）不能表达这层意思。

**C9（P2）预算缺少"按新价刷新"。**
- 已做对的：新报价不会自动改动预算中已关联的价格，只给出"有更便宜报价"的提醒，这与 Sage 的做法一致。
- 缺的是：Sage 支持批量更新前预览、撤销；目前只能逐行手改。
- 建议：提供"按当前最优价刷新"，先预览每行的新旧价格差异，确认后在一个事务里写入，并记录成一次调价（附说明）。

## 四、商用软件印证了"已经做对的"部分

| 做法 | 本项目 | 商用对照 |
|---|---|---|
| 新价格不自动改动已有预算，只做提醒 | ✓ | Sage Estimating |
| AI 只做第一遍，写入前必须人工确认 | ✓ | Coupa、BidLevel、Procurify AI Intake 都保留人工复核 |
| 只比较币种、含税口径、单位都相同的报价，并说明不参与的原因 | ✓（但口径太窄，见 C4） | SAP ME49、ERPNext 都要求先统一口径 |
| 导入前先预览、全部成功才写入（事务） | ✓ | Sage 批量更新前预览，Oracle 导入工作台 |
| 精确小数，不用浮点 | ✓ | 所有 ERP 的金额字段都用定点数 |

## 五、商用软件的功能中，明确不做的

- 供应商门户、在线投标、反向竞价、审批流、采购订单、收货、三单匹配：都需要服务器或超出定位（Ariba、Coupa、Precoro 的主体功能都在这里）。
- 授标优化求解（Ariba、Coupa 的约束优化）：30 人团队、以设备类为主的询价，用"按行最低有效价 + 人工拆分"就够了。
- 外部行情和价格库订阅（广联达 VIP 市场价、期货行情）：需要付费数据源，可以日后通过导入 Excel 对接，不内置。
- 带模糊打分权重的主数据治理平台（SAP MDG）：用"统一写法后精确比较 + 名称互相包含"作为疑似重复的判断就够用。

## 六、修订后的路线

在上一轮阶段 A、B、C 的基础上调整如下（★ 为本轮新增或提前的项目）：

**阶段 A：推广前必须完成**
1. ★ 取价考虑起订量（C2）：改动小、风险高，最先做。
2. ★ 重复数据用"已并入"标记和改指向来合并，禁止硬删除（C3）；新建和导入时查重（C7）。
3. 交换改为字段级合并，并增加冲突箱（上一轮 P0-2，本轮 C6）。
4. 数据格式迁移，兼容旧版本（上一轮 P0-4）。
5. 每天自动快照，并先用 3 到 5 台设备试点。

**阶段 B：让价格可信**
6. ★ 定标价和价格记录（C1）：预算优先取定标价。
7. ★ 报价的包含项和附加费用，比价显示有效单价（C4）。
8. 询价批次 → 行 × 供应商比价矩阵 → 按行授标 → 回填预算（C5，替代上一轮的 P1-10）。
9. 历史价格参考（最高、最低、平均、最近一次定标价）与偏离预警（上一轮 P1-8，基于定标价会更可靠）。
10. 报价附件和智能导入的原文出处校验（上一轮 P0-5、P1-6）。

**阶段 C：覆盖与体验**
11. 价格性质（C8），以及"按新价刷新"预算，先预览再写入（C9）。
12. PDF 和截图输入、共享文件夹同步、交换文件加密、物料类别与关键属性、拼音搜索、安装包签名与更新（沿用上一轮）。

## 七、结论

商用软件印证了上一轮的判断：主数据质量和多设备同步是地基。本轮额外暴露出三处价格口径上的硬伤，它们会直接让预算数字失真：

1. **没有成交价**：一直在拿开价当成本。
2. **忽略起订量**：会系统性地低估小批量项目的成本。
3. **只比单价**：看不见运费、安装等"含不含"的差异。

其中起订量问题只需要改几十行代码，建议立即修复。定标价和询价批次是把现有功能串成一条链的关键，建议作为下一阶段的核心。

## 参考

- SAP：[Purchasing Info Record - Conditions](https://help.sap.com/docs/SUPPORT_CONTENT/spmm/3362167609.html)；[Analyzing Price Determination Basics](https://learning.sap.com/courses/purchasing-in-sap-s-4hana/analyzing-price-determination-basics)；[Working With Purchasing Info Records](https://learning.sap.com/courses/sourcing-in-sap-s4hana/working-with-purchasing-info-records)；[ME49 Price Comparison](https://www.learntosap.com/mmtutorialpricecomparison.html)
- SAP Ariba：[Bid Comparison UI](https://help.sap.com/docs/strategic-sourcing/event-management/bid-comparison-ui)；[Using Bid Analysis to Award](https://learning.sap.com/courses/project-monitoring-and-event-administration-within-sap-ariba-guided-sourcing/using-bid-analysis-to-award-guided-sourcing-events)；[Optimization Scenarios](https://learning.sap.com/courses/project-monitoring-and-event-administration-within-sap-ariba-guided-sourcing/using-optimization-scenarios-to-award-guided-sourcing-events)；[Ariba Sourcing Features](https://www.sap.com/products/spend-management/ariba-sourcing/features.html)
- SAP MDG / Oracle：[Performing Master Data Duplicate Checks with SAP MDG](https://blog.sap-press.com/performing-master-data-duplicate-checks-with-sap-mdg)；[Configure Matching and Duplicate Check](https://help.sap.com/docs/SAP_S4HANA_CLOUD/f86dc2eb1f8b48c880a7607213104b27/ab145787dc06470bb127e4f0375d01c7.html)；[SAP KBA 3394515](https://userapps.support.sap.com/sap/support/knowledge/en/3394515)；[Oracle: How Items are Matched](https://docs.oracle.com/en/cloud/saas/supply-chain-and-manufacturing/26a/fapim/how-items-are-matched.html)；[Duplicate Data in Oracle ERP](https://www.cleverence.com/articles/oracle-documentation/duplicate-data-in-oracle-erp-4827/)
- 离线同步：[SAP Offline OData: Handling Errors and Conflicts](https://help.sap.com/doc/c2d571df73104f72b9f1b73e06c5609a/Latest/en-US/docs/user-guide/odata/Offline_OData_Handling_Errors_And_Conflicts.html)；[SAP Offline Overview](https://help.sap.com/doc/f53c64b93e5140918d676b927a3cd65b/Cloud/en-US/docs-en/guides/features/offline/overview.html)；[Dynamics 365 Field Service offline sync](https://learn.microsoft.com/en-us/dynamics365/field-service/mobile-power-app-system-offline-sync)
- Coupa：[Coupa Sourcing Optimization](https://www.coupa.com/products/source-to-contract/advanced-sourcing-optimization/)；[Direct Material Sourcing](https://www.coupa.com/products/direct-material-sourcing/)；[Strategic Sourcing](https://www.coupa.com/products/source-to-contract/sourcing/)
- Procore：[Construction Bid Leveling](https://www.procore.com/library/construction-bid-leveling)；[Level Bids for a Bid Form](https://support.procore.com/products/online/user-guide/project-level/bidding/tutorials/level-bids-for-a-bid-form)；[Bid Leveling Beta](https://support.procore.com/products/online/user-guide/project-level/bidding/tutorials/join-the-open-beta-for-bid-leveling)
- Sage / ProEst：[Updating database prices by category](https://help-sageestimating.na.sage.com/en-us/23_1/Content/pricing/updating_database_prices_by_category.htm)；[Update Sage Estimating Database](https://www.cleverence.com/articles/sage-documentation/update-database-sage-estimating-help-4271/)；[ProEst Unit Cost Databases](https://proest.com/explore/rsmeans/unit-cost-databases/)
- 广联达：[广材数据服务](https://www.glodon.com/product/209.html)；[广材网](https://www.gldjc.com/)；[广材助手帮助中心](https://gczs.gldjc.com/index.html)；[云计价 GCCP5.0](https://aecore.glodon.com/doc/GCCP5/4f7aba3744664e559accd6ce35ce140b)
- 金蝶：[采购价目表（产品手册）](https://help.open.kingdee.com/dokuwiki/doku.php?id=%E9%87%87%E8%B4%AD%E4%BB%B7%E7%9B%AE%E8%A1%A8)；[采购管理系统参数](https://help.open.kingdee.com/dokuwiki_std/doku.php?id=%E9%87%87%E8%B4%AD%E7%AE%A1%E7%90%86%E7%B3%BB%E7%BB%9F%E5%8F%82%E6%95%B0)；[价目表取价逻辑说明](http://www.tdxsoft.com/m/show.asp?id=6676)；[云星空 V8.1 发版说明](https://cdn037.yun-img.com/static/upload/asdert/team/20230619132805_31288.pdf)
- 用友 / 甄云 / 企企通：[用友 BIP 采购云](https://yonyou.com/subject/caigou-liucheng?withYonyouMenu=&zixun=0)；[用友 AI 寻源定价方案](https://www.yonyou.com/subject/caigou-liucheng/news/5722)；[甄云科技](https://www.going-link.com/)；[企企通接入 DeepSeek](https://zhuanlan.zhihu.com/p/31022363323)
- 中小企业采购：[Precoro August 2026 Product Update](https://precoro.com/blog/august-2026-product-update/)；[Precoro RFP 帮助](https://help.precoro.com/how-to-create-a-request-for-proposal)；[Procurify Features](https://www.procurify.com/platform/features/)；[Precoro vs Procurify](https://www.erpresearch.com/erp-add-ons/procurement/precoro-vs-procurify)
