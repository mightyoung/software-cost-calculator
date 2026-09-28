import 'dart:convert';

import 'conflicts.dart';
import 'duplicates.dart';
import 'ontology.dart';
import 'store.dart';

/// One data-quality finding: how many records need attention and where to
/// fix them.
class QualityCheck {
  QualityCheck(this.key, this.label, this.count, this.hint);
  final String key, label, hint;
  final int count;

  Map<String, Object?> toJson() => {
    'key': key,
    'label': label,
    'count': count,
    'hint': hint,
  };
}

const _live = "deleted = 0 AND json_extract(data,'\$.merged_into') IS NULL";

extension DataQuality on Store {
  /// Live records per object type (merged duplicates not counted).
  Map<String, int> recordCounts() => {
    for (final type in entityTypes)
      type:
          db
                  .select(
                    'SELECT count(*) AS n FROM $type WHERE '
                    '${ontology[type]!.field('merged_into') == null ? 'deleted = 0' : _live}',
                  )
                  .first['n']
              as int,
  };

  /// Gaps that make comparisons or budgets less reliable, worst first.
  List<QualityCheck> dataQuality() {
    int count(String sql) => db.select(sql).first['n'] as int;
    return [
      QualityCheck(
        'open_conflicts',
        '待确认的修改冲突',
        openConflicts().length,
        '同步与交换 › 去确认',
      ),
      QualityCheck(
        'duplicate_suppliers',
        '名称相同的供应商',
        _duplicateGroups(
          'supplier',
          (d) => [
            companyKey(d['name']! as String),
            for (final a in (d['aliases'] as List?) ?? const [])
              companyKey(a as String),
          ],
        ),
        '供应商 › 打开其中一条 › 合并',
      ),
      QualityCheck(
        'duplicate_products',
        '型号和品牌相同的物料',
        _duplicateGroups('product', (d) {
          final model = normalizeKey(d['model'] as String?);
          return model.isEmpty
              ? const []
              : ['$model|${normalizeKey(d['brand'] as String?)}'];
        }),
        '物料 › 打开其中一条 › 合并',
      ),
      QualityCheck(
        'unknown_tax_mode',
        '含税口径未知的报价',
        count(
          'SELECT count(*) AS n FROM quotation WHERE deleted = 0 '
          "AND json_extract(data,'\$.tax_mode') = 'unknown'",
        ),
        '不参与比价，补上含税或不含税',
      ),
      QualityCheck(
        'undated_quotes',
        '没有报价日期的报价',
        count(
          'SELECT count(*) AS n FROM quotation WHERE deleted = 0 '
          "AND json_extract(data,'\$.quoted_on') IS NULL",
        ),
        '无法判断是否有效，不参与最低价',
      ),
      QualityCheck(
        'needs_inquiry',
        '待询价的预算行',
        count(
          'SELECT count(*) AS n FROM project_item WHERE deleted = 0 '
          "AND json_extract(data,'\$.category') = 'material' "
          "AND json_extract(data,'\$.product_id') IS NULL",
        ),
        '项目 › 预算，关联物料或建询价单',
      ),
      QualityCheck(
        'products_never_quoted',
        '从未报价的物料',
        count(
          'SELECT count(*) AS n FROM product p WHERE p.deleted = 0 '
          "AND json_extract(p.data,'\$.merged_into') IS NULL "
          'AND NOT EXISTS (SELECT 1 FROM quotation q WHERE q.deleted = 0 '
          "AND json_extract(q.data,'\$.product_id') = p.id)",
        ),
        '询价后录入或智能导入报价',
      ),
      QualityCheck(
        'suppliers_without_contact',
        '没有联系人的供应商',
        count(
          'SELECT count(*) AS n FROM supplier s WHERE s.deleted = 0 '
          "AND json_extract(s.data,'\$.merged_into') IS NULL "
          'AND NOT EXISTS (SELECT 1 FROM contact c WHERE c.deleted = 0 '
          "AND json_extract(c.data,'\$.supplier_id') = s.id)",
        ),
        '供应商 › 添加联系人',
      ),
    ];
  }

  /// Groups of two or more live records sharing a key from [keys].
  // ponytail: loads every live record of the type (fine for thousands).
  int _duplicateGroups(
    String type,
    List<String> Function(Map<String, Object?> data) keys,
  ) {
    final byKey = <String, Set<String>>{};
    for (final r in db.select('SELECT id, data FROM $type WHERE $_live')) {
      final data = jsonDecode(r['data'] as String) as Map<String, Object?>;
      for (final k in keys(data).toSet()) {
        if (k.isNotEmpty) (byKey[k] ??= {}).add(r['id'] as String);
      }
    }
    // A record found under several keys still counts once per group.
    return {
      for (final ids in byKey.values)
        if (ids.length > 1) (ids.toList()..sort()).join(),
    }.length;
  }
}
