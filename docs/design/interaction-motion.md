# 跨端交互与动效

2026-09-29 · codex-ui。面向桌面鼠标/键盘、移动端触控；不改变数据库、确认流程、撤销和导入事务。

## 调研与设计判断

- [Apple Motion](https://developer.apple.com/design/human-interface-guidelines/motion) 与 [WWDC23 Springs](https://developer.apple.com/videos/play/wwdc2023/10158/)：参考状态连续性、可打断和无须回弹的运动。业务界面不照搬展示型弹跳。
- [Adobe Spectrum Motion](https://spectrum.adobe.com/page/motion/)：参考有目的的缓动与时长。下面的毫秒值是本项目选择，不是 Adobe 或 Apple 的强制规范。
- [Material Motion](https://m3.material.io/styles/motion/overview/how-it-works)：参考操作与空间关系；移动端次级页面保留 Flutter 原生平台过渡及返回手势。
- [Flutter performance best practices](https://docs.flutter.dev/perf/best-practices)：动画避免重建昂贵子树、减少不必要透明层、大列表按需构建。本次页面过渡复用 child，仅改变绘制偏移，不同时挂载退出页。
- [Flutter profiling](https://docs.flutter.dev/perf/ui-performance)：真实帧耗时需 profile 模式和设备测量，widget 测试不能证明 60/120fps。

## 操作矩阵与落地

| 操作 | 交互决定 | 动效与性能约束 |
| --- | --- | --- |
| 工作台/项目/报价/供应商/物料/问数据/交换/数据中心/设置切换 | 立即响应，当前页唯一挂载；快速连续切换以最新选择为准 | 6px垂直归位，180ms easeOutCubic；首屏不入场；无整页淡化，无退出页面继续查库 |
| 桌面导航悬停、键盘焦点、行选择 | 沿用 Material 局部反馈，选择态带文字与焦点；不把勾选混成打开详情 | 不给表格每行加 controller，不做数据交错入场 |
| 搜索、筛选、排序、批量选择 | 结果即时刷新，保持既有数据行为 | 刻意不添加列表重排动画；避免改变密集操作的命中位置 |
| 新建/编辑/确认/删除/导入预览弹窗 | 使用同一 showAppDialog，保留原 barrierDismissible、结果及保存快捷键 | 打开180ms、关闭120ms；减少动效零时长 |
| 桌面添加物料侧栏 | 从右侧轻微滑入，关闭按钮和已有遮罩行为保留 | 220ms，水平4%位移，不动画宽度、不逐帧重排内容 |
| 手机更多导航 | 保留可滚动底部菜单和安全区 | 打开220ms、关闭160ms；减少动效零时长 |
| 手机次级页面 | 保留平台返回与原生转场 | 全局减少动效时直接呈现页面 |
| AI提取、问数据、条件解析、交换、LAN接收、整库恢复 | 保留现有阶段说明、取消和写入锁；未知进度不伪造百分比 | TaskProgress 统一反馈；减少动效时静态状态取代循环加载器 |
| 成功/错误提示 | 保留具体文本与现有撤销按钮；不通过抖动暗示错误 | 通用 toast 160/120ms；减少动效关闭过渡；错误不加入庆祝动画 |
| ontology搜索/选择/聚焦 | 双语搜索、一跳关系、字段语义、固定节点布局、键盘选择 | 视口260ms且拖动可打断；强调140ms；系统或局部开关可停止动态效果 |

## 统一规则

设置新增“减少动态效果”，保存于既有本机设置。系统 disableAnimations 或 reduceMotion 始终优先，运行中系统偏好改变会更新。关系图还保留自己的局部开关。浅色/深色使用相同运动规律，颜色不承担唯一状态含义。

动画不控制保存时机，不延迟业务回调，不等待播放完毕才允许下一步。新增 PageArrival 的 AnimatedBuilder 缓存业务子树；仅最新页面存在，稳定后没有待运行 ticker。没有新增依赖、无限环境动画、模糊背景或全表格透明过渡。

## 验证记录

初轮全部85项非截图测试通过，覆盖既有业务、物料图标、关系图和新增动效测试。动效回归检查：动画帧不重建业务子树、连续切换移除旧页、中途减少动效立即停止、静态长任务无循环ticker、不可点击遮罩关闭的弹窗仍需确认并返回原结果。最终公共路由与截图修正后22项针对性验证通过（含3份截图渲染）；flutter analyze无问题，图标生成与diff检查通过。

性能边界：以上证明实现方式和行为，没有证明各端帧率。Windows、Android、iOS真机profile、大规模真实资料库、系统辅助功能及原生字体仍需平台验收。建议在目标设备分别采样导航、搜索、打开编辑、导入任务和图缩放；60Hz预算16.7ms、120Hz预算8.3ms，观察UI/raster帧而不是用测试运行时长代替。
