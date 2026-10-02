import 'dart:convert';

import 'ai_runtime.dart';
import 'assistant_actions.dart';
import 'assistant_evidence.dart';
import 'assistant_toolset.dart';
import 'assistant_web_catalog.dart';
import 'assistant_web_tools.dart';
import 'attachments.dart';
import 'pricing.dart';
import 'product_params.dart';
import 'quotation.dart';
import 'spec_constraint.dart';
import 'spec_dictionary.dart';
import 'spec_values.dart';
import 'store.dart';
import 'values.dart';

/// The host calls this for every generic mutation, irrespective of model intent.
void guardAssistantProcurementWrite(
  String operation,
  String type,
  Map<String, Object?> values,
) {
  if (operation != 'create_record' && operation != 'update_record') return;
  if (type == 'product' ||
      type == 'quotation' ||
      (type == 'project_item' &&
          values.keys.any(
            const {
              'product_id',
              'quotation_id',
              'unit_cost',
              'unit_price',
              'requirement',
            }.contains,
          ))) {
    throw const FormatException('采购事实必须使用来源候选和审核导入工具');
  }
}

Map<String, Object?> _object(Object? value) =>
    (value as Map).cast<String, Object?>();
Object? _frozen(Object? value) => value is Map
    ? Map<String, Object?>.unmodifiable({
        for (final key in (value.keys.cast<String>().toList()..sort()))
          key: _frozen(value[key]),
      })
    : value is List
    ? List<Object?>.unmodifiable(value.map(_frozen))
    : value;
String _canonical(Object? value) => jsonEncode(_frozen(value));

class AssistantProcurementTools implements AssistantToolset {
  AssistantProcurementTools(
    this.store, {
    required this.web,
    required this.sessionId,
    required this.permission,
    this.approve,
    this.validateSession,
    this.onChanged,
    this.domesticCriterion,
    this.requestText = '',
  }) {
    if (sessionId.isEmpty || sessionId.length > 200)
      throw ArgumentError('Invalid session ID');
  }
  final Store store;
  final AssistantWebTools web;
  final String sessionId, requestText;
  final AssistantPermission permission;
  final Future<bool> Function(AssistantActionPreview)? approve;
  final void Function()? validateSession, onChanged;
  final String? Function()? domesticCriterion;
  String get _key => 'assistant_procurement:${jsonEncode(sessionId)}';
  String get _receiptPrefix =>
      'assistant_procurement_receipt:[${jsonEncode(sessionId)},';

  /// The host clears research cache only after completing the task. Imported
  /// source attachments and atomic action receipts remain business evidence.
  void clearTransient() =>
      store.db.execute('DELETE FROM meta WHERE key=?', [_key]);
  Map<String, Object?> _load() {
    final rows = store.db.select('SELECT value FROM meta WHERE key=?', [_key]);
    return rows.isEmpty
        ? {'candidates': <String, Object?>{}, 'reports': <Object?>[]}
        : _object(jsonDecode(rows.single['value'] as String));
  }

  void _save(Map<String, Object?> state) {
    final encoded = _canonical(state);
    if (utf8.encode(encoded).length > 512 * 1024)
      throw const FormatException('任务研究证据超过512KiB限制');
    store.db.execute(
      'INSERT INTO meta(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      [_key, encoded],
    );
  }

  List<Map<String, Object?>> get appliedActions => List.unmodifiable([
    for (final row in store.db.select(
      'SELECT value FROM meta WHERE substr(key,1,length(?))=? ORDER BY key LIMIT 24',
      [_receiptPrefix, _receiptPrefix],
    ))
      _object(_frozen(_object(jsonDecode(row['value'] as String))['result'])),
  ]);
  void _check(AiCancellation cancellation, {bool write = false}) {
    cancellation.check();
    validateSession?.call();
    if (write && permission == AssistantPermission.readOnly)
      throw const FormatException('只读模式禁止采购导入');
  }

