# 关系图组件选型

2026-09-29 · 针对当前 Flutter Windows（主平台）、Android、macOS 应用。结论是选型建议，不代表已更换生产组件或完成真机性能验证。

## 建议

以视觉与探索交互为重点，优先验证 **AntV G6**。以原生接入成本为重点，保留 **GraphView** 作为方案。当前固定坐标手绘图具备业务语义，但自动布局、标签避让、多边路由都需要持续自研，已经成为视觉升级的成本来源。

成熟组件提供引擎，不会自动产生好设计。最终仍需统一节点尺寸、语义分组、焦点层级、边标签出现时机、明暗颜色与可打断动效。对当前11类对象，无须为了“知识图谱感”改成大量小圆点或持续力场漂浮。

## 对比

| 候选 | 官方能力 | 本项目判断 |
| --- | --- | --- |
| [AntV G6](https://g6.antv.antgroup.com/en/manual/behavior/overview) | 多布局、画布交互、聚焦、邻接高亮、自动标签处理；支持平行边和自环配置 | 最值得优先验证的视觉/交互方案，节点与边样式仍需设计。Flutter内嵌需要WebView和数据桥接 |
| [Cytoscape.js](https://js.cytoscape.org/) | 图可视化与分析、布局扩展、样式与事件系统 | 将来若重点转向路径分析、网络分析，可优先考虑；同样需要WebView，不能仅凭库名断言性能更好 |
| [Flutter GraphView](https://pub.dev/packages/graphview) | 原生Flutter，多种树/层次/力导向等布局，节点自定义、缩放聚焦、展开收起 | 接入最轻，适合当前小图；官方说明也强调小图。完整知识探索界面及复杂多关系显示仍需补充 |

GraphView并非完全不支持自环；1.5.1的实现/更新记录包含loopback。多重边是否保留不同字段语义，应使用本系统实际关系集验证，不能把一般有向图示例视为验收。

## G6值得复用的具体部分

- [布局系统](https://g6.antv.antgroup.com/en/api/layout)：用分组/层次布局替代手写坐标，图变化时重算；用户单纯选中节点时不重排。
- [内置行为](https://g6.antv.antgroup.com/en/manual/behavior/overview)：平移、缩放、选中、聚焦和标签适配等复用成熟实现；选择后的业务详情仍由现有Flutter呈现。
- [平行边处理](https://g6.antv.antgroup.com/manual/transform/process-parallel-edges)：同一对象对之间存在多个引用字段时保留独立语义，不静默合并成一条不明关系。
- [边配置](https://g6.antv.antgroup.com/en/manual/element/edge/base-edge)：自引用使用loop配置，避免隐藏supplier/product合并来源。

## 跨端与本地运行

最初选型时应用没有 WebView 依赖；本轮集成已锁定 `flutter_inappwebview: 6.1.5`，正式数据中心使用离线资源宿主。[Flutter官方webview_flutter](https://pub.dev/packages/webview_flutter)列出的原生平台是Android、iOS、macOS，不能直接据此承诺覆盖Windows。

[flutter_inappwebview的平台说明](https://inappwebview.dev/docs/intro/)包括Windows WebView2、macOS WKWebView及Android WebView。[Windows运行条件](https://inappwebview.dev/docs/webview/in-app-webview/)要求检测WebView2 Runtime并考虑其分发；需要增加打包和原生验证工作。

若采用G6，JS/CSS应锁定版本、随应用本地打包，不依赖联网CDN加载；通过明确的JSON接口传递ontology和必要的显示数据，不需要增加图数据库、云服务或把本机业务数据上传。图面仅负责可视化和选中事件，事务和编辑仍留在现有核心层。

## 数据中心专项的下一版验收条件

1. 用真实11类ontology类型和全部引用字段验收，特别是自环和同源同目标多字段，不用无关示例数据替代。
2. 设计按供应商、采购报价、项目预算、技术需求分组；默认突出当前业务对象的一跳关系，完整关系可展开。组是视觉组织，不更改数据模型。
3. 节点文字足够大，选中态清晰；边标签按焦点展示，不能全屏文字交叉；搜索可通过键盘执行，详情可读。
4. 明暗主题同布局同图标，支持减少动效、缩放、拖拽中断动画和窗口尺寸变化。
5. Windows/macOS/Android逐端测量首次加载、滚轮/触控手势、DPI、焦点、减少动效和帧耗时。原生验证之前保留现有可用实现，不把网页原型视为完成替换。
6. 数据质量与AI接入已按[data-center-workspace.md](data-center-workspace.md)完成本轮重构与针对性测试；G6 已接入正式 Flutter 数据中心，独立预览保留用于开发验收。代码集成与原生设备验收分开记录，见[整体验证](frontend-integration.md)。
