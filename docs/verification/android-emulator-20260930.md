# Android 模拟器功能验证（2026-09-30）

> 版本纠正：下述记录测试的是旧 `codex/supplier-implementation` 分支，
> 不是当前主分支的「询价台账」App。主分支 `454aea8` 已采用新的
> `AppState/Store + Shell` 实现与手机导航；本报告的功能通过结果不能用于
> 证明主分支 Android 功能已通过。首次安装选错了源码版本，不是安装了 server。

本次测试对象是当前工作区 `apps/supplier_app`，分支
`codex/supplier-implementation`，基准提交
`484053baa6b59cf42e1cb48129571a77ef32e1ed`，含工作区现有改动及本次修复。
测试设备为用户已打开的 `emulator-5554`，Android 16 / API 36，ARM64，
物理屏幕 1080×2400。结果仅适用于此模拟器及当前源码。

## 已验证

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| APK 安装、生产入口启动、Android 私有目录创建数据库 | 通过 | `restarted-home.png`；ADB run-as 目录检查 |
| Android 上真实 SQLite 的供应商、产品、报价创建；精确价格、编号前导零；数据库关闭重开；搜索筛选；Excel 导出回读；完整备份解码 | 1 个集成测试通过，1280×1000 测试画布 | `desktop-workflows.log` |
| Android 实际 path_provider 持久目录解析 | 通过 | `mobile-workflows.log` |
| 手机 390×844 布局、三步报价、备注、报价修改；完整备份恢复并核对原 ID、修订和价格；同步包导出、同包两次预览确认导入且记录和修订不重复 | 通过；连同目录测试共 2 个测试 | `mobile-workflows.log` |
| 相关页面回归 | 17 项通过 | `page-regression.log` |
| 应用全部现有测试 | 116 项通过，运行于 macOS Flutter 测试器 | `app-regression.log` |
| Android 默认目录检查点 | 两次运行通过 | `checkpoint-first.log`、`checkpoint-repeat.log` |
| 普通 APK 保留数据更新、强制停止后重启；精确字段、关联 ID、数据库完整性 | 通过，`PRAGMA quick_check = ok`；报价价格 `12.340001`、编号 `000123-ANDROID-E2E`、关联供应商/产品 IDs 与检查点一致；各 1 条供应商、产品、报价修订 | `checkpoint.json`、`restarted-active.sqlite`、`restart-verification.json`、`restarted-home.png` |

日志及截图目录：`artifacts/development/android-emulator-20260930/`。
手机集成测试在独立临时工作区执行，结束后删除该测试工作区。
重启检查点测试另在 Android 的真实应用私有目录写入明确标记为
`ANDROID-E2E-20260930` 的测试记录，复跑会复用对应记录，不清除已有业务数据。

集成测试运行后观察到测试包被清理，因此真正的普通 APK 进程重启证据来自独立
`tool/android_restart_probe.dart` 入口：通过 ADB 安装并启动后建立检查点，
再用 `adb install --no-streaming -r` 保留数据切换到正常生产入口 APK，
实际强制停止并重新启动。停进程时提取一致的数据库文件，并核对其内容。
最终模拟器及 `build/app/outputs/flutter-apk/app-debug.apk` 均为正常生产入口，
没有将诊断入口作为最终交付包。

## 测试发现与修复

1. 报价详情页在编辑保存后，`setState` 的表达式回调返回了数据库读取 Future，
   触发 `setState() callback argument returned a Future`。改为先取得读取 Future，
   再在同步回调内更新字段。手机编辑流程已复测通过。
2. 完整备份恢复、完整同步路径弹窗在 `showDialog` 返回后立即释放输入控制器，
   弹窗退出动画仍使用该控制器，触发 `TextEditingController was used after being disposed`。
   移除这两个一次性控制器，通过 `onChanged` 保存路径；输入框使用自身生命周期。
   手机恢复和同步完整流程已复测通过。
3. 新增手机测试在同步确认窗口使用 `pumpAndSettle` 时，后台持续加载动画使测试等待不结束。
   测试改用有界帧推进及明确界面状态，不压制应用异常。

保留首次编辑失败和弹窗失败日志：`mobile-edit-failure.log`、`mobile-dialog-failure.log`。
本次未修改其他已有业务改动，也未提交或推送代码。

## 限制与待补功能

- 原生 Excel 导入、同步包导入和恢复备份仍要求输入文件绝对路径；缺少 Android 系统文件选择入口。
- 导出的 Excel、备份和同步包保存在应用私有目录，界面显示路径；缺少普通用户可用的系统保存或分享流程。
  本次证明底层读写、恢复与同步有效，不能证明普通用户已经能便捷地在 Android 外部应用间交换文件。
- 模拟器反复弹出 `Process system isn't responding` 和 `System UI isn't responding`。
  当前 AVD 配置为 1 CPU 核心、2048 MB 内存，本机总内存 8 GB。
  测试期间重启同一模拟器、刷新 ADB 并停止本次构建的空闲 Gradle 后，完成正常 APK 安装和重启检查。
  未改动 AVD 配置或清除虚拟机数据。保存的系统诊断记录到较早的
  launcher / edge-swipe 输入超时；将该模拟器干扰与上述可复现应用异常分开记录。
  Android 真机触摸、性能、权限和外部文件交换仍待验证。
- 手机端手工完整复制、删除、Excel 字段映射、冲突及关联修复流程未逐项完成；
  部分相关逻辑已被 macOS 上的全量应用测试覆盖，不能替代 Android 操作证据。
- 当前 APK/源码的业务导航为查询与比价、供应商、产品、文件与备份；本次未测试其他分支或未出现在本工作区的模块。
- 恢复及同步测试有 Drift 多数据库实例诊断警告，涉及独立临时数据库文件；测试通过不等于已完成全部并发或崩溃认证。
- APK 为 debug 签名；本次不构成正式发布或 Android 真机验收。

## 复现

在 `apps/supplier_app` 目录运行。`NO_PROXY` 避免本机 HTTP 代理拦截 Flutter 调试 WebSocket。

```sh
NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1 \
  flutter test integration_test/android_mobile_workflows_test.dart -d emulator-5554

# 此用例有明确副作用：在默认 Android 私有目录留下带标记的测试记录。
NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1 \
  flutter test integration_test/android_restart_checkpoint_test.dart -d emulator-5554

# 独立重启诊断入口会留下带标记的测试记录。
flutter build apk --debug --target-platform android-arm64 \
  --target tool/android_restart_probe.dart
# 用 ADB 安装该包后，须重新构建并以 adb install -r 安装正常入口包。
flutter build apk --debug --target-platform android-arm64
```
