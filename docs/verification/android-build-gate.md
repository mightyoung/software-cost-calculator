# Android 构建环境补齐

2026-09-17。全部新增工具位于 `/private/tmp/supplier-inquiry-toolchain/`，用户原 Android SDK 未修改；已有 Build Tools 36.0.0、platform-tools 和许可证记录复制到独立 SDK。

## 已核对工具

- Microsoft OpenJDK 17.0.20.1 macOS aarch64，官方归档 SHA-256 `a61837df9f18cf8c5bcff5c87b4f69267783d9eeb7d8ecbd05a831a530fb99de`，下载后计算完全一致，`java -version` 实际运行成功。
- Google command-line tools mac ARM 15859902，官方 ZIP SHA-256 `835b62a26162b229b441d1f6d4680383815a270809eb33522c0d480fa5002c4e`，下载后计算完全一致；同一 JDK 下 `sdkmanager --version` 实际输出22.0。工具有迁移到 `android sdk` 的弃用提示，但当前命令可运行。
- 项目实际 FlutterExtension 要求 compile/target API 36、NDK 28.2.13676358。独立 SDK 安装成功，arm64 debug APK 构建成功（assembleDebug 402秒）。

AGP9.1 的官方最低/默认 JDK17、Gradle9.3.1 和 Build Tools36.0.0 与本工程一致；Gradle9.3.1允许Java17–25。终端采用进程级 JAVA_HOME/ANDROID_HOME 与私有 GRADLE_USER_HOME，不写全局 Flutter Java 配置。

原始沙箱安装尝试无法读取远端清单，不是包不存在的证明。允许独立安装进程后官方包解析成功；记录见 `artifacts/development/platform/android-sdk-install-verified.log`，原失败日志保留。

即使APK编译成功，也只证明工程壳可构建。没有Android10+ arm64真机，不证明重启、存储、文件权限或业务验收；T1生产存储和发布仍未放行。

官方来源：[AGP9.1兼容表](https://developer.android.com/build/releases/agp-9-1-0-release-notes)、[Gradle9.3.1兼容表](https://docs.gradle.org/9.3.1/userguide/compatibility.html)、[Microsoft OpenJDK](https://learn.microsoft.com/en-us/java/openjdk/download)、[Android命令行工具](https://developer.android.com/studio#command-line-tools-only)、[sdkmanager](https://developer.android.com/tools/sdkmanager)。

## 构建结果

`apps/supplier_app/build/app/outputs/flutter-apk/app-debug.apk` 已生成，SHA-256 `95838e580b9a7179d5ab6ca12562b72a8046a66ac32d57ec67c17008775fd739`。aapt读取确认包名com.supplierinquiry.supplier_app、version0.1.0、minSdk29、target/compileSdk36；签名验证结果和ABI见原始日志，完整机器证据保存在 `artifacts/development/platform/android-apk-evidence.json`。

构建有SDK XML版本4/解析器最高3的兼容警告，原样保留。此APK为debug工程壳，使用调试签名，不是可发布业务应用。未启动模拟器或连接真机。独立SDK/JDK及Gradle缓存保留于临时目录，后续构建须继续传入文中进程级环境变量。
