import 'dart:convert';

import 'budget.dart';
import 'compare.dart';
import 'data_quality.dart';
import 'inquiries.dart';
import 'ontology.dart';
import 'record_query.dart';
import 'search.dart';
import 'spec_constraint.dart';
import 'spec_dictionary.dart';
import 'spec_match.dart';
import 'spec_parse.dart';
import 'spec_request.dart';
import 'store.dart';
import 'values.dart';

const maxToolRows = 50;

Map<String, Object?> _tool(
  String name,
  String description,
  Map<String, Object?> properties, [
  List<String> required = const [],
]) => {
  'type': 'function',
  'function': {
    'name': name,
    'description': description,
    'parameters': {
      'type': 'object',
      'properties': properties,
      'required': required,
    },
  },
};

const _str = {'type': 'string'};
const _limit = {'type': 'integer', 'description': '最多返回条数，默认 20，上限 50'};
final _type = {'type': 'string', 'enum': entityTypes};

/// Read-only tools over the local data, described by the [ontology]. The
/// same set serves the in-app assistant and any other agent; none of them
/// writes.
final agentTools = [
  _tool(
    'describe',
    '查看数据模型。不带 type：全部对象类型、关系、规则和人工操作；带 type：该类型每个字段的含义、取值和关系',
    {'type': _type},
  ),
  _tool(
    'search',
    '按关键词找物料、供应商或项目：名称、别名、型号、编号，也支持拼音首字母（如 lxb）。物料按匹配度排序',
    {
      'type': {
        'type': 'string',
        'enum': ['product', 'supplier', 'project'],
      },
      'keywords': {'type': 'array', 'items': _str},
      'limit': _limit,
    },
    ['type', 'keywords'],
  ),
  _tool(
    'get',
    '按 id 读取一条记录（任何对象类型，含已删除的）',
    {'type': _type, 'id': _str},
    ['type', 'id'],
  ),
  _tool(
    'query',
    '按字段条件筛选一类记录并计数。字段名见 describe；十进制按数值比较；列表字段任一元素满足即可；'
        '已删除和已合并的记录不返回。返回 total（总数）和 rows',
    {
      'type': _type,
      'where': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'field': _str,
            'op': {'type': 'string', 'enum': queryOps},
            'value': {'description': '比较值；in 用数组；is_null/not_null 不需要'},
          },
          'required': ['field', 'op'],
        },
      },
      'order_by': {'type': 'string', 'description': '排序字段，默认按最近修改'},
      'descending': {'type': 'boolean'},
      'limit': _limit,
    },
    ['type'],
  ),
  _tool(
    'related',
    '沿关系找引用了某条记录的记录，例如 link=quotation.supplier_id 取某供应商的报价，'
        'link=project_item.project_id 取某项目的预算行',
    {
      'link': {
        'type': 'string',
        'enum': [for (final l in links) l.name],
      },
      'id': {'type': 'string', 'description': '被引用记录的 id'},
      'limit': _limit,
    },
    ['link', 'id'],
  ),
  _tool(
    'compare_quotes',
    '某物料的全部报价按可比口径（币种+含税口径+单位）分组比价：每条是否可用及原因、最低可用价、'
        '是否定标，以及该口径的历史最低/平均/最高/最近成交价',
    {'product_id': _str},
    ['product_id'],
  ),
  _tool(
    'quote_options',
    '为某项目的某物料选价：该项目币种和含税口径下的可用报价，可用的在前、有效单价从低到高；'
        '给出需求数量 qty 时计入起订量和附加费用分摊',
    {'project_id': _str, 'product_id': _str, 'qty': _str},
    ['project_id', 'product_id'],
  ),
  _tool(
    'project_budget',
    '项目成本预算：各行数量、成本单价、销售单价、金额和提示，分类小计、成本合计、销售合计、毛利',
    {'project_id': _str},
    ['project_id'],
  ),
  _tool('data_quality', '数据质量体检：各类记录数，以及冲突、重复、口径未知、待询价等需要处理的问题数量和处理位置', {}),
  _tool(
    'spec_classes',
    '参数字典：不带 class 列出设备类别模板；带 class 列出该类别的参数（代码、名称、类型、单位、比较方式、可选值）',
    {'class': _str},
  ),
  _tool(
    'match_item',
    '按技术要求匹配物料：给 item_id（技术要求中的需求项），或给 class（类别代码）和 requirement（要求原文）。'
        '返回读出的条件、每个候选物料的结论（完全满足/基本满足/不满足）、最低有效报价和逐条判定',
    {'item_id': _str, 'class': _str, 'requirement': _str, 'limit': _limit},
  ),
  _tool(
    'inquiry_matrix',
    '询价单的比价矩阵：每个预算行 × 每家供应商的报价（有效单价、是否可用、是否最低、偏离历史均价百分比），及各供应商已回复行数',
    {'inquiry_id': _str},
    ['inquiry_id'],
  ),
];

