# Supplier core

正式应用的纯 Dart 领域内核。当前实施 T2，尚未连接数据库或业务界面。

- 业务金额用十进制字符串保存和比较。
- 标准报价与显式历史导入分别校验，日期精度不互相补造。
- protocol 2 修订采用限定领域 JCS 与 SHA-256；图闭包、单根和冲突投影留给 T4。
- 预览绑定数据库实例、活动 epoch、generation、封存暂存与决定摘要。
- 仓储契约使用有界扫描和暂存任务提交；尚无生产事务实现。

在安装了 Dart SDK 的环境运行：

```sh
dart pub get
dart analyze
dart test
```

`pubspec.lock` 固定本次实际解析版本。应用与平台证据见 `../../docs/verification/development-progress.md`。单元测试不能证明平台持久化、完整 Excel 交换或三端发布完成。
