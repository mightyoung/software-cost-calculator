import 'dart:convert';

import 'budget.dart';
import 'llm.dart';
import 'search.dart';
import 'store.dart';

const maxToolRounds = 8;
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
const _int = {'type': 'integer'};

/// Read-only views of the local database. Nothing here can write: creating
/// projects from AI output always goes through a user-confirmed screen.
final assistantTools = [
  _tool(
    'search_products',
    '按关键词检索物料（名称/品牌/型号/规格/类别），返回匹配度排序的物料',
    {
      'keywords': {'type': 'array', 'items': _str},
      'limit': _int,
    },
    ['keywords'],
  ),
  _tool('search_suppliers', '按名称或别名检索供应商', {'keyword': _str}, ['keyword']),
  _tool('search_projects', '按名称或编号检索项目', {'keyword': _str}, ['keyword']),
  _tool('list_quotations', '列出报价，可按物料、供应商、项目过滤，最新在前', {
    'product_id': _str,
    'supplier_id': _str,
    'project_id': _str,
    'limit': _int,
  }),
  _tool(
    'quote_options',
    '某物料在指定币种与税制下的可用报价，有效的在前、价格从低到高',
    {
      'product_id': _str,
      'currency': _str,
      'tax_mode': {
        'type': 'string',
        'enum': ['included', 'excluded'],
      },
    },
    ['product_id'],
  ),
  _tool(
    'project_budget',
    '项目成本预算：各行金额、分类小计、报价合计、毛利和预警',
    {'project_id': _str},
    ['project_id'],
  ),
  _tool(
    'get_record',
    '按 ID 读取一条记录（supplier/contact/product/project/quotation）',
    {'type': _str, 'id': _str},
    ['type', 'id'],
  ),
];

const _system =
    '你是供应商询价与项目成本系统的数据助手。只能通过提供的工具查询本机数据，'
    '不要编造数据；查不到就如实说明。金额是精确十进制文本，请原样引用。'
    '回答使用中文，涉及记录时给出名称，必要时附上 ID。';

extension Assistant on Store {
  /// Answers a question about local data using read-only tool calls.
  Future<String> ask(LlmClient llm, String question) async {
    final messages = <Map<String, Object?>>[
      {'role': 'system', 'content': _system},
      {'role': 'user', 'content': question},
    ];
    for (var round = 0; round < maxToolRounds; round++) {
      final message = await llm.complete(messages, tools: assistantTools);
      messages.add(message);
      final calls = message['tool_calls'];
      if (calls is! List || calls.isEmpty) {
        return (message['content'] as String?)?.trim() ?? '';
      }
      for (final call in calls.cast<Map<String, Object?>>()) {
        final function = call['function']! as Map<String, Object?>;
        messages.add({
          'role': 'tool',
          'tool_call_id': call['id'],
          'content': runTool(
            function['name'] as String? ?? '',
            function['arguments'] as String? ?? '{}',
          ),
        });
      }
    }
    throw LlmException('查询步骤过多，请把问题说得更具体一些');
  }

  /// Executes one tool call. Bad arguments come back as an error message the
  /// model can read and correct, never as an exception.
  String runTool(String name, String arguments) {
    try {
      final a = jsonDecode(arguments) as Map<String, Object?>;
      final limit = ((a['limit'] as num?)?.toInt() ?? 20).clamp(1, maxToolRows);
      final result = switch (name) {
        'search_products' => [
          for (final h in searchProducts(
            (a['keywords']! as List).cast<String>(),
            limit: limit,
          ))
            {'id': h.id, ...h.data},
        ],
        'search_suppliers' => _hits(searchByName('supplier', _s(a, 'keyword'))),
        'search_projects' => _hits(searchByName('project', _s(a, 'keyword'))),
        'list_quotations' => _hits(
          listQuotations(
            productId: a['product_id'] as String?,
            supplierId: a['supplier_id'] as String?,
            projectId: a['project_id'] as String?,
            limit: limit,
          ),
        ),
        'quote_options' => [
          for (final o in quoteOptionsFor(
            _s(a, 'product_id'),
            currency: a['currency'] as String? ?? 'CNY',
            taxMode: a['tax_mode'] as String? ?? 'included',
          ).take(maxToolRows))
            {
              'id': o.id,
              'valid': o.valid,
              'validity_pending': o.validityPending,
              ...o.data,
            },
        ],
        'project_budget' => _budget(_s(a, 'project_id')),
        'get_record' => get(_s(a, 'type'), _s(a, 'id'))?.data,
        _ => throw FormatException('未知工具 $name'),
      };
      return jsonEncode(result);
    } catch (e) {
      return jsonEncode({'error': '$e'});
    }
  }

  List<Map<String, Object?>> _hits(List<Hit> hits) => [
    for (final h in hits) {'id': h.id, ...h.data},
  ];

  Map<String, Object?> _budget(String projectId) {
    final b = budget(projectId);
    return {
      'cost': b.cost,
      'price': b.price,
      'margin': b.margin,
      'cost_by_category': b.costByCategory,
      'contract_warning': b.contractWarning,
      'lines': [
        for (final l in b.lines.take(maxToolRows))
          {
            'id': l.id,
            ...l.data,
            'unit_price': l.unitPrice,
            'cost_amount': l.cost,
            'price_amount': l.price,
            'warnings': l.warnings,
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
