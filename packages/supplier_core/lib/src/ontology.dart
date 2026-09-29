import 'budget.dart';
import 'compare.dart';
import 'entities.dart';
import 'inquiry.dart';
import 'product_params.dart';
import 'project.dart';
import 'quotation.dart';
import 'store.dart';

/// Machine-readable description of the data model for AI agents and the
/// data-centre page: object types with the meaning of every field, links
/// between them, business rules and actions. Field lists, enum values and
/// links are checked against the validators by tests, so this cannot drift.

enum Kind {
  text('文本'),
  textList('文本列表'),
  decimal('十进制文本'),
  integer('整数'),
  boolean('是/否'),
  date('日期 YYYY-MM-DD'),
  instant('时间点 ISO 8601'),
  enumeration('枚举'),
  ref('引用'),
  refList('引用列表'),
  object('对象');

  const Kind(this.label);
  final String label;
}

class FieldSpec {
  const FieldSpec(
    this.name,
    this.label,
    this.kind,
    this.description, {
    this.required = false,
    this.values,
    this.target,
  });
  final String name, label, description;
  final Kind kind;
  final bool required;

  /// Enum values and what each means.
  final Map<String, String>? values;

  /// Referenced object type, for [Kind.ref] and [Kind.refList].
  final String? target;

  Map<String, Object?> toJson() => {
    'name': name,
    'label': label,
    'kind': kind.name,
    'required': required,
    'description': description,
    'values': ?values,
    'target': ?target,
  };
}

class ObjectType {
  const ObjectType(this.name, this.label, this.description, this.fields);
  final String name, label, description;
  final List<FieldSpec> fields;

  FieldSpec? field(String name) =>
      fields.where((f) => f.name == name).firstOrNull;

  Map<String, Object?> toJson() => {
    'name': name,
    'label': label,
    'description': description,
    'fields': [for (final f in fields) f.toJson()],
  };
}

/// A reference from one object type to another, named "type.field".
class LinkType {
  const LinkType(this.from, this.field, this.to, {required this.many});
  final String from, field, to;

  /// The field holds a list of ids.
  final bool many;
  String get name => '$from.$field';

  Map<String, Object?> toJson() => {
    'name': name,
    'from': from,
    'to': to,
    'cardinality': many ? 'many-to-many' : 'many-to-one',
    'meaning':
        '${ontology[from]!.label}.${ontology[from]!.field(field)!.label}'
        ' → ${ontology[to]!.label}',
  };
}

class Rule {
  const Rule(this.name, this.text);
  final String name, text;
}

/// Something that changes data. Agents only read; each action is carried
/// out by a person in the app.
class ActionType {
  const ActionType(this.name, this.label, this.description);
  final String name, label, description;
}

const _taxModes = {
  'included': '含税价',
  'excluded': '不含税价',
  'unknown': '含税口径未知（不参与比价）',
};
const _currency = FieldSpec(
  'currency',
  '币种',
  Kind.text,
  'ISO 4217 三位大写字母，如 CNY、USD',
  required: true,
);
const _notes = FieldSpec('notes', '备注', Kind.text, '自由文本，最长 2000 字');
FieldSpec _merged(String type) => FieldSpec(
  'merged_into',
  '已合并到',
  Kind.ref,
  '不为空表示这是被合并掉的重复记录，应改用目标记录；查询默认已排除',
  target: type,
);

