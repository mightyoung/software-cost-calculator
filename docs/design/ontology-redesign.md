# 数据关系图与典型物料图标重构

2026-09-29 · `codex-ui` 隔离工作树。保留既有 UI 修改，不触碰 Claude 工作目录、数据库结构或数据交换行为。

## 现有问题与实施计划

旧关系图把 11 类对象固定在 300px 高的区域，节点宽度固定而坐标跟随容器缩放，窄桌面窗口容易拥挤。连线只有方向、缺少字段语义；合并记录的自引用被跳过；没有搜索、缩放、聚焦和动效偏好。字段详情在图下方，切换对象时难以同时看清关系与字段。旧 Painter 的重绘判断只比较 selected，主题切换也可能留下旧颜色。

实施分三部分：

1. 补齐典型工业物料的统一矢量图标，按显式物料分类选择，未知类别回退通用物料，不修改持久化数据。
2. 重建稳定的关系画布：平移/缩放、搜索、全图/相关关系、具名引用、自引用、聚焦与适应画布；先锁定点击选择和计数行为。
3. 桌面建立图与字段详情并列的工作区；窄窗口/放大文字回退上下排列，手机保留可访问的类型选择。测试保证选择仍使用同一 ontology，关系和字段数据不另建副本。

## 研究来源与判断

以下为优秀成熟产品的可核验参考，不宣称客观“行业第一”。本轮已经搜索官方资料；视觉风格建议与厂商原文要求分开。

| 官方来源 | 借鉴点 | 本系统取舍 |
| --- | --- | --- |
| [Apple Motion](https://developer.apple.com/design/human-interface-guidelines/motion) | 动效解释状态、维持连续性 | 选择与聚焦有明确目的，不持续漂浮 |
| [Apple springs · WWDC23](https://developer.apple.com/videos/play/wwdc2023/10158/) | 运动连续、可被打断、可以无回弹 | 聚焦可以随时被拖拽接管；不给表格或文字加弹跳 |
| [Adobe Spectrum Motion](https://spectrum.adobe.com/page/motion/) | 以任务为中心的时间和节奏 | 邻接关系强调约150ms，主动视口过渡约260ms；这些是项目建议值 |
| [Neo4j Bloom](https://neo4j.com/docs/desktop/current/explore/) | 搜索、视角与场景分工 | 默认突出一跳邻接，不用全部关系淹没视线 |
| [React Flow 视口](https://reactflow.dev/learn/concepts/the-viewport) | 明确平移、缩放和适应画布的交互 | 显式按钮与指针操作共存，不引入 React 依赖 |
| [React Flow 可访问性](https://reactflow.dev/learn/advanced-use/accessibility) | 键盘选择、焦点保持可见 | 图不成为只能使用鼠标的功能孤岛 |
| [React Flow Schema Node](https://reactflow.dev/ui/components/database-schema-node) | 节点与字段语义可读 | 节点保持精简，字段在旁侧检查 |

Apple 的视觉品质来自层次、连续性和响应；不等于大面积玻璃模糊。采购数据图应保持清楚的文字、可追踪的连线、稳定的节点和可解释的状态，避免霓虹、粒子飞线、无业务依据的实时流动和随机力导向布局。

用户指定的 [Remotion 技能](/Users/muyi/.codex/plugins/cache/ecc/ecc/2.2.2/skills/remotion-video-creation/SKILL.md) 及 timing 规则已读取。可借鉴插值边界、缓动和无回弹的节奏，但它面向 React 视频逐帧渲染；本次是 Flutter 交互界面，以原生动画实现，不增加 Remotion 或生成一个视频代替交互。

## 业务与视觉契约

- 这里展示对象类型关系，而不是每一条采购记录的实例图；节点数量是记录计数，连线数量不是交易数量。
- 从引用方指向被引用方；字段名称与多值关系来自 `links` / `ontology`，不手写另一套关系数据。
- 同一对类型间的不同字段分别保留；合并记录产生的自引用也必须可检查。
- 明暗共用布局、路径与图形。亮色采用白色工作面、低饱和冷灰边界和蓝色强调；暗色采用微暖近黑工作面与浅色强调。业务状态仍有文字。
- 可见节点位置稳定；切换对象改变强调和详情，只有用户主动触发聚焦/适应才移动视口。
- 图标继续使用现有24×24、1.7描边、圆端点规则。典型物料与功能图标属于同一图形家族。

## 减少动态效果

自定义动画同时处理系统设置和页面内开关，减少动效时即时完成视口变化和强调，不依赖动画完成回调才能继续操作。本机 SDK 已核对：`MediaQuery.disableAnimations` 与 `AccessibilityFeatures.reduceMotion` 分离；不能只用前者声称覆盖 iOS。[Flutter 官方说明](https://api.flutter.dev/flutter/widgets/MediaQueryData/disableAnimations.html)

## 验收范围

需验证对象计数、选择回调、搜索与无结果、具名关系/自引用、缩放/适应/聚焦、主题变化、减少动效、键盘可达性，以及窄桌面、手机与放大文字。视觉检查以真实 Flutter 渲染为准。网页和测试渲染不代替 Windows/Android 原生设备验收。

## 已交付与实测

- 关系图已在实际 Flutter 数据中心实现，桌面左右分栏，窄桌面上下分栏，手机保留类型选择和字段详情。类型及引用均来自核心 ontology；测试确认自引用不再丢失。
- 新增18类典型物料图标与4枚关系图/联系人图标，共95枚图形。实际物料列表按分类显示；未知分类保留通用物料图标。浏览器已检查18类明暗并列图形。
- [亮色实际渲染](ontology-light.png)、[暗色实际渲染](ontology-dark.png)、[紧凑布局实际渲染](ontology-compact.png)。截图以本机 STHeiti 作为明确命名的审阅字体，展示测试数据；不作为 Windows/Android 生产字体认证。
- [Canva参考板](https://canva.link/e5th471zuc5ok18) 是补充视觉探索，实际交付和交互以 Flutter 实现为准。
- 首轮85项非截图测试通过；最终公共路由、减少动效及截图修正后的22项针对性验证通过（包含3份截图渲染）。7项关系图测试覆盖搜索、无结果、全部关系、自引用、缩放聚焦、主题、窄画布及键盘；4项页面测试覆盖实际选择和响应式布局。
- `flutter analyze --no-pub` 无问题，图标生成器 `--check` 和 `git diff --check` 通过。
- 动效扩展至全局导航、表单/确认弹窗、添加物料侧栏、手机更多菜单、通用提示及AI/交换/恢复任务状态，详见[跨端交互与动效](interaction-motion.md)。没有新增第三方依赖。
- Windows/Android/iOS原生设备、真实大资料库帧耗时和各平台辅助功能检查尚未完成；本轮不声称真机性能或发布认证。
