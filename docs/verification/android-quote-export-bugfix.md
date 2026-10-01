# Android 报价单导出修复

日期：2026-10-01。分支：`codex-bugfix`。基线：远程 `main` 的 `586adf4`。

## 用户现象与原因

用户在 Android 点击导出后没有文件，也没有提示。

当前 `file_picker 13.1.0` 使用 `android_file_picker 2.0.0`。原生插件
`FileUtils.saveFile` 构造 `ACTION_CREATE_DOCUMENT`、`CATEGORY_OPENABLE`
与按文件内容/扩展名识别的 MIME，并先调用 `resolveActivity`；查询失败时返回
`explorer_not_found`，没有启动系统保存界面。应用 Manifest 原先仅声明了
`PROCESS_TEXT` 查询，没有声明文件创建查询。

Android 11+ 的包可见性过滤可以使查询返回空，即使直接启动目标 Activity
本来可行。这是与现象吻合的代码缺陷；没有用户设备日志，不能断言所有 Android
设备上的失败都来自这一原因。

原有项目导出方法未捕获生成或保存异常。回归测试确认 `explorer_not_found`
及普通写入错误均成为未捕获异常，用户看不到失败提示。

官方依据：

- [Package visibility use cases](https://developer.android.com/training/package-visibility/use-cases)
- [Declare package visibility needs](https://developer.android.com/training/package-visibility/declaring)
- [Storage Access Framework: create a file](https://developer.android.com/training/data-storage/shared/documents-files#create-file)

## 修复

- `android/app/src/main/AndroidManifest.xml`：增加 `CREATE_DOCUMENT`、
  `OPENABLE`、`*/*` 的查询声明，匹配插件保存接口使用的多种 MIME。
- `lib/features/projects/project_detail.dart`：捕获 Excel/PDF 生成和保存异常，
  文件管理器不可用时显示中文原因，其他失败显示可读提示。PDF 分支显式
  `await`，确保异步异常也被捕获。保存成功才提示成功，用户取消不提示成功。
- `test/project_export_test.dart`：通过移动端更多菜单调用真实注册的 Android
  picker 实现，在原生方法通道边界验证 XLSX 字节、文件名及成功/失败/取消。

## 验证

- 新增导出回归：修复前 2 通过、2 失败；修复后 4/4 通过。
- `flutter test --no-pub test/project_export_test.dart test/business_design_audit_test.dart --reporter expanded`：36/36 通过。
- `dart test test/excel_test.dart test/pdf_test.dart --reporter expanded`：11/11 通过，含实际 PDF 生成。
- `flutter analyze --no-pub`：完整应用静态分析无问题。
- `xmllint --noout android/app/src/main/AndroidManifest.xml`、`git diff --check`：通过。
- 独立代码审查：没有阻断发现。
- 使用临时资料库与真实 `ProjectDetail` 页面的 Android arm64 调试探针 APK
  构建成功；`aapt dump xmltree` 确认最终 APK 包含 `CREATE_DOCUMENT`、
  `OPENABLE`、`*/*` 查询声明。探针入口位于 `/private/tmp`，不是生产资料库。

测试环境的代理曾导致本地 WebSocket HTTP 400，应用测试在关闭代理后通过；
生成层测试保留外网代理并让本地通信绕过代理后通过。首次 Android 构建期间
系统盘空间降至约 338 MB，已停止本次模拟器/构建并仅清理本工作树新生成的
临时 Android 构建产物，再继续验证。

## 设备验证边界

原生 Android 探针 APK 已构建成功。API 36 模拟器启动后，安装持续受本机资源
限制而未完成，已停止本次安装与模拟器；未取得实际系统保存界面或文件读回结果。
上述方法通道测试并不证明用户设备的包可见性修复已生效；PDF 的 Android 系统
中文字体可用性也不在这组测试范围内。需要在用户设备安装更新后的应用后验证。

## 另行发现

只读检查还发现独立的大额 Excel 边界：合法数量 `1000000` 与成本单价
`1000000` 相乘后，金额超过 XLSX writer 的 12 位整数验证限制。该问题与
Android 保存入口不同，未在本次分支扩大数字单元格精度契约，也未把它认定为
用户此次失败的原因。

原工作区及其他代理的未提交改动保持原状。本分支未推送、未开 PR、未合并 main。