extension AgentTools on Store {
  /// Runs one tool call. Bad arguments come back as an error the model can
  /// read and correct, never as an exception.
  String runTool(String name, String arguments) {
    try {
      final a = jsonDecode(arguments) as Map<String, Object?>;
      final limit = ((a['limit'] as num?)?.toInt() ?? 20).clamp(1, maxToolRows);
      final Object? result = switch (name) {
        'describe' => _describe(a['type'] as String?),
        'search' => _search(_s(a, 'type'), a['keywords'], limit),
        'get' => _get(_s(a, 'type'), _s(a, 'id')),
        'query' => _result(
          queryRecords(
            _s(a, 'type'),
            where: [
              for (final c in (a['where'] as List?) ?? const [])
                (c as Map).cast<String, Object?>(),
            ],
            orderBy: a['order_by'] as String?,
            descending: a['descending'] == true,
            limit: limit,
          ),
        ),
        'related' => _result(
          relatedRecords(_s(a, 'link'), _s(a, 'id'), limit: limit),
        ),
        'compare_quotes' => _compare(_s(a, 'product_id')),
        'quote_options' => _options(
          _s(a, 'project_id'),
          _s(a, 'product_id'),
          a['qty']?.toString(),
        ),
        'project_budget' => _budget(_s(a, 'project_id')),
        'inquiry_matrix' => _matrix(_s(a, 'inquiry_id')),
        'spec_classes' => _specClasses(a['class'] as String?),
        'match_item' => _matchItem(a, limit),
        'data_quality' => {
          'record_counts': recordCounts(),
          'issues': [
            for (final c in dataQuality())
              if (c.count > 0) c.toJson(),
          ],
        },
        _ => throw FormatException('未知工具 $name'),
      };
      return jsonEncode(result);
    } catch (e) {
      return jsonEncode({'error': '$e'});
    }
  }

  Object? _specClasses(String? code) {
    if (code == null) {
      return [
        for (final c in specClasses)
          {'class': c.code, 'label': c.label, 'parent': c.parent},
      ];
    }
    if (specClass(code) == null) invalid('class', 'unknown value');
    return [
      for (final cp in classParams(code))
        if (specProperty(cp.property) case final p?)
          {
            'code': p.code,
            'label': p.label,
            'type': p.type.name,
            'key': cp.key,
            'unit': ?p.unit,
            'ops': opsFor(p),
            if (p.values.isNotEmpty)
              'values': [for (final v in p.values) v.code],
          },
    ];
  }

  Map<String, Object?> _matchItem(Map<String, Object?> a, int limit) {
    final String cls;
    final List<SpecClause> clauses;
    if (a['item_id'] case final String id) {
      final item =
          get('spec_item', id) ?? invalid('item_id', 'record does not exist');
      cls = item.data['spec_class'] as String? ?? invalid('class', 'required');
      clauses = clausesOf(item);
    } else {
      cls = _s(a, 'class');
      if (specClass(cls) == null) invalid('class', 'unknown value');
      clauses = draftItem('', _s(a, 'requirement'), specClass: cls).clauses;
    }
    final cs = constraintsOf(clauses);
    final r = matchSpec(cls, cs);
    return {
      'class': cls,
      'conditions': [for (final c in cs) c.describe()],
      'text_clauses': [
        for (final c in clauses)
          if (c.isText) c.text,
      ],
      'counts': {for (final g in MatchGroup.values) g.name: r.size(g)},
      'candidates': [
        for (final c in r.candidates.take(limit))
          {
            'product_id': c.id,
            'name': c.data['name'],
            'model': c.data['model'],
            'group': matchGroupLabels[c.group],
            'price': c.price,
            'results': [
              for (final x in c.results)
                {
                  'condition': x.constraint.describe(),
                  'outcome': deviationLabels[x.verdict.outcome],
                  'note': ?x.verdict.note,
                },
            ],
          },
      ],
    };
  }