final _types = <ObjectType>[
  ObjectType('supplier', '供应商', '提供物料或服务的单位', [
    const FieldSpec('name', '名称', Kind.text, '全称，最长 200 字', required: true),
    const FieldSpec('aliases', '别名', Kind.textList, '简称、曾用名，最多 20 个'),
    const FieldSpec('address', '地址', Kind.text, '最长 500 字'),
    const FieldSpec('categories', '经营类别', Kind.textList, '如"水泵""阀门"'),
    _notes,
    _merged('supplier'),
    const FieldSpec(
      'rating',
      '评价',
      Kind.enumeration,
      '采购方自己的判断；停用的供应商其报价不算有效、不参与最低价',
      values: supplierRatings,
    ),
    const FieldSpec('rating_note', '评价说明', Kind.text, '为什么这样评价，最长 500 字'),
  ]),
  const ObjectType('contact', '联系人', '供应商的联系人，至少有一种联系方式', [
    FieldSpec(
      'supplier_id',
      '供应商',
      Kind.ref,
      '所属供应商',
      required: true,
      target: 'supplier',
    ),
    FieldSpec('name', '姓名', Kind.text, '最长 200 字', required: true),
    FieldSpec('phone', '电话', Kind.text, '电话、微信、邮箱至少填一项'),
    FieldSpec('wechat', '微信', Kind.text, ''),
    FieldSpec('email', '邮箱', Kind.text, ''),
    _notes,
  ]),
  ObjectType('product', '物料', '可询价的设备、材料或服务，一条物料可有多家供应商的报价', [
    const FieldSpec('name', '名称', Kind.text, '通用名，如"离心水泵"', required: true),
    const FieldSpec('unit', '单位', Kind.text, '计量单位，如 台、米、套', required: true),
    const FieldSpec('brand', '品牌', Kind.text, ''),
    const FieldSpec('model', '型号', Kind.text, '最能区分物料的信息'),
    const FieldSpec('specification', '规格/技术要求', Kind.text, '自由文本，最长 1000 字'),
    const FieldSpec('category', '类别', Kind.text, '如"水泵""电缆"'),
    _notes,
    _merged('product'),
    const FieldSpec(
      'attributes',
      '关键参数',
      Kind.object,
      '参数名 → 参数值，如 {"流量": "50m³/h"}，最多 12 项，顺序有意义',
    ),
    const FieldSpec(
      'unit_conversions',
      '报价单位换算',
      Kind.object,
      '报价单位 → 每 1 个报价单位包含的本物料基准单位数量，例如 {"千米": "1000"} 表示 1 千米 = 1000 米',
    ),
    const FieldSpec(
      'spec_class',
      '参数模板',
      Kind.text,
      '参数字典中的类别代码，如 sensor.th（温湿度传感器）；决定有哪些结构化参数',
    ),
  ]),
  ObjectType('project', '项目', '一次成本测算或采购任务，含预算行、报价和询价单', [
    const FieldSpec(
      'code',
      '编号',
      Kind.text,
      '项目编号，如 2026-WH01-015',
      required: true,
    ),
    const FieldSpec('name', '名称', Kind.text, '', required: true),
    FieldSpec(
      'status',
      '状态',
      Kind.enumeration,
      '',
      required: true,
      values: {
        'planning': '筹备',
        'active': '进行中',
        'done': '已完成',
        'cancelled': '已取消',
      },
    ),
    const FieldSpec(
      'type',
      '类型',
      Kind.enumeration,
      '',
      values: {'market': '市场项目（对外）', 'internal': '内部项目'},
    ),
    const FieldSpec(
      'level',
      '级别',
      Kind.enumeration,
      '',
      values: {'A': 'A 级', 'B': 'B 级', 'C': 'C 级'},
    ),
    const FieldSpec('customer', '客户', Kind.text, ''),
    const FieldSpec('contract_no', '合同号', Kind.text, ''),
    const FieldSpec(
      'contract_amount',
      '合同金额',
      Kind.decimal,
      '成本达到合同金额的 90% 时预算会提示',
    ),
    const FieldSpec('department', '部门', Kind.text, ''),
    const FieldSpec('leader', '负责人', Kind.text, ''),
    const FieldSpec('start_date', '开始日期', Kind.date, ''),
    const FieldSpec('end_date', '结束日期', Kind.date, '不早于开始日期'),
    _currency,
    const FieldSpec(
      'tax_mode',
      '含税口径',
      Kind.enumeration,
      '预算按此口径计算；只选用口径相同的报价',
      required: true,
      values: {'included': '含税', 'excluded': '不含税'},
    ),
    const FieldSpec(
      'markup_rate',
      '加价率',
      Kind.decimal,
      '百分数，如 "15" 表示 15%；预算行未填销售单价时，销售单价 = 成本单价 × (1 + 加价率/100)',
      required: true,
    ),
    _notes,
  ]),
  ObjectType('project_item', '预算行', '项目成本预算的一行', [
    const FieldSpec(
      'project_id',
      '项目',
      Kind.ref,
      '',
      required: true,
      target: 'project',
    ),
    const FieldSpec(
      'category',
      '成本类别',
      Kind.enumeration,
      '',
      required: true,
      values: {
        'material': '材料设备（可关联物料和报价）',
        'outsourcing': '外包',
        'labor': '人工',
        'overhead': '管理费用',
        'other': '其他',
      },
    ),
    const FieldSpec(
      'product_id',
      '物料',
      Kind.ref,
      '只有材料设备行可关联；材料行没有物料表示"待询价"',
      target: 'product',
    ),
    const FieldSpec('name', '名称', Kind.text, '未关联物料时必填'),
    const FieldSpec('qty', '数量', Kind.decimal, '大于 0', required: true),
    const FieldSpec('unit', '单位', Kind.text, '', required: true),
    const FieldSpec(
      'quotation_id',
      '采用的报价',
      Kind.ref,
      '成本单价取自这条报价（需先关联物料）',
      target: 'quotation',
    ),
    const FieldSpec(
      'unit_cost',
      '成本单价',
      Kind.decimal,
      '采用报价时的价格快照，或手填；报价变化不会自动改它，需"按最优价刷新"',
      required: true,
    ),
    const FieldSpec('unit_price', '销售单价', Kind.decimal, '为空时按项目加价率计算'),
    _notes,
  ]),
  ObjectType('quotation', '报价', '一家供应商对一个物料的一次报价，可属于某个项目和询价单', [
    const FieldSpec(
      'supplier_id',
      '供应商',
      Kind.ref,
      '',
      required: true,
      target: 'supplier',
    ),
    const FieldSpec(
      'product_id',
      '物料',
      Kind.ref,
      '',
      required: true,
      target: 'product',
    ),
    const FieldSpec(
      'price',
      '单价',
      Kind.decimal,
      '报价单价；已定标时实际成交按 deal_price',
      required: true,
    ),
    _currency,
    const FieldSpec(
      'tax_mode',
      '含税口径',
      Kind.enumeration,
      '',
      required: true,
      values: _taxModes,
    ),
    const FieldSpec(
      'unit_snapshot',
      '单位',
      Kind.text,
      '报价时的计量单位；单位不同的报价不能直接比较',
      required: true,
    ),
    const FieldSpec(
      'min_qty',
      '起订量',
      Kind.decimal,
      '需求数量低于起订量时，这条报价不可用',
      required: true,
    ),
    const FieldSpec('quoted_on', '报价日期', Kind.date, '供应商给出报价的日期'),
    const FieldSpec('contact_id', '联系人', Kind.ref, '报价的联系人', target: 'contact'),
    const FieldSpec(
      'contact_snapshot',
      '联系人快照',
      Kind.object,
      '报价时联系人的 {name, phone, wechat, email}，联系人以后改了也不变',
    ),
    const FieldSpec('tax_rate', '税率', Kind.decimal, '百分数，如 "13"'),
    const FieldSpec('lead_time_days', '交期（天）', Kind.integer, ''),
    const FieldSpec(
      'valid_until',
      '有效期至',
      Kind.date,
      '过期后报价不可用；未填时报价日期起 90 天内视为有效',
    ),
    _notes,
    const FieldSpec(
      'project_id',
      '项目',
      Kind.ref,
      '为哪个项目询的价；为空表示通用报价',
      target: 'project',
    ),
    const FieldSpec('inquiry_location', '询价地点', Kind.text, ''),
    const FieldSpec('inquirer_name', '询价人', Kind.text, '本公司询价的人'),
    const FieldSpec(
      'inquiry_precision',
      '询价时间精度',
      Kind.enumeration,
      '',
      values: {
        'date': '只知道日期（inquiry_date）',
        'instant': '精确到时刻（inquired_at）',
        'unknown': '不知道（仅历史资料）',
      },
    ),
    const FieldSpec('inquiry_date', '询价日期', Kind.date, ''),
    const FieldSpec('inquired_at', '询价时刻', Kind.instant, 'UTC 时间'),
    const FieldSpec(
      'inquiry_utc_offset_minutes',
      '询价时区',
      Kind.integer,
      '询价时刻所在时区相对 UTC 的分钟数，如 480 表示东八区',
    ),
    const FieldSpec(
      'capture_mode',
      '录入方式',
      Kind.enumeration,
      '',
      required: true,
      values: {
        'standard': '标准记录：必须有项目、询价人、询价日期、报价日期',
        'historical': '历史资料补录，信息可不全',
      },
    ),
    FieldSpec(
      'includes',
      '价格包含',
      Kind.textList,
      '为空表示未说明，[] 表示都不含',
      values: {
        'freight': '运费',
        'installation': '安装',
        'commissioning': '调试',
        'training': '培训',
      },
    ),
    const FieldSpec('warranty_months', '质保（月）', Kind.integer, ''),
    const FieldSpec(
      'extra_cost',
      '附加费用',
      Kind.decimal,
      '整单另收的费用（运费、包装等），摊到单价：有效单价 = 单价 + 附加费用 ÷ 数量',
    ),
    const FieldSpec('deal_price', '成交单价', Kind.decimal, '定标后谈定的单价，定标时必填'),
    const FieldSpec('awarded_on', '定标日期', Kind.date, '不为空表示这条报价已中标'),
    const FieldSpec('award_note', '定标说明', Kind.text, ''),
    const FieldSpec(
      'inquiry_id',
      '询价单',
      Kind.ref,
      '回复的是哪张询价单',
      target: 'inquiry',
    ),
    const FieldSpec(
      'attachment_ids',
      '附件',
      Kind.refList,
      '报价单原件等附件的 id（附件内容不通过工具提供）',
    ),
    const FieldSpec(
      'price_basis',
      '价格性质',
      Kind.enumeration,
      '为空表示正式书面报价；口头价和参考价只作参考，不用于预算和最低价',
      values: {'verbal': '口头报价', 'reference': '参考价（网价、往年价等）'},
    ),
    const FieldSpec(
      'price_tiers',
      '阶梯价',
      Kind.object,
      '[{min_qty, price}]，按报价单位：需求数量达到 min_qty 时单价为 price；'
          '数量递增且都大于起订量，最多 10 档。已定标的按成交价，不看阶梯',
    ),
  ]),
  ObjectType('inquiry', '询价单', '把一个项目的若干预算行发给若干供应商询价', [
    const FieldSpec(
      'project_id',
      '项目',
      Kind.ref,
      '',
      required: true,
      target: 'project',
    ),
    const FieldSpec('title', '标题', Kind.text, '', required: true),
    const FieldSpec(
      'item_ids',
      '询价的预算行',
      Kind.refList,
      '顺序即询价单上的行序，最多 500 行',
      required: true,
      target: 'project_item',
    ),
    const FieldSpec(
      'supplier_ids',
      '询价的供应商',
      Kind.refList,
      '最多 50 家',
      required: true,
      target: 'supplier',
    ),
    const FieldSpec('due_date', '截止日期', Kind.date, ''),
    const FieldSpec(
      'status',
      '状态',
      Kind.enumeration,
      '',
      required: true,
      values: {'open': '进行中', 'closed': '已结束'},
    ),
    _notes,
  ]),
  ObjectType('product_param', '物料参数', '物料的一项结构化参数（有类型、单位，可比较）；每个物料每个参数一条', [
    const FieldSpec(
      'product_id',
      '物料',
      Kind.ref,
      '',
      required: true,
      target: 'product',
    ),
    const FieldSpec(
      'property',
      '参数',
      Kind.text,
      '参数字典代码，如 cpu.cores（物理核数）、prot.ip（防护等级）',
      required: true,
    ),
    const FieldSpec(
      'value',
      '取值',
      Kind.object,
      '按参数类型：数值 {v,u}、范围 {min,max,u}、精度 {v,u} 或 {v,basis:FS|RD}、'
          '单选 {v}、多选 {vs}、是否 {v}、IP {codes}、防爆 {marks:[{types,group,temp,epl}]}、'
          '目录 {entries:[{name,batch,level,valid_until}]}；u 为单位代码',
      required: true,
    ),
    const FieldSpec('cond', '条件', Kind.text, '取值的条件说明，如"25℃ 时"'),
    FieldSpec(
      'source',
      '来源',
      Kind.enumeration,
      '',
      required: true,
      values: {
        'manual': '手填',
        'rule': '规则抽取',
        'ai': 'AI 抽取',
        'import': '导入',
        'decoder': '型号解码',
      },
    ),
    const FieldSpec('evidence', '依据', Kind.text, '依据原文，如说明书中的一句'),
    const FieldSpec('attachment_id', '依据文件', Kind.ref, '附件 id'),
    const FieldSpec(
      'confirmed',
      '已确认',
      Kind.boolean,
      '人工核对过；未确认的值只作参考',
      required: true,
    ),
    const FieldSpec(
      'dict_version',
      '字典版本',
      Kind.integer,
      '写入时的参数字典版本',
      required: true,
    ),
  ]),
  ObjectType('spec_request', '技术要求', '一份技术要求文件，通常挂在项目下', [
    const FieldSpec('project_id', '项目', Kind.ref, '', target: 'project'),
    const FieldSpec('title', '标题', Kind.text, '', required: true),
    const FieldSpec('source_name', '来源', Kind.text, '文件名或"粘贴文本"'),
    const FieldSpec('dict_version', '字典版本', Kind.integer, '', required: true),
    _notes,
  ]),
  ObjectType('spec_item', '需求项', '技术要求中的一台设备及其条款；可定选物料', [
    const FieldSpec(
      'request_id',
      '技术要求',
      Kind.ref,
      '',
      required: true,
      target: 'spec_request',
    ),
    const FieldSpec('seq', '序号', Kind.integer, '', required: true),
    const FieldSpec('name', '设备名称', Kind.text, '', required: true),
    const FieldSpec('spec_class', '参数模板', Kind.text, '类别代码'),
    const FieldSpec('qty', '数量', Kind.decimal, ''),
    const FieldSpec('unit', '单位', Kind.text, ''),
    const FieldSpec('text', '要求原文', Kind.text, ''),
    const FieldSpec(
      'project_item_id',
      '预算行',
      Kind.ref,
      '',
      target: 'project_item',
    ),
    const FieldSpec(
      'clauses',
      '条款',
      Kind.object,
      '[{n,text,mark:star|triangle|none,cs:[{p,op,value}],reviewed,hint}]；cs 为空是文字条款',
      required: true,
    ),
    const FieldSpec(
      'chosen_product_id',
      '定选物料',
      Kind.ref,
      '',
      target: 'product',
    ),
    const FieldSpec(
      'chosen_snapshot',
      '定选快照',
      Kind.object,
      '逐条响应 rows:[{n,response,outcome,note}]',
    ),
    _notes,
  ]),
];