  @override
  List<Map<String, Object?>> get tools => [
    _tool(
      'procurement_stage',
      '从真实网页产品行建立采购候选；预算行研究与替代必须指定原item_id。不得提交任何事实字段。',
      {
        'source_id': {'type': 'string'},
        'row_id': {'type': 'string'},
        'item_id': {'type': 'string'},
      },
      ['source_id', 'row_id'],
    ),
    _tool(
      'procurement_check',
      '逐项检查候选与原预算要求；unknown不代表合格。',
      {
        'candidate_id': {'type': 'string'},
      },
      ['candidate_id'],
    ),
    _tool(
      'procurement_compare',
      '严格同品牌完整型号配置、币种单位税运数量日期核价；至少两个独立卖方和域名，仅参考区间。',
      {
        'candidate_ids': {
          'type': 'array',
          'items': {'type': 'string'},
          'minItems': 2,
          'maxItems': 8,
        },
        'item_id': {'type': 'string'},
      },
      ['candidate_ids'],
    ),
    if (permission != AssistantPermission.readOnly)
      _tool(
        'procurement_import',
        '人工审核后保存资料与原始来源；报价固定参考价。预算替代需重新询价并在预算界面用正式报价完成。',
        {
          'candidate_id': {'type': 'string'},
          'operation': {
            'type': 'string',
            'enum': ['catalog'],
          },
        },
        ['candidate_id', 'operation'],
      ),
  ];
  Map<String, Object?> _tool(
    String name,
    String description,
    Map<String, Object?> properties,
    List<String> required,
  ) => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': {
        'type': 'object',
        'properties': properties,
        'required': required,
        'additionalProperties': false,
      },
    },
  };
  void _args(
    Map<String, Object?> args,
    Set<String> required, [
    Set<String> optional = const {},
  ]) {
    if (!args.keys.toSet().containsAll(required) ||
        args.keys.any((k) => !required.contains(k) && !optional.contains(k)))
      throw const FormatException('未知或缺少采购参数');
    for (final key in args.keys.where((k) => k != 'candidate_ids')) {
      if (args[key] is! String ||
          (args[key] as String).isEmpty ||
          (args[key] as String).length > 200)
        throw const FormatException('无效采购ID或操作');
    }
  }

  Record _live(String type, String id) {
    final record = store.get(type, requireUuid(id, 'id'));
    if (record == null || record.deleted)
      throw const FormatException('原业务记录不可用');
    return record;
  }

  Map<String, Object?> _record(Record r) => {
    'type': r.type,
    'id': r.id,
    'version': r.version,
    'deleted': r.deleted,
    'data': r.data,
  };
  Map<String, Object?> _bindings(String? itemId) {
    if (itemId == null) return {};
    final item = _live('project_item', itemId);
    return {
      'item': _record(item),
      'project': _record(_live('project', item.data['project_id'] as String)),
      if (item.data['product_id'] case final String id)
        'product': _record(_live('product', id)),
      if (item.data['quotation_id'] case final String id)
        'quotation': _record(_live('quotation', id)),
    };
  }

  Map<String, Object?> _candidate(String id) {
    final candidate = _object(_load()['candidates'])[id];
    if (candidate is! Map) throw const FormatException('未知候选ID');
    return candidate.cast<String, Object?>();
  }

  (AssistantWebSnapshot, AssistantWebProduct) _source(
    Map<String, Object?> candidate,
  ) {
    final snapshot = AssistantWebSnapshot.fromJson(
      _object(candidate['source']),
    );
    final row = snapshot.products
        .where((p) => p.id == candidate['row_id'])
        .firstOrNull;
    if (row == null) throw const FormatException('来源行不存在');
    return (snapshot, row);
  }

  void _fresh(Map<String, Object?> candidate) {
    if (_canonical(_bindings(candidate['item_id'] as String?)) !=
        _canonical(candidate['bindings']))
      throw const FormatException('原预算/项目/物料/报价已变更，请重新研究');
  }

  String get _today => store.clock().toIso8601String().substring(0, 10);
  Map<String, Object?> _qualification(Map<String, Object?> candidate) {
    final (snapshot, row) = _source(candidate);
    final requirement = candidate['requirement'] as String;
    final checks = <Map<String, Object?>>[];
    for (final raw
        in requirement
            .split(RegExp(r'[\n;；。]'))
            .where((s) => s.trim().isNotEmpty)) {
      final clause = raw.trim();
      var status = 'unknown';
      String? reason;
      String? evidence;
      String? countryField;
      if (RegExp(r'^(中国制造|中国生产|制造地[:：]?中国|国产制造)$').hasMatch(clause))
        countryField = 'manufacture_country';
      if (RegExp(r'^(中国品牌|国产品牌|品牌来源[:：]?中国)$').hasMatch(clause))
        countryField = 'brand_origin';
      if (clause == '国产') {
        countryField = switch (domesticCriterion?.call()) {
          'manufacture' => 'manufacture_country',
          'brand' => 'brand_origin',
          _ => null,
        };
        if (countryField == null) reason = '国产认定口径未由用户明确';
      }
      if (countryField != null) {
        evidence = row.facts[countryField];
        if (evidence != null)
          status =
              const {
                '中国',
                '中华人民共和国',
                'China',
                'CN',
                '中国大陆',
                'Mainland China',
              }.contains(evidence)
              ? 'source_supported'
              : 'contradicted';
        else
          reason = '来源未明确声明所需国别，品牌与制造地不可混用';
      } else if (reason == null) {
        final parsed = _numericRequirement(clause);
        if (parsed != null) {
          final (property, constraint) = parsed;
          evidence =
              row.parameters[property.code] ?? row.parameters[property.label];
          final have = evidence == null ? null : _number(property, evidence);
          if (have != null) {
            final verdict = evaluateConstraint(
              property,
              have,
              constraint,
              today: _today,
            );
            status = verdict.satisfied
                ? 'source_supported'
                : verdict.outcome.name == 'worse'
                ? 'contradicted'
                : 'unknown';
            reason = verdict.note;
          } else {
            reason = '缺少明确字典参数或单位不支持';
          }
        } else {
          reason = '完整条款未被支持的严格规则解析，须人工核验';
        }
      }
      checks.add({
        'requirement': clause,
        'status': status,
        'evidence': evidence,
        'reason': reason,
      });
    }
    if (checks.isEmpty)
      checks.add({
        'requirement': requirement,
        'status': 'unknown',
        'reason': '未绑定完整技术要求，仅供资料研究',
      });
    if (snapshot.truncated)
      checks.add({
        'requirement': '来源完整性',
        'status': 'unknown',
        'reason': '网页快照被截断',
      });
    if (row.warnings.isNotEmpty)
      checks.add({
        'requirement': '来源字段完整性',
        'status': 'unknown',
        'reason': row.warnings.join('；'),
      });
    final status = checks.any((c) => c['status'] == 'contradicted')
        ? 'contradicted'
        : checks.every((c) => c['status'] == 'source_supported')
        ? 'source_supported'
        : 'unknown';
    return {
      'candidate_id': candidate['id'],
      'requirement': requirement,
      'status': status,
      'checks': checks,
      'review': 'source_supported仅为网页声明支持，须逐项人工审阅，不保证网页真实',
    };
  }

  (SpecProperty, SpecConstraint)? _numericRequirement(String clause) {
    for (final property in specProperties.where(
      (p) => p.type == ParamType.num,
    )) {
      for (final label in [property.code, property.label]) {
        if (!clause.startsWith(label)) continue;
        final match = RegExp(
          r'^\s*(>=|<=|≥|≤|=|不低于|不少于|不高于|不超过|等于)\s*(.+)$',
        ).firstMatch(clause.substring(label.length));
        if (match == null) continue;
        final number = _number(property, match[2]!);
        if (number == null) continue;
        final op = const {
          '>=': 'ge',
          '≥': 'ge',
          '不低于': 'ge',
          '不少于': 'ge',
          '<=': 'le',
          '≤': 'le',
          '不高于': 'le',
          '不超过': 'le',
          '=': 'eq',
          '等于': 'eq',
        }[match[1]]!;
        return (property, SpecConstraint(property.code, op, number));
      }
    }
    return null;
  }

  Map<String, Object?>? _number(SpecProperty property, String text) {
    final m = RegExp(
      r'^\s*([0-9]+(?:\.[0-9]+)?)\s*([^\s]*)\s*$',
    ).firstMatch(text);
    if (m == null) return null;
    final unit = m[2]!;
    if (property.kind != null && unit.isEmpty) return null;
    if (property.kind == null && unit.isNotEmpty && unit != property.unitLabel)
      return null;
    try {
      return normalizeParamValue(property, {
        'v': m[1],
        if (property.kind != null) 'u': unit,
      });
    } on FormatException {
      return null;
    }
  }

  List<String> _priceProblems(AssistantWebProduct row) {
    final facts = row.facts, missing = <String>[];
    for (final field in [
      'brand',
      'model',
      'configuration',
      'supplier',
      'price',
      'currency',
      'unit',
      'tax_mode',
      'tax_rate',
      'shipping',
      'min_qty',
      'quoted_on',
      'valid_until',
    ]) {
      if (facts[field] == null) missing.add('缺少$field');
    }
    if (row.warnings.isNotEmpty) missing.addAll(row.warnings);
    try {
      ExactDecimal.parse(facts['price'] ?? '', positive: true);
      ExactDecimal.parse(facts['min_qty'] ?? '', positive: true);
    } on FormatException {
      missing.add('价格或最小数量不是明确正十进制值');
    }
    if (!const {'included', 'excluded'}.contains(facts['tax_mode']))
      missing.add('税口径未知');
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(facts['currency'] ?? ''))
      missing.add('币种无效');
    try {
      final rate = ExactDecimal.parse(
        facts['tax_rate'] ?? '',
        maxIntegerDigits: 3,
        maxFractionDigits: 4,
      );
      if (rate.compareTo(ExactDecimal.parse('100')) > 0) missing.add('税率超出范围');
    } on FormatException {
      missing.add('税率不是明确十进制值');
    }
    if (!const {
      'included',
      'excluded',
      'free',
      '含运费',
      '不含运费',
      '包邮',
      '免运费',
    }.contains(facts['shipping']))
      missing.add('运费口径未知');
    for (final field in ['quoted_on', 'valid_until']) {
      try {
        requireDate(facts[field], field);
      } on FormatException {
        missing.add('$field日期无效');
      }
    }
    final today = _today;
    if ((facts['quoted_on'] ?? '9999').compareTo(today) > 0)
      missing.add('报价日期晚于今天');
    if ((facts['valid_until'] ?? '0000').compareTo(today) < 0)
      missing.add('报价过期或有效期未知');
    if (facts['quoted_on'] != null &&
        facts['valid_until'] != null &&
        facts['valid_until']!.compareTo(facts['quoted_on']!) < 0)
      missing.add('日期顺序矛盾');
    return missing;
  }

  Map<String, Object?> _compare(List<String> ids, String? itemId) {
    final rows = [for (final id in ids) _candidate(id)];
    for (final c in rows) _fresh(c);
    final target = _bindings(itemId);
    final product = target['product'] == null
        ? null
        : _object(_object(target['product'])['data']);
    final item = target['item'] == null
        ? null
        : _object(_object(target['item'])['data']);
    final included = <Map<String, Object?>>[],
        excluded = <Map<String, Object?>>[];
    Map<String, String>? basis;
    final sellers = <String>{}, domains = <String>{};
    final prices = <BigInt>[];
    for (final c in rows) {
      final (source, row) = _source(c);
      final f = row.facts;
      final problems = _priceProblems(row);
      if (source.truncated) problems.add('来源截断');
      if (product != null &&
          (f['brand'] != product['brand'] || f['model'] != product['model']))
        problems.add('与项目品牌或完整型号不同');
      if (item != null) {
        if (f['unit'] != item['unit']) problems.add('与项目单位不同');
        try {
          if (micros(f['min_qty']!) > micros(item['qty'] as String))
            problems.add('项目数量未达到最小起订量');
        } catch (_) {
          problems.add('数量条件未知');
        }
      }
      final b = {
        for (final key in [
          'brand',
          'model',
          'configuration',
          'currency',
          'unit',
          'tax_mode',
          'tax_rate',
          'shipping',
          'min_qty',
          'quoted_on',
          'valid_until',
        ])
          key: f[key] ?? '',
      };
      if (basis != null && _canonical(b) != _canonical(basis))
        problems.add('样本品牌/完整型号/配置/币种/单位/税运/数量/日期口径不同');
      // Conservative grouping also rejects subdomains as independent sellers.
      final labels = Uri.parse(source.url).host.toLowerCase().split('.');
      final host = labels
          .skip(labels.length > 2 ? labels.length - 2 : 0)
          .join('.');
      final seller = (f['supplier'] ?? '').trim().toLowerCase();
      if (sellers.contains(seller) || domains.contains(host))
        problems.add('卖方或域名重复，不能作为独立样本');
      if (problems.isNotEmpty) {
        excluded.add({'candidate_id': c['id'], 'reasons': problems});
        continue;
      }
      basis ??= b;
      sellers.add(seller);
      domains.add(host);
      prices.add(micros(f['price']!));
      included.add({
        'candidate_id': c['id'],
        'source': source.url,
        'seller': f['supplier'],
        'price': f['price'],
      });
    }
    prices.sort();
    return {
      'kind': 'comparison',
      'as_of': _today,
      'status': prices.length >= 2
          ? 'reference_range'
          : 'insufficient_evidence',
      'included': included,
      'excluded': excluded,
      'basis': basis,
      if (prices.length >= 2) 'min': fromMicros(prices.first),
      if (prices.length >= 2) 'max': fromMicros(prices.last),
      'project_difference': _projectDifference(target, basis, prices),
      'notice': '仅网页参考样本区间，不是公允价或合理性结论；不支持的字段必须人工核验',
    };
  }

  Map<String, Object?> _projectDifference(
    Map<String, Object?> bindings,
    Map<String, String>? basis,
    List<BigInt> prices,
  ) {
    final reasons = <String>[];
    if (bindings['item'] == null)
      return {
        'status': 'not_comparable',
        'reasons': ['未指定预算行'],
      };
    if (basis == null || prices.length < 2)
      return {
        'status': 'not_comparable',
        'reasons': ['缺少两个完整同口径独立样本'],
      };
    final item = _object(_object(bindings['item'])['data']);
    final product = bindings['product'] == null
        ? null
        : _object(_object(bindings['product'])['data']);
    final quote = bindings['quotation'] == null
        ? null
        : _object(_object(bindings['quotation'])['data']);
    final project = _object(_object(bindings['project'])['data']);
    if (product == null) reasons.add('预算没有明确物料');
    if (quote == null)
      return {
        'status': 'not_comparable',
        'reasons': [...reasons, '预算未选择正式报价'],
      };
    if (quote['price_basis'] != null || quote['capture_mode'] != 'standard')
      reasons.add('选中报价不是正式标准报价');
    if (quote['product_id'] != item['product_id']) reasons.add('选中报价与预算物料不同');
    if (quote['project_id'] != _object(bindings['project'])['id'])
      reasons.add('选中报价不属于当前项目');
    for (final field in ['brand', 'model']) {
      if (product?[field] == null || product?[field] != basis[field])
        reasons.add('本机$field与来源不一致或缺失');
    }
    final configs = <String>{};
    final attrs = product?['attributes'];
    if (attrs is Map)
      for (final key in ['configuration', '配置']) {
        if (attrs[key] case final String value when value.isNotEmpty)
          configs.add(value);
      }
    // A source document can supply configuration only when its selected row is
    // bound to this exact product and all of this quotation's core terms.
    for (final id in quote['attachment_ids'] as List? ?? const []) {
      final attachment = store.attachment(id as String);
      if (attachment?.bytes == null || attachment!.size > 512 * 1024) continue;
      try {
        final evidence = _object(jsonDecode(utf8.decode(attachment.bytes!)));
        final source = AssistantWebSnapshot.fromJson(
          _object(evidence['source']),
        );
        if (source.truncated) continue;
        final row = source.products
            .where((p) => p.id == evidence['selected_row_id'])
            .firstOrNull;
        if (row == null || row.warnings.isNotEmpty) continue;
        final f = row.facts;
        if (f['brand'] != product?['brand'] || f['model'] != product?['model'])
          continue;
        if (f['unit'] != quote['unit_snapshot']) continue;
        if (['price', 'tax_rate', 'min_qty'].any(
          (key) =>
              f[key] == null ||
              quote[key] == null ||
              micros(f[key]!) != micros(quote[key] as String),
        ))
          continue;
        if ([
          'currency',
          'tax_mode',
          'quoted_on',
          'valid_until',
        ].any((key) => f[key] != quote[key]))
          continue;
        if (f['configuration'] case final String configuration)
          configs.add(configuration);
      } catch (_) {
        /* Ordinary non-source attachments provide no typed facts. */
      }
    }
    if (configs.length != 1 || configs.single != basis['configuration'])
      reasons.add('本机配置缺失、冲突或与来源不同');
    for (final field in ['currency', 'tax_mode', 'quoted_on', 'valid_until']) {
      if (quote[field] == null || quote[field] != basis[field])
        reasons.add('正式报价$field与来源不同或缺失');
    }
    for (final field in ['currency', 'tax_mode'])
      if (project[field] != basis[field]) reasons.add('项目$field与来源不同，不自动换算');
    if (item['unit'] != basis['unit'] ||
        quote['unit_snapshot'] != basis['unit'])
      reasons.add('预算/正式报价单位与来源不同，不自动换算');
    for (final field in ['tax_rate', 'min_qty']) {
      try {
        if (micros(quote[field] as String) != micros(basis[field]!))
          reasons.add('正式报价$field与来源不同');
      } catch (_) {
        reasons.add('正式报价$field缺失或无效');
      }
    }
    final scope = quote['includes'];
    final shipping = basis['shipping'];
    final included = const {
      'included',
      'free',
      '含运费',
      '包邮',
      '免运费',
    }.contains(shipping);
    final excluded = const {'excluded', '不含运费'}.contains(shipping);
    if (scope is! List)
      reasons.add('正式报价运费范围未知');
    else {
      if ((!included && !excluded) || scope.contains('freight') != included)
        reasons.add('正式报价运费范围与来源不同');
      if (scope.any((value) => value != 'freight'))
        reasons.add('正式报价包含安装/调试/培训等额外范围，不能视为同口径单价');
    }
    if (quote['extra_cost'] != null &&
        micros(quote['extra_cost'] as String) != BigInt.zero)
      reasons.add('正式报价存在额外费用，需另行核对');
    if (quote['price_tiers'] != null) reasons.add('正式报价有阶梯价格，当前工具不推定适用档位');
    if (micros(item['qty'] as String) < micros(quote['min_qty'] as String))
      reasons.add('预算数量低于正式报价最小数量');
    final cost = micros(item['unit_cost'] as String),
        quoted = micros(quote['price'] as String);
    if (cost != quoted) reasons.add('预算成本快照与当前正式报价单价不同');
    if (reasons.isNotEmpty)
      return {'status': 'not_comparable', 'reasons': reasons};
    return {
      'status': 'comparable_unit_price',
      'scope': '仅比较同口径单价，不代表总采购成本或市场公允价',
      'project_unit_cost': fromMicros(cost),
      'currency': basis['currency'],
      'unit': basis['unit'],
      'difference_from_min': fromMicros(cost - prices.first),
      'difference_from_max': fromMicros(cost - prices.last),
      'position': cost < prices.first
          ? 'below_reference_range'
          : cost > prices.last
          ? 'above_reference_range'
          : 'within_reference_range',
    };
  }

  @override
  Future<String> execute(
    String name,
    Map<String, Object?> arguments, {
    required String callId,
    required AiCancellation cancellation,
  }) async {
    _check(cancellation);
    if (callId.isEmpty || callId.length > 200)
      throw const FormatException('Invalid call ID');
    final args = _object(_frozen(arguments));
    switch (name) {
      case 'procurement_stage':
        _args(args, {'source_id', 'row_id'}, {'item_id'});
        final source = web.snapshot(args['source_id'] as String);
        if (source == null ||
            !source.products.any((p) => p.id == args['row_id']))
          throw const FormatException('没有真实来源快照或产品行');
        final bindings = _bindings(args['item_id'] as String?);
        final requirement = bindings['item'] == null
            ? requestText
            : (_object(_object(bindings['item'])['data'])['requirement']
                      as String? ??
                  '');
        final id = derivedUuid(
          _canonical([source.id, args['row_id'], bindings, requirement]),
        );
        final state = _load(), candidates = _object(_load()['candidates']);
        if (!candidates.containsKey(id) && candidates.length >= 8)
          throw const FormatException('任务最多8个候选');
        final candidate = <String, Object?>{
          'id': id,
          'source': source.toJson(),
          'row_id': args['row_id'],
          'item_id': args['item_id'],
          'requirement': requirement,
          'bindings': bindings,
        };
        candidates[id] = candidate;
        state['candidates'] = candidates;
        _save(state);
        return _canonical({
          'candidate_id': id,
          'source_id': source.id,
          'row_id': args['row_id'],
          'facts': _source(candidate).$2.facts,
          'qualification': _qualification(candidate),
        });
      case 'procurement_check':
        _args(args, {'candidate_id'});
        final c = _candidate(args['candidate_id'] as String);
        _fresh(c);
        return _canonical(_qualification(c));
      case 'procurement_compare':
        _args(args, {'candidate_ids'}, {'item_id'});
        final ids = args['candidate_ids'];
        if (ids is! List ||
            ids.length < 2 ||
            ids.length > 8 ||
            ids.any((v) => v is! String) ||
            ids.toSet().length != ids.length)
          throw const FormatException('需要2至8个不同候选ID');
        final report = _compare(ids.cast<String>(), args['item_id'] as String?);
        final state = _load();
        final inputKey = _canonical([ids.toList()..sort(), args['item_id']]);
        state['reports'] = [
          ...(state['reports'] as List)
              .where((old) => _object(old)['input_key'] != inputKey)
              .toList()
              .reversed
              .take(7)
              .toList()
              .reversed,
          {
            'input_key': inputKey,
            'candidate_ids': ids,
            'item_id': args['item_id'],
            'as_of': _today,
            'bindings': _bindings(args['item_id'] as String?),
            'result': report,
          },
        ];
        _save(state);
        return _canonical(report);
      case 'procurement_import':
        _args(args, {'candidate_id', 'operation'});
        return _import(args, callId, cancellation);
      default:
        throw const FormatException('Unknown procurement tool');
    }
  }

  Future<String> _import(
    Map<String, Object?> args,
    String callId,
    AiCancellation cancellation,
  ) async {
    _check(cancellation, write: true);
    final operation = args['operation'];
    if (operation != 'catalog')
      throw const FormatException('仅可导入资料；替换预算须重新询价并使用正式报价');
    final key =
            'assistant_procurement_receipt:${jsonEncode([sessionId, callId])}',
        canonical = _canonical(args);
    String? receipt() {
      final rows = store.db.select('SELECT value FROM meta WHERE key=?', [key]);
      if (rows.isEmpty) return null;
      final r = _object(jsonDecode(rows.single['value'] as String));
      if (r['arguments'] != canonical) throw const FormatException('调用ID参数改变');
      return _canonical(r['result']);
    }

    final replay = receipt();
    if (replay != null) return replay;
    final candidate = _candidate(args['candidate_id'] as String);
    _fresh(candidate);
    final (source, row) = _source(candidate);
    final qualification = _qualification(candidate);
    final criterion = domesticCriterion?.call();
    final f = row.facts;
    if (f['name'] == null || f['unit'] == null)
      throw const FormatException('来源缺物料名称或单位，不能创建物料；候选和来源已保留');
    final product = validatePayload('product', {
      for (final key in payloadFields('product')) key: null,
      'name': f['name'],
      'unit': f['unit'],
      'brand': f['brand'],
      'model': f['model'],
      'notes': '网页研究资料，未核验；来源 ${source.url}',
    });
    final bindings = _object(candidate['bindings']);
    final before = bindings['item'] == null
        ? <String, Object?>{}
        : _object(_object(bindings['item'])['data']);
    final priceProblems = _priceProblems(row);
    if (source.truncated) priceProblems.add('来源截断');
    if (bindings['project'] == null) priceProblems.add('缺少项目，不能建立标准参考报价');
    final preview = AssistantActionPreview(
      operation: 'procurement_import',
      type: 'product',
      id: candidate['id'] as String,
      title: '逐项审核网页采购资料（不保证来源真实）',
      before: before,
      after: {
        'operation': operation,
        'product': product,
        'requirement': candidate['requirement'],
        'qualification': qualification,
        'source': source.toJson(),
        'quote_exclusions': priceProblems,
        'reference_quote': priceProblems.isEmpty,
        'cost_policy': '仅新增资料；原预算完全保持，待重新询价并在预算界面用正式报价完成替换',
      },
      affectedReferences: {},
      referencedRecords: bindings,
      version: bindings['item'] == null
          ? null
          : _object(bindings['item'])['version'] as int,
    );
    if (approve == null) throw const FormatException('没有人工审核界面');
    if (!await cancellation.wait(approve!(preview))) {
      _check(cancellation, write: true);
      return _canonical({'status': 'denied', 'candidate_id': candidate['id']});
    }
    _check(cancellation, write: true);
    var applied = false;
    final result = store.transaction(() {
      _check(cancellation, write: true);
      final prior = receipt();
      if (prior != null) return prior;
      _fresh(candidate);
      final currentPriceProblems = _priceProblems(row);
      if (source.truncated) currentPriceProblems.add('来源截断');
      if (bindings['project'] == null)
        currentPriceProblems.add('缺少项目，不能建立标准参考报价');
      if (_canonical(currentPriceProblems) != _canonical(priceProblems))
        throw const FormatException('报价时效或条件已变，请重新审核');
      if (criterion != domesticCriterion?.call() ||
          _canonical(qualification) != _canonical(_qualification(candidate)))
        throw const FormatException('审核期间认定条件改变');
      final attachmentId = store.addAttachment(
        '采购来源-${source.digest.substring(0, 12)}.json',
        utf8.encode(
          _canonical({
            'source': source.toJson(),
            'selected_row_id': row.id,
            'requirement': candidate['requirement'],
            'qualification': qualification,
          }),
        ),
        mime: 'application/json',
      );
      final productId = store.save('product', {
        ...product,
        'source_attachment_ids': [attachmentId],
        'notes': '未核验网页资料；来源附件 $attachmentId；${source.url}',
      });
      for (final property in specProperties.where(
        (p) => p.type == ParamType.num,
      )) {
        final raw =
            row.parameters[property.code] ?? row.parameters[property.label];
        final value = raw == null ? null : _number(property, raw);
        if (value != null)
          store.setParam(
            productId,
            property.code,
            value,
            source: 'import',
            confirmed: false,
            evidence: raw,
            attachmentId: attachmentId,
          );
      }
      String? supplierId, quotationId;
      if (f['supplier'] != null)
        supplierId = store.save('supplier', {
          for (final field in payloadFields('supplier')) field: null,
          'name': f['supplier'],
          'aliases': <String>[],
          'categories': <String>[],
          'notes': '网页声明供应方，未核验；来源附件 $attachmentId',
        });
      if (priceProblems.isEmpty && supplierId != null) {
        final projectId = _object(bindings['project'])['id'];
        quotationId = store.save('quotation', {
          for (final field in payloadFields('quotation')) field: null,
          'supplier_id': supplierId,
          'product_id': productId,
          'project_id': projectId,
          'price': f['price'],
          'currency': f['currency'],
          'tax_mode': f['tax_mode'],
          'tax_rate': f['tax_rate'],
          'unit_snapshot': f['unit'],
          'min_qty': f['min_qty'],
          'quoted_on': f['quoted_on'],
          'valid_until': f['valid_until'],
          'capture_mode': 'standard',
          'price_basis': 'reference',
          'inquirer_name': '网页研究',
          'inquiry_precision': 'date',
          'inquiry_date': f['quoted_on'],
          'attachment_ids': [attachmentId],
          'notes':
              '网页参考价；运费口径 ${f['shipping']}；配置 ${f['configuration']}；未核验，不作为正式报价或成本',
        });
      }
      final result = <String, Object?>{
        'status': 'applied',
        'candidate_id': candidate['id'],
        'product_id': productId,
        'supplier_id': supplierId,
        'quotation_id': quotationId,
        'attachment_id': attachmentId,
        'item_id': candidate['item_id'],
        'price_basis': 'reference',
        'qualification': qualification['status'],
        'cost_status': 'unchanged',
        'next_step': '待重新询价，在预算界面用正式报价完成替换',
      };
      store.db.execute('INSERT INTO meta(key,value) VALUES (?,?)', [
        key,
        _canonical({'arguments': canonical, 'result': result}),
      ]);
      applied = true;
      return _canonical(result);
    });
    if (applied) {
      try {
        onChanged?.call();
      } catch (_) {}
    }
    return result;
  }

  /// Host-generated only: never reads or interpolates the model's final prose.
  String renderReport(AssistantAnswer answer) {
    final state = _load(), candidates = _object(_load()['candidates']);
    final lines = <String>['采购研究证据报告（网页声明不等于真实认证）'];
    for (final candidate in candidates.values) {
      final c = _object(candidate);
      final (source, row) = _source(c);
      final q = _qualification(c);
      var stale = false;
      try {
        _fresh(c);
      } on FormatException {
        stale = true;
      }
      lines.add(
        _canonical({
          'candidate_id': c['id'],
          'facts': row.facts,
          'source': source.url,
          'fetched_at': source.fetchedAt,
          'digest': source.digest,
          'truncated': source.truncated,
          'local_bindings_stale': stale,
          if (stale) 'warning': '本机原要求或关联记录已变更，必须重新研究后审核',
          'qualification': q,
        }),
      );
    }
    for (final raw in state['reports'] as List) {
      final stored = _object(raw);
      try {
        final itemId = stored['item_id'] as String?;
        if (_canonical(_bindings(itemId)) != _canonical(stored['bindings']))
          throw const FormatException('项目引用已改变');
        final ids = (stored['candidate_ids'] as List).cast<String>();
        lines.add(_canonical(_compare(ids, itemId)));
      } catch (_) {
        lines.add(
          _canonical({
            'kind': 'comparison',
            'status': 'stale_comparison',
            'as_of': _today,
            'reason': '原项目、候选或报告依据已改变，请重新核价；不显示旧区间',
          }),
        );
      }
    }
    for (final receipt in appliedActions)
      lines.add('已保存：${_canonical(receipt)}');
    if (candidates.isEmpty) lines.add('尚无可信来源候选，不能确认物料、价格或资格。');
    lines.add('支持范围：明确关联产品行、严格数字字典条件和明确国别；复杂条款、未标示单位/税运/有效期及网页真实性须人工核验。');
    return lines.join('\n\n');
  }
}