  Map<String, Object?> _describe(String? type) {
    if (type == null) {
      return {
        'types': [
          for (final t in ontology.values)
            {'name': t.name, 'label': t.label, 'description': t.description},
        ],
        'links': [for (final l in links) l.toJson()],
        'rules': [for (final r in rules) r.text],
        'actions_in_app': [
          for (final x in actions) '${x.label}：${x.description}',
        ],
      };
    }
    final t = ontology[type] ?? invalid('type', 'unknown object type');
    return {
      ...t.toJson(),
      'links_out': [
        for (final l in links)
          if (l.from == type) l.toJson(),
      ],
      'links_in': [
        for (final l in links)
          if (l.to == type) l.toJson(),
      ],
    };
  }

  List<Map<String, Object?>> _search(String type, Object? keywords, int limit) {
    if (keywords is! List || keywords.isEmpty) {
      throw const FormatException('缺少参数 keywords');
    }
    final words = [for (final k in keywords) '$k'];
    final List<Hit> hits;
    if (type == 'product') {
      hits = searchProducts(words, limit: limit);
    } else if (type == 'supplier' || type == 'project') {
      final byId = <String, Hit>{
        for (final w in words)
          for (final h in searchByName(type, w, limit: limit)) h.id: h,
      };
      hits = byId.values.take(limit).toList();
    } else {
      invalid('type', 'search covers product, supplier and project');
    }
    return [
      for (final h in hits)
        {
          'id': h.id,
          for (final e in h.data.entries)
            if (e.value != null) e.key: e.value,
        },
    ];
  }

  Map<String, Object?>? _get(String type, String id) {
    if (!entityTypes.contains(type)) invalid('type', 'unknown object type');
    final r = get(type, id);
    if (r == null) return null;
    return {
      'id': r.id,
      if (r.deleted) 'deleted': true,
      for (final e in r.data.entries)
        if (e.value != null) e.key: e.value,
    };
  }

  Map<String, Object?> _result(QueryResult r) => {
    'total': r.total,
    'rows': r.rows,
  };

  String? _name(String type, Object? id) =>
      id is String ? get(type, id)?.data['name'] as String? : null;

  List<Map<String, Object?>> _compare(String productId) => [
    for (final g in compareQuotes(productId))
      {
        'currency': g.currency,
        'tax_mode': g.taxMode,
        'unit': g.unit,
        if (priceHistory(
              productId,
              currency: g.currency,
              taxMode: g.taxMode,
              unit: g.unit,
              forCompareGroup: true,
            )
            case final h?)
          'history': {
            'count': h.count,
            'min': h.min,
            'average': h.average,
            'max': h.max,
            'last_deal': ?h.lastDeal,
          },
        'quotes': [
          for (final r in g.rows.take(maxToolRows))
            {
              'id': r.id,
              'supplier': _name('supplier', r.data['supplier_id']),
              'price': r.comparisonPrice,
              if (r.converted) ...{
                'original_price': r.price,
                'original_unit': r.data['unit_snapshot'],
                'original_tax_mode': r.data['tax_mode'],
              },
              'usable': r.valid,
              if (r.issues.isNotEmpty)
                'not_usable_because': [for (final i in r.issues) i.name],
              if (r.lowest) 'lowest': true,
              if (r.awarded) 'awarded_on': r.data['awarded_on'],
              for (final k in [
                'quoted_on',
                'valid_until',
                'min_qty',
                'extra_cost',
                'includes',
                'price_basis',
                'project_id',
              ])
                if (r.data[k] != null) k: r.data[k],
            },
        ],
      },
  ];

