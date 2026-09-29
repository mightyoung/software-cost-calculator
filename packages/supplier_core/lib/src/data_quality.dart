import 'dart:convert';

import 'conflicts.dart';
import 'duplicates.dart';
import 'ontology.dart';
import 'product_params.dart';
import 'spec_migration.dart';
import 'store.dart';

/// Which part of the work a finding belongs to. Technical requirements are
/// what a project asks for; material parameters are what a material offers.
enum QualityArea {
  requirements('项目与技术要求'),
  parameters('物料参数'),
  quotes('报价'),
  records('供应商与数据一致性');

  const QualityArea(this.label);
  final String label;
}

/// One data-quality finding: how many records need attention and where to
/// fix them.
class QualityCheck {
  QualityCheck(this.key, this.label, this.count, this.hint, this.area);
  final String key, label, hint;
  final int count;
  final QualityArea area;

  Map<String, Object?> toJson() => {
    'key': key,
    'label': label,
    'count': count,
    'hint': hint,
    'area': area.label,
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
        QualityArea.records,
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
        QualityArea.records,
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
        QualityArea.records,
      ),
      QualityCheck(
        'unknown_tax_mode',
        '含税口径未知的报价',
        count(
          'SELECT count(*) AS n FROM quotation WHERE deleted = 0 '
          "AND json_extract(data,'\$.tax_mode') = 'unknown'",
        ),
        '不参与比价，补上含税或不含税',
        QualityArea.quotes,
      ),
      QualityCheck(
        'undated_quotes',
        '没有报价日期的报价',
        count(
          'SELECT count(*) AS n FROM quotation WHERE deleted = 0 '
          "AND json_extract(data,'\$.quoted_on') IS NULL",
        ),
        '无法判断是否有效，不参与最低价',
        QualityArea.quotes,
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
        QualityArea.requirements,
      ),
      ..._requirementChecks(),
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
        QualityArea.quotes,
      ),
      ..._paramChecks(),
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
        QualityArea.records,
      ),
    ];
  }

  /// Design §9.5: materials that could have a parameter template but do
  /// not, that miss key parameters, or whose parameters nobody checked.
  List<QualityCheck> _paramChecks() {
    var unclassified = 0, incomplete = 0;
    // Read only property codes, once for the whole live classified catalogue.
    // Values and record histories are irrelevant to completeness.
    final properties = <String, Set<String>>{};
    for (final r in db.select(
      "SELECT json_extract(pp.data,'\$.product_id') AS product_id, "
      "json_extract(pp.data,'\$.property') AS property "
      'FROM product_param pp JOIN product p '
      "ON p.id = json_extract(pp.data,'\$.product_id') "
      'WHERE pp.deleted = 0 AND p.deleted = 0 '
      "AND json_extract(p.data,'\$.merged_into') IS NULL "
      "AND json_extract(p.data,'\$.spec_class') IS NOT NULL",
    )) {
      (properties[r['product_id'] as String] ??= {}).add(
        r['property'] as String,
      );
    }
    for (final r in db.select('SELECT id, data FROM product WHERE $_live')) {
      final d = jsonDecode(r['data'] as String) as Map<String, Object?>;
      if (d['spec_class'] == null) {
        if (guessSpecClass([d['name'] as String?, d['category'] as String?]) !=
            null) {
          unclassified++;
        }
        continue;
      }
      final c = completenessForParams(
        d['spec_class'] as String,
        properties[r['id']] ?? const <String>{},
      );
      if (c.filled < c.total) incomplete++;
    }
    final unconfirmed =
        db
                .select(
                  "SELECT count(DISTINCT json_extract(data,'\$.product_id')) AS n "
                  "FROM product_param WHERE deleted = 0 "
                  "AND json_extract(data,'\$.confirmed') = 0",
                )
                .first['n']
            as int;
    return [
      QualityCheck(
        'products_unclassified',
        '可归类但未选参数模板的物料',
        unclassified,
        '数据中心 › 数据质量 › 物料参数 › 从型号和规格说明补全',
        QualityArea.parameters,
      ),
      QualityCheck(
        'products_missing_key_params',
        '缺关键参数的物料',
        incomplete,
        '物料 › 物料参数表，或从型号和规格说明补全',
        QualityArea.parameters,
      ),
      QualityCheck(
        'products_unconfirmed_params',
        '有未确认参数的物料',
        unconfirmed,
        '物料 › 物料参数表 › 确认',
        QualityArea.parameters,
      ),
    ];
  }

  /// What a project's technical requirements still need: clauses nobody
  /// checked against the original text, and items without a chosen material.
  List<QualityCheck> _requirementChecks() {
    final r = db
        .select(
          'SELECT (SELECT count(*) FROM spec_item i, '
          "json_each(i.data,'\$.clauses') c WHERE i.deleted = 0 "
          "AND json_extract(c.value,'\$.reviewed') = 0) AS unreviewed, "
          '(SELECT count(*) FROM spec_item WHERE deleted = 0 '
          "AND json_extract(data,'\$.chosen_product_id') IS NULL) AS unchosen",
        )
        .first;
    return [
      QualityCheck(
        'spec_clauses_unreviewed',
        '待核对的技术要求条款',
        r['unreviewed'] as int,
        '项目 › 技术要求，逐条对照原文确认读出的条件',
        QualityArea.requirements,
      ),
      QualityCheck(
        'spec_items_unchosen',
        '还没定选物料的需求项',
        r['unchosen'] as int,
        '项目 › 技术要求 › 匹配与定选',
        QualityArea.requirements,
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
