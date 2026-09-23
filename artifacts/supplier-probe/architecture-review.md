# 阶段 0 独立架构评审

来源：原生 Architect 子代理 stage0_arch_review 最终返回；评审者只读，正文要点由主代理保存。

**CLEAR，仅针对隔离的 Dart 存储与 XLSX 小样。** 新增字段方案通过架构复核；初轮实现阻断均修复。独立执行 dart analyze 无问题，dart test 19/19 通过，退出码均为 0。此结论不代表四端发布、正式 DAG 同步或完整阶段 0 验收。

项目名称、编号、询价地点和询价人为报价快照，编号非唯一，询价人不是账户。时间以 UTC 毫秒和原始偏移配对，报价日期独立。独立 stage0 格式/schema2 与仅空库恢复边界正确。正式 v2 混合历史仅为可行演进方向，仍须独立规范和 fixture 验证。cycle-2 manifest 六份既有产物字节数与 SHA-256 均未改变。

不变量核对：

- 文本入口拒绝孤立代理项与非法 XML 字符，合法补充平面字符往返通过。
- 编号和金额全程文本；金额排序使用定宽精确键。
- 建表/升级 DDL 与 user_version 在同一事务，中途失败保持原版本与数据，重试成功。
- 四表空库检查与恢复插入单事务，失败回滚，非空库拒绝覆盖。
- XML 行号、父子坐标、合并单元格、公式与非文本值在第三方解析器之前检查；不支持的富文本及 inline CRLF 明确拒绝。
- ZIP 压缩/实际展开、条目、重复名、CRC和大小检查有界；伪造大小回归通过。
- WPS 仅在原始预检后从内存副本移除未被实际样式直接/继承使用的41–44声明，真实样本快照一致，其它低ID、实际引用及数值拒绝。
- Web 内存/unsafeIndexedDb 禁止业务写入与下载，展示真实存储模式。

验证限度：独立运行的是 macOS Dart 核心测试。浏览器记录仅支持 sharedIndexedDb 页面重开，不代表全部浏览器、进程重启或存储驱逐。WPS 真实样本解码通过，Microsoft Excel 尚未实测。Flutter 产品壳、原生三端、离线启动、完整备份、正式 DAG 与预算 B 全域保证未被此次评审覆盖。

权衡：先做四端 Flutter 工程可更早暴露插件/生命周期差异；当前小样优先验证数据语义和编解码，原生适配仍有验证成本。建议沿共享边界以同一 fixture 继续四端适配。

评审绑定 SHA-256：

| 文件 | SHA-256 |
|---|---|
| 阶段0增补 | 05b565487f98d136b949da9de88f2ff806ec9fb0ed67baf198c22a9182354612 |
| lib/model.dart | ef8dfb78784ce202dfce7a5a46025fc9db4dbbfeb9e220c0a9ab2deb3eed2e95 |
| lib/database.dart | 196b486cd906328407c3cc2aee30b6c31c9d08caa180ba7ed3cb1448b1a80f0b |
| lib/xlsx.dart | 0e034a6df828da9affbeb8fc4649e44070b7928390cbfb65c245bbaa1409ac8f |
| test/probe_test.dart | 9ae6c530e817870d1f7afdc33e56632aa305676c686a51c58bfc0076e4bd977d |
| web/main.dart | 066c634bf766dd56a03016c4850271dc44f70f788823042b4ec8661d0e78bce4 |
| WPS样本 | feaa65a30d6e433cbd83bd2507c9fe08d5239b6be06d1f49bb84022c485453fb |
