# 整体 UI 审查与改版

日期：2026-09-29。范围：`codex-ui`，基于 `origin/main` 的 `1138e2c`。业务对象、计算与数据结构不变。现有截图与相关源码核对后开展审查，测试示例不是实际采购记录。

## 直说问题

现在的界面有明显的功能拼装感。问题不是缺少渐变和装饰，而是不同页面没有统一的信息层级：工作台空、预算工具栏挤、手机内容小。增加功能时不断往现有一行中塞控件，造成桌面像调试工具、手机像压缩版桌面。

| 程度 | 原问题 | 本次处理 |
| --- | --- | --- |
| 高 | 手机四列金额硬塞一行，成本告警被挤碎 | 两列摘要，保留全部金额与告警 |
| 高 | 数据表整行只有指针点击，没有键盘打开路径 | Material / InkWell 焦点、Enter 与选中语义；保留独立复选框 |
| 高 | 手机 AI 核对页的提交设置挤占审阅空间 | 核对条目滚动，固定区显示目标项目/预算影响；调整入口展开顶部设置 |
| 中 | 深色侧栏重量超过业务内容 | 中性浅色导航，深色模式保留对应层次，统一蓝色选中态 |
| 中 | 工作台快捷键提示只是文字，手机用户无法使用 | 显式搜索入口调用同一命令面板，任务标题与状态分层 |
| 中 | 手机项目清单没有标题，新建只有图标 | 标题、文字操作、48dp 筛选；按内容区宽度切换布局 |
| 中 | 默认项目详情可见，左侧却没有选中反馈 | 列表高亮与实际详情一致，过滤后不展示已被筛除的详情 |
| 中 | 短窗口侧栏溢出；更多菜单依赖固定高度 | 侧栏业务区与手机菜单可滚动，设置保持可达 |
| 中 | 页签只有视觉下划线；触控范围偏小 | 选中语义、焦点反馈、48dp 手机页签 |

## 仍需讲清的边界

- 横向滚动的项目页签保留；不是所有业务页面都进行了导航重构。
- 旧 `.impeccable.md` 里“深色主题待实现”与后文已实现的描述冲突；保留历史文件，本分支以 `DESIGN.md` 和实际代码为准。
- 原生 Flutter 使用 Material 控件。没有将应用包装为网页，也没有新增装饰性图片或指标卡。
- Windows、Android、macOS 都有源码目标；本次本机 widget 测试与截图不能代替三端真机验收。
- Canva 为概念参考：[方向板](https://canva.link/8ba43amm81623nd)。实际效果以 `apps/supplier_app/test/screens/` 为准。

## 独立复审与修复

复审目视检查 15 张截图并核对交互源码，方向认可，首轮结论为 FIX：手机确认区只显示数量，设置移入滚动内容后不能直接看出写入哪个项目。这是本次布局带来的退化，已按评审意见补充目标项目与预算影响、调整设置入口、资料模式“不保存报价”说明；必填校验失败会展开设置区。新增回归覆盖已有询价人、多项目、预算开关和资料模式。手机项目页签末项部分露出但可以横向滚动，保留为低优先级已知项。

第二轮截图后，独立审阅对上述唯一阻断给出 RESOLVED：首屏确认上下文已恢复，设置可展开并更新摘要。该结论针对列出的修复项，不等同于所有页面、所有平台认证。

## 改版预览

- [桌面预算工作区](../../apps/supplier_app/test/screens/desktop_budget.png)
- [桌面工作台](../../apps/supplier_app/test/screens/desktop_home.png)
- [手机项目列表](../../apps/supplier_app/test/screens/phone_projects.png)
- [手机预算](../../apps/supplier_app/test/screens/phone_budget.png)
- [手机导入核对与固定确认区](../../apps/supplier_app/test/screens/phone_import_review.png)
- [深色工作台](../../apps/supplier_app/test/screens/dark_home.png)

## 实现范围

8 个界面源码文件：`theme.dart`、`shell.dart`、`home_page.dart`、`projects_page.dart`、`project_detail.dart`、`material_review.dart`、`settings_page.dart`、`data_grid.dart`。3 个新增回归文件，36 张更新后的截图。设计约定写入根 `PRODUCT.md`、`DESIGN.md` 和 `.impeccable/design.json`。

## 验证记录

改动前非截图测试：47 个通过。初次执行受代理影响，清除代理环境后正常。

最终验证：

- `flutter test --no-pub --exclude-tags screenshot`：59/59 通过。
- `flutter test --no-pub test/screenshot_test.dart --update-goldens`：第二轮 36/36 场景成功渲染；更新快照不代表像素回归对旧版通过。
- `flutter analyze --no-pub`：No issues found。
- `git diff --check`：通过。
- 新增 12 个测试，覆盖触屏搜索、受限宽度、项目高亮、表格 Enter 与复选框隔离、短窗口、130% 字号、320/390px 键盘场景、多项目导入目的地和资料模式。

测试运行时清除了 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY 及其小写版本，并设置 NO_PROXY=localhost,127.0.0.1,::1，避免本地 WebSocket 被代理拦截。使用现有 Flutter SDK，无新增依赖。