  List<Map<String, Object?>> _options(
    String projectId,
    String productId,
    String? qty,
  ) => [
    for (final o in quoteOptions(
      projectId,
      productId,
      qty: qty == null ? null : tryDecimal(qty, positive: true),
    ).take(maxToolRows))
      {
        'id': o.id,
        'supplier': _name('supplier', o.data['supplier_id']),
        'usable': o.valid,
        'effective_price': o.effectivePrice,
        'price': o.price,
        if (!o.dateValid) 'date_valid': false,
        if (!o.meetsMinQty) 'meets_min_qty': false,
        if (!o.formal) 'price_basis': o.data['price_basis'],
        if (o.awarded) 'awarded_on': o.data['awarded_on'],
        for (final k in ['quoted_on', 'valid_until', 'min_qty', 'extra_cost'])
          if (o.data[k] != null) k: o.data[k],
      },
  ];

  Map<String, Object?> _budget(String projectId) {
    final b = budget(projectId);
    return {
      'cost': b.cost,
      'price': b.price,
      'margin': b.margin,
      'cost_by_category': b.costByCategory,
      if (b.contractWarning) 'contract_warning': true,
      'lines': [
        for (final l in b.lines.take(maxToolRows))
          {
            'id': l.id,
            'name': l.data['name'] ?? _name('product', l.data['product_id']),
            for (final k in [
              'category',
              'product_id',
              'qty',
              'unit',
              'quotation_id',
              'unit_cost',
            ])
              if (l.data[k] != null) k: l.data[k],
            'unit_price': l.unitPrice,
            'cost_amount': l.cost,
            'price_amount': l.price,
            if (l.warnings.isNotEmpty) 'warnings': l.warnings,
          },
      ],
    };
  }

  Map<String, Object?> _matrix(String inquiryId) {
    final m = inquiryMatrix(inquiryId);
    return {
      'title': m.inquiry['title'],
      'status': m.inquiry['status'],
      'suppliers': [
        for (final s in m.suppliers)
          {'id': s, 'name': _name('supplier', s), 'answered': m.answered[s]},
      ],
      'rows': [
        for (final r in m.rows.take(maxToolRows))
          {
            'item_id': r.itemId,
            'name': r.item['name'] ?? _name('product', r.item['product_id']),
            'qty': r.item['qty'],
            'unit': r.item['unit'],
            'quotes': [
              for (final (i, c) in r.cells.indexed)
                if (c != null)
                  {
                    'supplier_id': m.suppliers[i],
                    'quotation_id': c.quotationId,
                    'effective_price': c.effectivePrice,
                    'usable': c.valid,
                    if (!c.comparable) 'comparable': false,
                    if (c.lowest) 'lowest': true,
                    if (c.awarded) 'awarded': true,
                    'deviation_percent': ?c.deviation,
                  },
            ],
          },
      ],
    };
  }
}

String _s(Map<String, Object?> a, String key) {
  final value = a[key];
  if (value is! String || value.isEmpty) throw FormatException('缺少参数 $key');
  return value;
}

/// Everything an outside agent needs to work with this data, as Markdown:
/// the ontology card and the tools with their parameters.
String agentGuide() {
  final b = StringBuffer(
    '# 询价台账数据说明\n\n'
    '供应商询价与项目成本数据，按设备本地保存。以下是数据模型和可用的只读工具。\n\n',
  )..write(ontologyCard());
  b.writeln('\n## 关系');
  for (final l in links) {
    b.writeln('- ${l.name} → ${l.to}${l.many ? '（多个）' : ''}');
  }
  b.writeln('\n## 工具（只读）');
  for (final t in agentTools) {
    final f = t['function']! as Map<String, Object?>;
    final params = ((f['parameters']! as Map)['properties']! as Map).keys.join(
      ', ',
    );
    b.writeln('- ${f['name']}($params)：${f['description']}');
  }
  return b.toString();
}