/// Object types by name, in [entityTypes] order.
final Map<String, ObjectType> ontology = {
  for (final t in entityTypes) t: _types.firstWhere((o) => o.name == t),
};

/// Every reference between object types, from the stored reference maps.
final List<LinkType> links = [
  for (final MapEntry(key: from, value: fields) in references.entries)
    for (final MapEntry(key: field, value: to) in fields.entries)
      LinkType(from, field, to, many: false),
  for (final MapEntry(key: from, value: fields) in listReferences.entries)
    for (final MapEntry(key: field, value: to) in fields.entries)
      LinkType(from, field, to, many: true),
];

/// Business rules an agent needs to read the data correctly.
const rules = [
  Rule('decimal', '金额、数量、比率都是精确十进制文本（如 "12500.5"），原样引用，不要四舍五入；工具已完成的计算直接使用。'),
  Rule('comparable', '同币种报价可按税率换算含税口径，并按物料中的单位换算规则折算到基准单位；缺少税率或单位规则时不可跨口径比较。'),
  Rule('deal_price', '已定标（awarded_on 不为空）的报价按成交单价 deal_price 计，否则按报价单价 price。'),
  Rule('effective_price', '有效单价 = 单价 + 附加费用 extra_cost ÷ 需求数量；比较和选价都用有效单价。'),
  Rule(
    'usable',
    '可用报价：报价日期不晚于今天；未过有效期（未填有效期时报价日期起 $undatedValidityDays 天内）；'
        '需求数量不低于起订量；价格性质为正式报价（price_basis 为空）。含税口径未知的不参与最低价。',
  ),
  Rule('history', '单价与同口径历史均价偏离 $historyWarnPercent% 及以上时应提示用户核实。'),
  Rule(
    'budget',
    '预算行成本 = 数量 × 成本单价；销售单价未填时按项目加价率计算。预算提示：needs_inquiry 待询价、'
        'cheaper_available 有便宜 10% 以上的可用报价、quote_not_valid 采用的报价已失效、'
        'below_min_qty 数量低于所用报价的起订量；成本达到合同金额 90% 时提示。',
  ),
  Rule('soft_delete', '删除和合并都不移除记录：已删除（deleted）和已合并（merged_into）的记录默认不返回。'),
  Rule(
    'devices',
    '每台设备各自保存数据，通过交换文件合并；记录的 updated_at、updated_by 表示最后修改的时间和设备。',
  ),
];

