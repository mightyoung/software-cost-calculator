---
name: 询价台账 codex-ui
description: 浅中性色工作区与克制蓝色操作层级
colors:
  canvas: "#F7F8FA"
  surface: "#FFFFFF"
  sunken: "#F1F3F6"
  rule: "#E2E6EC"
  rule-strong: "#C3CAD6"
  ink: "#111827"
  ink-secondary: "#4B5565"
  ink-caption: "#636C7E"
  primary: "#2458D3"
  primary-deep: "#1B47C2"
  primary-tint: "#E8EFFF"
  navigation: "#EEF1F5"
  navigation-hover: "#E2E8F2"
  navigation-ink: "#374357"
  navigation-caption: "#5B677B"
  warning: "#9A5000"
  warning-bg: "#FFF2DF"
  error: "#B8302A"
  error-bg: "#FDE8E6"
  success: "#17693F"
  success-bg: "#E6F4EC"
typography:
  title:
    fontSize: "24px"
    fontWeight: 600
  section:
    fontSize: "16px"
    fontWeight: 600
  body:
    fontSize: "14px"
  table:
    fontSize: "13px"
  caption:
    fontSize: "12px"
rounded:
  control: "8px"
  dialog: "12px"
spacing:
  tight: "8px"
  related: "12px"
  content: "16px"
  section: "24px"
  section-large: "32px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.surface}"
    rounded: "{rounded.control}"
    padding: "12px 14px"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "12px 12px"
  input:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.control}"
    padding: "10px 10px"
  filter-selected:
    backgroundColor: "{colors.primary-tint}"
    textColor: "{colors.primary-deep}"
    rounded: "{rounded.control}"
    height: "48px"
---

# Design System: 询价台账

## Overview

**Creative North Star: "清晰的业务工作区"**

这是 `codex-ui` 分支改版实现的视觉记录。用户授权整体 UI 优化，具体方案由本次实现提出，不能称为用户批准或真机验收。产品事实见 `PRODUCT.md`。

浅中性色导航退到背景，白色工作面承载记录和预算。克制的蓝色标识主操作、当前选择与可交互内容；数据、标题与状态通过层级和空间组织。

**Key Characteristics:**
- 清晰的标题与任务入口。
- 可扫描的数据与可辨识的状态。
- 浅导航、白色工作面与克制蓝色。
- 保留精确数字与平台字体。

来源为 `apps/supplier_app/lib/app/theme.dart` 与实际组件代码。上方色值记录浅色主题；深色值已存在于 `Tokens._pick`，继续由同一套语义 token 提供。历史 `.impeccable.md` 保留原文，其深色侧栏与推迟深色主题的描述不覆盖本分支实现。

## Colors

### Primary

主蓝用于主按钮与选中态；深蓝用于浅蓝底上的可读文字。蓝色不替代危险、警告或成功状态。

### Neutral

画布、导航与工作面以明度区分，细线分隔表格和控件。主文字、次级文字、注释各用对应墨色，不通过一律减淡正文制造层级。

### Semantic states

警告用琥珀色，错误用红色，最低有效报价等良好结果用绿色。业务状态同时保留文字标签，图标辅助识别。

### Icons

内部功能图标使用 `AppIcon`：统一 24×24 画布、1.7 描边、圆形端点与连接点。明暗主题共用图形，通过 `IconTheme` 继承颜色、透明度及尺寸，禁止为两种主题分别维护路径。业务名称与图形映射集中在 `docs/design/icons/catalog.json`，SVG 和 Flutter 路径均由 `apps/supplier_app/tool/generate_business_icons.py` 生成。新增图标先更新图谱并验证小尺寸，不混入独立实心或多彩插画风格。详见 `docs/design/icons/README.md`。

## Typography

使用 Flutter 平台默认字体；Windows 显式选择 Segoe UI Variable Text 并回退 Segoe UI。中文回退包含 Microsoft YaHei UI、Microsoft YaHei、PingFang SC、Noto Sans SC、Noto Sans CJK SC。代码与型号采用 Consolas / Menlo / SF Mono / Cascadia Mono 等等宽回退；普通标题不使用等宽字。

`titleLarge` 为页面标题，`titleMedium` 为分区标题，`bodyLarge` 为正文，`bodyMedium` 为紧凑内容，`bodySmall` 为注释。正文不是全局统一 14，保留 13 的紧凑内容层级。金额和数量使用已有 `tabular` 字体特性与格式化逻辑，保持右对齐和原有精度。

## Layout

桌面壳使用 200 逻辑像素侧栏，手机使用 72 高底部导航。项目页实际可用宽度达到 1000 时显示 240 宽主列表与剩余详情；较窄时点击项目进入独立详情。不能以物理屏幕宽度推断嵌套面板空间。

工作台按标题、说明、搜索、快捷操作与队列排序。队列行内部可用宽度不足 520 时，状态放在描述下方。项目筛选至少 48 高；表格保留桌面密度，不通过整体放大行列替代手机适配。前置 token 中的 px 对应 Flutter 逻辑像素。

## Elevation & Depth

通过背景、边框与间距形成结构。当前应用栏、卡片与对话框主题的 elevation 为 0；不要给每条记录新增浮动阴影。临时浮层的系统行为以实际 Flutter 组件为准。

## Shapes

控件使用主题小圆角，对话框使用更大圆角。工作队列为一个有边框的列表面，不给每条记录重复套卡片。项目选中项使用浅蓝底、深蓝标题与选中语义，取代粗彩色边条。

## Components

### Buttons

主按钮用于主要任务，描边按钮用于次要入口。创建任务使用可读文字，避免只靠小图标和悬浮提示。键盘焦点、禁用与按压反馈沿用 Flutter Material 主题。

### Inputs / Fields

白底、细边框、主题圆角；聚焦输入框使用 2 逻辑像素蓝色边框。工作台搜索是打开既有命令面板的真实按钮。

### Navigation

桌面导航使用浅中性色，当前目的地以蓝色选中态标识；手机保留底部目的地与原有路径。导航不能压过当前任务内容。

### Filters and records

项目筛选具备选中语义和至少 48 高触达区域；列表选中项与显示详情一致。空筛选结果解释如何恢复，不误称为没有建立过项目。

### Tables and work queue

任务先显示名称，再显示项目、数量或报价上下文，最后显示截止与待处理状态。预算保留分类、金额、警告与编辑行为；视觉调整不能改变计算或隐藏精度。

## Do's and Don'ts

### Do:
- **Do** 使用语义 token，同时保留浅色与深色实现。
- **Do** 保持金额精度、数据状态和真实交互。
- **Do** 根据组件实际可用宽度组织布局。

### Don't:
- **Don't** 添加装饰性指标卡片或虚构业务数据。
- **Don't** 以粗彩色边条、渐变或发光替代信息层级。
- **Don't** 将自动测试或桌面截图描述为跨平台真机验收。
