import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';

void main(List<String> args) {
  if (args.length != 5 && !(args.length == 6 && args.last == '--withdraw')) {
    stderr.writeln(
      '用法: dart run tool/hub_export.dart <数据库路径> '
      '<supplier|quotation> <记录UUID> <发布UUID> <发布版本> [--withdraw]',
    );
    exitCode = 64;
    return;
  }
  Store? store;
  try {
    store = openReadOnly(args[0]);
    final payload = buildHubPublication(
      store,
      type: args[1],
      id: args[2],
      publicationId: args[3],
      revision: int.parse(args[4]),
      withdrawn: args.length == 6,
    );
    final records = payload['records'] as List<Map<String, Object?>>;
    stderr.writeln(
      '仅导出文件内容，不上传。请核对以下 ${records.length} 条记录及正文；'
      '报价关联询价时，会包含询价引用的其他供应商与清单。',
    );
    for (final record in records) {
      stderr.writeln('${record['entity_type']}/${record['entity_id']}');
    }
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(payload));
  } catch (error) {
    stderr.writeln('导出失败：$error');
    exitCode = 1;
  } finally {
    store?.close();
  }
}