/// What people can do in the app; agents describe these, never perform them.
const actions = [
  ActionType('save_record', '新建或修改记录', '在对应页面填写表单，通过校验后保存，并记入变更记录'),
  ActionType('award', '定标', '在比价或询价单里选中一条报价，填成交单价和定标日期，并可写回预算行'),
  ActionType('create_inquiry', '建询价单', '在项目里勾选预算行和供应商，可导出 Excel 询价表发给供应商'),
  ActionType('refresh_prices', '按最优价刷新', '把预算行的成本单价更新为当前最低的可用报价'),
  ActionType('merge_duplicates', '合并重复', '把重复的供应商或物料合并到保留的一条，引用自动改指向'),
  ActionType('smart_import', '智能导入', '粘贴报价信息或 Excel，由 AI 整理成供应商、物料、报价，人工核对后写入'),
  ActionType('exchange', '数据交换', '导出/导入交换文件、共享文件夹同步、局域网推送，在设备之间合并数据'),
];

/// Compact text of the model, for a system prompt.
String ontologyCard() {
  final b = StringBuffer('## 对象类型（字段：名称 类型 [必填] 说明）\n');
  for (final t in ontology.values) {
    b.writeln('### ${t.name} ${t.label}：${t.description}');
    for (final f in t.fields) {
      final extra = [
        if (f.target != null) '→${f.target}',
        if (f.values != null)
          f.values!.entries.map((e) => '${e.key}=${e.value}').join('/'),
        if (f.description.isNotEmpty) f.description,
      ].join('；');
      b.writeln(
        '- ${f.name} ${f.label} ${f.kind.label}'
        '${f.required ? ' 必填' : ''}${extra.isEmpty ? '' : '：$extra'}',
      );
    }
  }
  b.writeln('每条记录另有 id、updated_at、updated_by。');
  b.writeln('\n## 规则');
  for (final r in rules) {
    b.writeln('- ${r.text}');
  }
  return b.toString();
}

/// Enum values the validators accept, for the consistency test.
Map<String, List<String>> get validatorEnums => {
  'project.status': projectStatuses,
  'project.type': projectTypes,
  'project.level': projectLevels,
  'project_item.category': costCategories,
  'quotation.includes': quoteIncludes,
  'quotation.price_basis': priceBases,
  'product_param.source': paramSources,
  'supplier.rating': supplierRatings.keys.toList(),
  'inquiry.status': inquiryStatuses,
};
