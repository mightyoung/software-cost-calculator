import '../app/workspace.dart';

Future<SupplierWorkspace> openSupplierWorkspace() async =>
    const UnavailableWorkspace('当前平台没有可用的本地数据库实现。');
