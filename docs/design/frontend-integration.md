# 前端集成实施与验收

## 实现结果

代码位于 `codex-ui` 独立工作区。九个正式业务入口继续使用真实页面；全局中性深色、浅色工作面、业务图标和减少动效体系已统一。

数据中心的模型页默认使用本地 G6 前端：对象目录、关系画布、属性／关系检查器完整嵌入 Flutter，而不是打开外部演示站。核心 schema 序列化统一到 `ontology_payload.dart`，真实计数在数据通知时刷新，对象选择不再重复执行计数 SQL。保留字段描述、枚举含义和引用目标导航；对象选择不写业务数据。

`OntologyGraphHost` 处理首次就绪、状态同步、超时、重试、渲染失败和迟到回调。Windows 先检测 WebView2，并在可写的应用支持目录创建环境；缺失环境时仍可用基础视图。主题／计数回传不清除关系选择，文字放大与窗口缩窄不重排整图；减少动效立即停止视口动画。数据中心页签改为点击切换，横向拖动交给图谱与表格。

离线 HTML、G6 脚本、图标和许可随应用打包，无 CDN 或本地服务器依赖。开发验收页面的记录数明确是模拟数据；正式应用使用 `Store.recordCounts()`。生成脚本和锁文件可重现资源；CI 新增 Node 测试和资源一致性检查，Windows 构建新增 [NuGet 环境](https://github.com/NuGet/setup-nuget)。

## 验证与限制

- 全应用 `flutter analyze --no-pub` 通过，业务图标生成物校验通过。
- Node 图谱与宿主协议测试 15 项通过，脚本语法和离线产物一致性检查通过。
- `flutter build bundle --no-pub` 成功，产物中确认存在 HTML、G6 脚本和许可文件。
- 实际 G6 在浏览器加载打包资源，验证宿主就绪、对象与主题同步、1.4 倍文字、390px 缩窄后焦点保持，控制台无错误。该证据不是原生 WebView 设备测试。
- Flutter 截图测试使用原生基础视图（测试环境未注册 WebView），不能把这些截图当成 G6 原生宿主的运行证据。G6 的浏览器验收入口为 `docs/design/g6/host-preview.html`，计数明确为模拟值。
- `flutter test --no-pub --exclude-tags screenshot`：98 项通过，覆盖正式业务页面、导航、主题、图标、数据中心、桥接、失败回退和迟到回调。独立代码复核：无剩余实质问题。
- macOS 原生构建：本机缺少 Xcode，未完成。Android APK 构建：现有 SDK 可用，但缺少 Java Runtime，未完成。Windows：当前 macOS 无 Windows 构建环境。CI 配置已更新但本轮未推送或运行远端流水线。
- Windows/macOS/Android 原生滚轮、触控、DPI、离线启动、WebView 生命周期和帧耗时均待实际设备验证；不宣称安装包发布或性能认证完成。

依赖选择依据：[InAppWebView 平台配置](https://inappwebview.dev/docs/intro/)、[稳定版桥接 API](https://pub.dev/documentation/flutter_inappwebview/latest/flutter_inappwebview/InAppWebViewController/addJavaScriptHandler.html)、[Microsoft 本地资源限制](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/working-with-local-content)。运行时采用本地文件和相对脚本，不使用 `NavigateToString` 内嵌整个图引擎。

## 实施计划

1. 保留当前主题、导航、业务图标和动效改造；核查所有正式入口，而非再建演示页面。
2. 把 G6 对象目录、画布、检查面板打包为离线资源，接入正式数据中心。共享核心 ontology 序列化，传递真实记录计数、选择、主题、文字倍率和减少动效设置。
3. 添加跨平台 WebView 宿主、受限消息接口、启动失败提示及原生视图回退。业务查询和编辑继续留在 Flutter／核心层。
4. 先补桥接协议与失败回退回归测试，再执行现有页面测试、分析和可用平台构建。浏览器验证生产资源；未实测设备单独列出。

## 行为边界

图谱只展示对象类型与引用关系，不把计数误画成记录级知识图谱。对象选择和主题切换不能修改业务数据。切换图谱／原生视图保留选中对象。失败时仍可浏览字段和关系；不得让缺少 WebView Runtime 导致整个数据中心不可用。

Windows、Android、macOS 逐端性能与设备交互结果须分别记录；静态分析、单元测试或 WebView 资源预览不能代替真实设备验收。
