# 主分支 Android UI 版本纠正

首次 Android 安装误用了 `codex/supplier-implementation` (`484053b`)；
该分支仍是旧 `SupplierWorkspace` 四页界面。它是旧核心 App，不是 server。
此前 `android-emulator-20260930.md` 的验证不能证明当前主分支功能通过。

本次纠正使用本地 `main` 提交 `454aea8`，通过 `git archive main` 提取至
`/private/tmp/supplier-main-android-20260930`，不改动任何现有分支或工作树。
正式入口是 `apps/supplier_app/lib/main.dart` → `AppState.open()` → `Shell`；
Android 包名 `com.mightyoung.supplier_app`，手机底部导航是工作台、项目、报价、更多。

## 构建边界

原样主分支构建因 `flutter_inappwebview_android 1.1.3` 使用
`getDefaultProguardFile('proguard-android.txt')` 被 AGP 9.1 拒绝。
仅在临时副本复制已锁定插件，替换两处配置为
`proguard-android-optimize.txt`，并由临时 `pubspec_overrides.yaml` 指向该副本。
没有修改全局 pub 缓存。此兼容修复尚未提交到主分支。
临时 Gradle 内存上限由 8G 降至 2G，workers=2，适应本机 8GB 内存。
Android 官方说明：https://developer.android.com/build/releases/agp-9-0-0-release-notes

## 已取得证据

- `catalog_responsive_test.dart` 和 `workspace_design_audit_test.dart`：16 项通过。
- `ui_workspace_test.dart` 和 `ui_review_layout_test.dart`：9 项通过；覆盖窄屏导航、320/390px、大字号和键盘遮挡。
- 上述是 Flutter widget 测试，不能替代 Android 模拟器实际运行或整体业务验证。

## 待完成

新版 APK 安装、实际手机页面截图、启动日志及强停重启检查。
