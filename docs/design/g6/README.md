# 数据中心 · G6 前端与离线资源

## 交付范围

基于 G6 5.1.1，保留独立浏览器预览，并生成 Flutter 宿主使用的离线前端。预览使用项目真实 ontology 的 11 类对象、22 条引用和字段定义；正式嵌入模式从 Flutter 获取 schema、实际记录计数、选中对象与显示偏好，前端不直接读取数据库。

参考 [Palantir Ontology Manager](https://www.palantir.com/docs/foundry/ontology-manager/overview)、[Object Explorer](https://www.palantir.com/docs/foundry/object-explorer/getting-started) 及其[官方对象图示例](https://www.palantir.com/docs/resources/foundry/object-explorer/home_object_type_group_graph.png)，采用分组对象目录、矩形对象卡片、细关系线、关系／属性检查面板。明暗主题、图标和中文业务名称沿用本项目；预览目录明确标注字段数量，嵌入目录展示实际记录数（“条”），属性数量另列。缺失计数显示“—”，不冒充零条记录。

支持中文／技术名称搜索、一跳／全部关系、关系探索／引用层次布局、聚焦、缩放、拖拽、减少动效。选择对象不触发布局重算；窄屏初始聚焦当前对象，避免全图缩小后文字无法阅读。“适应画布”仍可查看全图。平行引用保持独立标识；测试用合成平行边验证此行为，不冒充真实数据案例。

## 本地运行

在本目录运行 `npm ci --ignore-scripts`，然后在上级 `docs/design` 运行 `python3 -m http.server 8767 --bind 127.0.0.1`。打开 `http://127.0.0.1:8767/g6/index.html`；窄屏检查页为 `/g6/responsive.html`。

依赖由 lockfile 锁定，无 CDN。首次 npm 安装需要联网。独立预览 fetch schema 与图标目录，需 HTTP 服务；嵌入资源不需要 fetch、ESM 或网络请求。G6 使用 MIT 许可，生成资源附带所有已安装依赖可用的许可及 NOTICE 文本。

## 构建与宿主协议

在本目录运行 `npm run build`，生成 `apps/supplier_app/assets/ontology_graph/index.html`、`g6.min.js`、`THIRD_PARTY_NOTICES.txt`。`npm run check` 对照源码与锁定依赖验证生成物无漂移。HTML 内联业务代码、样式与图标；图引擎是同目录经典脚本，适用于本地文件宿主。Flutter 使用 `initialFile: assets/ontology_graph/index.html` 加载资源。

宿主先注册处理器。前端等待 `flutterInAppWebViewPlatformReady` 或已可用的 `callHandler`，调用 `ontologyReady` 获取以下完整对象：

```json
{"version":1,"schema":{"schemaVersion":1,"nodes":[],"edges":[]},"counts":{"supplier":13},"selected":"supplier","dark":false,"reducedMotion":false,"textScale":1.0}
```

示例仅展示结构，schema 必须包含真实节点且选中 ID 必须存在。首次绘制完成回传 `ontologyRendered`；点击对象回传 `ontologySelect(id)`；载入或更新失败回传 `ontologyError(message)`。Flutter 后续调用 `window.ontologyHost.update(payload)` 更新完整状态。更新按序执行并验证版本、选择和计数；数据结构不变时保留布局与视口，宿主更新不回传选择事件。减少动效开启时中断视口动画。文字缩放支持 1–2 倍；窄屏纵向排列并允许滚动查看属性。

嵌入模式隐藏小样标题、页脚和主题开关，主题与动效由 Flutter 控制。前端只输出选择和状态，不承载 SQL 或数据库写入。

更新 schema：在 `apps/supplier_app` 运行 `flutter test test/graph_fixture_test.dart --dart-define=UPDATE_GRAPH_FIXTURE=true`。普通运行该测试会验证 JSON 与核心 ontology 一致。

## 验证记录

- `npm test`：15 项通过，包含真实图谱、宿主边界与离线资源约束，以及使用模拟图引擎的打包脚本运行测试（延迟桥接、串行更新、关系选择回声、立即中断动效、窄屏聚焦、字段描述／枚举／引用导航、卸载后忽略更新）；`node --check app.mjs`、`npm run check` 通过。这些脚本测试不替代真实 WebView 渲染。
- Flutter 数据中心模型、工作区、fixture、关系图及截图测试：20 项通过。
- 目录响应式、目录行为和工作区测试：13 项通过。
- 浏览器确认对象切换、属性展示、明暗切换；独立预览标签控制台无错误。390px iframe 仅验证窄屏布局，不代表手机原生宿主。
- 截图使用测试字体与小型种子数据，不构成实际大库或设备性能结论。

正式离线资源的浏览器验收入口为 `host-preview.html`，需从仓库根目录提供 HTTP 服务。该入口使用真实 schema 与明确标注的模拟记录数，验证桥接、主题、选中对象、缩放与减少动效；不是业务数据页面。

## 设备验证边界

Windows 需检测并分发 WebView2 Runtime；macOS 需验证 WKWebView、现有 sandbox 与网络配置；Android 需验证 WebView、触控和硬件加速。逐端检查首次加载、DPI、键盘焦点、滚轮／触控、动画中断和帧耗时。这些均为 DEFERRED，不承诺 60fps，不把网页小样视为跨平台上线验收。
