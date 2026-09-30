# UI 审查与字体、AI 助手更新

## 基线与范围

在独立 `codex-ui` 工作区执行，先从远程拉取 `main`，无冲突快进至 `bec3c2f`。原工作目录的未提交修改未动。审查对象为 DESIGN.md、应用壳、共享组件、全部功能目录，以及 main 新增的公司资料、表单与页面。审查属于代码与本地渲染验证，不等于所有平台实机验收。

## 发现与修复

| 问题 | 修复与入口 |
| --- | --- |
| 字体依赖各系统回退，中文、数字与标题节奏不一致 | `app/theme.dart` 与 `pubspec.yaml` 打包官方 Noto Sans SC 可变字体，统一正文、标题行高，保持业务字号与金额精度 |
| AI 对话工作面过宽，聊天内容与说明、历史控件争抢空间 | `features/ai/ask_page.dart` 居中 760 宽对话列，简洁助手正文、轻底色用户消息、底部圆角输入区、48×48 发送/停止入口与复制回答 |
| 窄屏大字号与键盘展开时输入区域拥挤 | 根据剩余高度收起说明；建议问题可滚动；限制输入提示行数，保留字号缩放和输入操作 |
| 目录字段、单位换算始终双列 | `catalog_form.dart` 按宽度与文字倍率切换单列，保持字段顺序和原保存行为 |
| 分页操作在窄屏大字号下溢出 | `widgets/ledger.dart` 的 MoreRow 使用可换行布局 |
| 公司资料加载动画绕过减少动效设置 | `hub_page.dart` / `hub_publish.dart` 使用已有 TaskProgress |
| 公司资料详情、发布准备失败无原地恢复入口 | 增加重试、重新核对；重新核对只重新准备，不自动重复发布 |

## 参考与边界

字体与聊天布局参考 [DeepSeek Harness 官方字体栈](https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/client/ui-theme/src/styles/base.css) 和 [正文布局](https://github.com/deepseek-ai/deepseek-harness/blob/639ed015397290b3745d163aafe02ffee4aa3f84/packages/client/ui-chat/src/client/chat/ChatView.module.css)。参考 [ChatGPT 官方界面更新记录](https://help.openai.com/en/articles/6825453-chatgpt-release-notes) 的输入区与阅读位置思路，以及 [Claude 会话管理](https://support.claude.com/en/articles/8230524-delete-or-rename-a-conversation) 的对话与操作分离原则。未增加独立多会话数据模型。

字体来自 [Noto 官方字体库](https://github.com/notofonts/noto-cjk/tree/main/Sans/Variable/TTF/Subset)，许可证随 `assets/fonts/OFL.txt` 保留。借鉴排版和交互，不分发未获授权的产品专有字体。完整中文字体约 17.8 MB，以离线覆盖任意供应商名称和导入内容为代价；无新增代码依赖。Canva 检索未找到该项目现有设计，因此以仓库产品、设计基准和可运行界面为依据。

查询依据折叠、已核验记录跳转、历史未保留依据提示、近期对话默认关闭、取消、任务恢复和本地记录存储均保留。回答复制使用显示清理后的文本。新按钮复用已有统一图标库。

## 验证

- 全应用非截图回归：206 通过，1 跳过。跳过项为缺少本地 Rust 服务程序的真实服务集成；模拟服务测试通过。
- 静态分析：无问题。格式检查与 diff 空白检查通过。
- 41 个桌面、手机和深色渲染场景批量验证；AI 的空态、已有对话及深色对话均有截图。
- 新增 320×640、两倍字号、260 高键盘区域、明暗主题的聊天布局验证；目录窄屏、单位换算和失败重试均有回归测试。
- 首轮发现的键盘溢出已修复。最后复验使用真实本地字体资产。
- 未运行 Android / Windows 真机、浏览器 Web 与真实 AI 服务端到端验收。

## 预览

- `apps/supplier_app/test/screens/desktop_ask.png`
- `apps/supplier_app/test/screens/desktop_ask_conversation.png`
- `apps/supplier_app/test/screens/phone_ask.png`
- `apps/supplier_app/test/screens/phone_ask_conversation.png`
- `apps/supplier_app/test/screens/dark_phone_ask_conversation.png`

## 2026-10-01 提交前复核

提交前再次同步远端 main，快进至 `06d18ad`，保留最新导入文本限制与基准调整。静态分析无问题；完整前端回归 209 项通过、1 项真实服务集成跳过；核心测试 347 项通过、3 项依赖外部条件的测试跳过；图谱与管理端 23 项通过。代码复审未发现提交阻断问题。完整图标来源与平台资源见本轮图标重设计记录。

用户已要求提交并合并到 main。本次仅包含独立 codex-ui 工作区中的 UI、字体、AI 对话、图标及配套验证资料，不包含原工作目录的其他未提交工作。
