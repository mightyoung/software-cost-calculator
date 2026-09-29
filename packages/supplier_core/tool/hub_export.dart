import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';

/// Builds a publication from one explicit root and its current references.
/// Does not export change_log, attachments, unrelated children, or upload data.
Map<String, Object?> buildHubPublication(
  Store store, {
  required String type,
  required String id,
  required String publicationId,
  required int revision,
  bool withdrawn = false,
}) {
  if (!['supplier', 'quotation'].contains(type)) {
    throw ArgumentError('首版只支持 supplier 或 quotation 根记录');
  }
  requireUuid(id, 'entity_id');
  requireUuid(publicationId, 'publication_id');
  if (revision < 1 || revision > 2147483647) {
    throw ArgumentError('发布版本必须为 1..2147483647');
  }
  const supported = {
    'supplier',
    'contact',
    'product',
    'quotation',
    'project',
    'project_item',
    'inquiry',
  };
  final records = <Map<String, Object?>>[];
  final seen = <String>{};
  final pending = [(type, id)];
  store.db.execute('BEGIN');
  try {
    while (pending.isNotEmpty) {
      final (kind, entityId) = pending.removeLast();
      if (!seen.add('$kind:$entityId')) continue;
      if (!supported.contains(kind) || seen.length > 256) {
        throw StateError('超出首版支持的实体类型或 256 条引用上限');
      }
      final record = store.get(kind, entityId);
      if (record == null || record.deleted) {
        throw StateError('记录不存在或已删除：$kind/$entityId');
      }
      final data = validatePayload(kind, record.data);
      if (kind == 'quotation' &&
          ((data['attachment_ids'] as List?)?.isNotEmpty ?? false)) {
        throw StateError('首版暂不传输附件；不能静默丢弃此报价的附件');
      }
      records.add({
        'entity_type': kind,
        'entity_id': entityId,
        'source_version': record.version,
        'data': data,
      });
      for (final ref
          in (references[kind] ?? const <String, String>{}).entries) {
        if (data[ref.key] case final String referencedId) {
          pending.add((ref.value, referencedId));
        }
      }
      for (final ref
          in (listReferences[kind] ?? const <String, String>{}).entries) {
        for (final referencedId in (data[ref.key] as List?) ?? const []) {
          pending.add((ref.value, referencedId as String));
        }
      }
    }
    records.sort(
      (a, b) => '${a['entity_type']}:${a['entity_id']}'.compareTo(
        '${b['entity_type']}:${b['entity_id']}',
      ),
    );
    final result = <String, Object?>{
      'publication_id': publicationId,
      'revision': revision,
      'withdrawn': withdrawn,
      'root': {'entity_type': type, 'entity_id': id},
      'records': records,
    };
    if (utf8.encode(jsonEncode(result)).length > 1024 * 1024) {
      throw StateError('发布内容超过首版 1 MiB 上限');
    }
    store.db.execute('COMMIT');
    return result;
  } catch (_) {
    store.db.execute('ROLLBACK');
    rethrow;
  }
}

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
