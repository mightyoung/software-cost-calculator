import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supplier_core/supplier_core.dart';

/// Holds the device's store. Pages read the store directly (SQLite is
/// synchronous and local) and call [changed] after writing so every
/// listener rebuilds with fresh data.
// ponytail: one global change signal; split per-table notifiers only if
// rebuild cost ever becomes visible.
class AppState extends ChangeNotifier {
  AppState._(this.store, this.dataDir, this._settings);

  @visibleForTesting
  AppState.test(this.store, this.dataDir)
    : _settings = {'device_name': store.device};

  final Store store;
  final Directory dataDir;
  final Map<String, Object?> _settings;

  static Future<AppState> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final settingsFile = File('${dir.path}/settings.json');
    final settings = settingsFile.existsSync()
        ? jsonDecode(settingsFile.readAsStringSync()) as Map<String, Object?>
        : <String, Object?>{};
    final device = settings['device_name'] as String? ?? _defaultDeviceName();
    settings['device_name'] = device;
    settingsFile.writeAsStringSync(jsonEncode(settings));
    return AppState._(
      Store.open('${dir.path}/supplier.db', device: device),
      dir,
      settings,
    );
  }

  static String _defaultDeviceName() {
    final host = Platform.localHostname.trim();
    return host.isEmpty ? '本机' : host;
  }

  String get deviceName => _settings['device_name']! as String;

  void changed() => notifyListeners();

  /// Runs a write and refreshes listeners. Validation errors come back as a
  /// user-facing message instead of an exception.
  String? write(void Function(Store store) action) {
    try {
      action(store);
      notifyListeners();
      return null;
    } on FormatException catch (e) {
      return friendlyError(e.message);
    }
  }
}

/// Maps core validation messages ("field: reason") to short Chinese text.
String friendlyError(String message) {
  const fields = {
    'name': '名称',
    'code': '编号',
    'unit': '单位',
    'qty': '数量',
    'unit_cost': '成本单价',
    'unit_price': '对外单价',
    'price': '单价',
    'contract_amount': '合同金额',
    'markup_rate': '加价率',
    'supplier_id': '供应商',
    'product_id': '物料',
    'project_id': '项目',
    'quotation_id': '报价',
    'end_date': '结束日期',
    'decimal': '数值',
  };
  const reasons = {
    'required': '必填',
    'precision exceeded': '位数超出（最多 12 位整数、6 位小数）',
    'expected unsigned decimal text': '应为不带符号的数字',
    'must be positive': '必须大于 0',
    'currency or tax mode differs from project': '币种或含税口径与项目不一致',
    'record does not exist': '记录已被删除',
    'clearing existing information requires explicit confirmation':
        '不能直接清空已有内容',
    'standard cannot be downgraded': '标准记录不能改为历史资料',
  };
  final i = message.indexOf(': ');
  if (i < 0) return message;
  final field = message.substring(0, i);
  final reason = message.substring(i + 2);
  final label = fields[field.split('.').last] ?? field;
  return '$label：${reasons[reason] ?? reason}';
}
