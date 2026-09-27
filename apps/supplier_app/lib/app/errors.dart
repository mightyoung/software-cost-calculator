import 'package:supplier_core/supplier_core.dart';

import 'format.dart';

/// Chinese for every reason the core validators raise. A test scans the core
/// sources so a new English reason cannot reach users untranslated.
const _reasons = {
  'required': '必填',
  'precision exceeded': '位数超出（最多 12 位整数、6 位小数）',
  'expected unsigned decimal text': '应为不带符号的数字',
  'decimal text required': '应为数字',
  'expected a number': '应为数字',
  'must be positive': '必须大于 0',
  'must be at most 100': '不能超过 100',
  'must be at most 1000 percent': '不能超过 1000%',
  'currency or tax mode differs from project': '币种或含税口径与项目不一致',
  'currency, tax mode or unit cannot be converted': '币种、含税口径或单位无法换算到项目预算口径',
  'clear budget and contract amount before changing project price basis':
      '已有预算行或合同金额。请先处理这些金额，再修改项目币种或含税口径',
  'must use the project price basis': '采用报价时，成本单价须使用项目税口径和预算行单位的折算价',
  'clear or reconfigure conversions when changing the base unit':
      '修改基准单位前请清空旧换算，或按新基准单位重新设置',
  'expected at most 50 conversions': '最多设置 50 条单位换算',
  'duplicate or base unit, or invalid factor': '来源单位不能重复或等于基准单位，换算数量须为正数',
  'record does not exist': '记录已被删除',
  'record is not deleted': '记录没有被删除',
  'clearing existing information requires explicit confirmation': '不能直接清空已有内容',
  'standard cannot be downgraded': '标准记录不能改为历史资料',
  'already merged': '已经合并过',
  'at least one contact method required': '电话、微信、邮箱至少填一项',
  'budget snapshot currency and tax mode must match': '复制预算行时，两个项目的币种和含税口径必须一致',
  'cannot be merged': '这类记录不能合并',
  'cannot merge into itself': '不能合并到自己',
  'cannot restore inside another transaction': '正在写入其他数据，请稍后再恢复',
  'choose a new safety backup path': '恢复前备份的文件名已存在，请重试',
  'choose a snapshot, not the active library': '请选择备份文件，不能选正在使用的数据库',
  'contact or supplier does not match': '联系人不属于这家供应商',
  'damaged': '文件已损坏',
  'does not match instant and offset': '与询价时刻和时区不一致',
  'does not match its content': '与文件内容不符',
  'empty file': '文件是空的',
  'expected 0 or 1': '数据格式错误',
  'expected YYYY-MM-DD': '日期格式应为 年-月-日，例如 2026-09-28',
  'expected a list of 1-100 values': '应为 1 到 100 个值',
  'expected array': '应为列表',
  'expected explicit timezone and at most milliseconds': '时间格式错误',
  'expected lowercase UUID v4': '记录编号格式错误',
  'expected object': '数据格式错误',
  'expected text': '应为文字',
  'expected three uppercase letters': '应为三位大写字母，例如 CNY',
  'expected timestamp': '时间格式错误',
  'historical records come only from imports': '历史资料只能通过导入录入',
  'instant required': '缺少询价时刻',
  'invalid XML character or isolated surrogate': '含有无法保存的特殊字符',
  'invalid calendar date': '日期不存在',
  'invalid offset': '时区无效',
  'invalid precision or incompatible fields': '询价时间信息不完整或相互矛盾',
  'invalid tax mode': '含税口径无效',
  'invalid time': '时间无效',
  'larger than 20 MB': '超过 20 MB',
  'library changed since safety backup': '恢复期间数据有变动，已取消恢复，请重试',
  'line is not part of this inquiry': '这一行不在询价单里',
  'local year out of range': '年份超出范围',
  'UTC year out of range': '年份超出范围',
  'made by a newer version; upgrade this device first': '来自更新版本的软件，请先升级本机',
  'missing attachment': '附件缺失',
  'missing or unknown keys': '数据字段不完整或有多余字段',
  'must copy selected contact at capture time': '联系方式须与所选联系人一致',
  'must not be earlier than start_date': '不能早于开始日期',
  'not a matching budget snapshot': '复制的预算行与原行不一致',
  'not a supported exchange file': '不是本软件支持的交换文件',
  'not an encrypted exchange file': '不是加密的交换文件',
  'not found': '找不到文件',
  'not in canonical form': '数据格式不规范，文件可能被其他程序改过',
  'only material lines reference products': '只有材料设备行可以关联物料',
  'payload requires canonical UTC milliseconds': '时间格式错误',
  'quotation is for another product': '这条报价不是这个物料的',
  'required for standard capture': '标准记录必填',
  'required storage field': '缺少必需字段',
  'required when contact is bound': '选择联系人后必须带上联系方式',
  'requires product_id': '需要先关联物料',
  'requires quoted_on no later than valid_until': '不能早于报价日期',
  'safety backup verification failed': '恢复前备份校验失败，已取消恢复',
  'search covers product, supplier and project': '只能搜索物料、供应商和项目',
  'supplier is not invited': '这家供应商不在询价单里',
  'too many items': '数量太多',
  'unknown cost category': '成本类别无效',
  'unknown entity type': '数据类型无效',
  'unknown field': '含有不认识的字段',
  'unknown line': '询价单里没有这一行',
  'unknown link': '关系无效',
  'unknown mode': '录入方式无效',
  'unknown object type': '数据类型无效',
  'unknown value': '不是允许的取值',
};

/// Reasons carrying a number or name.
final _patterns = <(RegExp, String Function(Match))>[
  (RegExp(r'^exceeds (\d+) codepoints$'), (m) => '不能超过 ${m[1]} 个字'),
  (
    RegExp(r'^expected finite safe integer from (-?\d+) to (-?\d+)$'),
    (m) => '应为 ${m[1]} 到 ${m[2]} 之间的整数',
  ),
  (RegExp(r'^missing (\w+) record$'), (m) => '引用的${_type(m[1]!)}不存在'),
  (RegExp(r'^unknown field (\w+)$'), (m) => '没有“${_label(m[1]!)}”这个字段'),
  (RegExp(r'^unknown (\w+)$'), (m) => '${_type(m[1]!)}不存在'),
  (RegExp(r'^required for \w+$'), (_) => '缺少比较值'),
  (RegExp(r'^use one of '), (_) => '比较方式无效'),
];

/// Field names outside the ontology.
const _extraLabels = {
  'file': '文件',
  'backup': '恢复前备份',
  'restore': '恢复',
  'attachment': '附件',
  'payload': '数据',
  'data': '数据',
  'value': '比较值',
  'op': '比较方式',
  'type': '类型',
  'entity_type': '类型',
  'entity': '类型',
  'link': '关系',
  'id': '记录',
  'field': '字段',
  'decimal': '数值',
  'updated_at': '修改时间',
  'added_at': '添加时间',
  'deleted': '删除标记',
  'size': '大小',
  'snapshotSourceItemId': '复制来源',
  'contact_snapshot': '联系人',
  'project': '项目',
};

String _type(String name) =>
    ontology[name]?.label ??
    const {'attachment': '附件', 'contact': '联系人'}[name] ??
    name;

String _label(String field) {
  if (fieldLabels[field] case final label?) return label;
  if (_extraLabels[field] case final label?) return label;
  for (final t in ontology.values) {
    if (t.field(field) case final f?) return f.label;
  }
  return field;
}

/// Maps core validation messages ("field: reason") to short Chinese text.
String friendlyError(String message) {
  final i = message.indexOf(': ');
  if (i < 0) return message;
  final field = message.substring(0, i);
  final reason = message.substring(i + 2);
  final label = _label(field.split('.').last);
  final text =
      _reasons[reason] ??
      [
        for (final (pattern, render) in _patterns)
          if (pattern.firstMatch(reason) case final m?) render(m),
      ].firstOrNull ??
      reason;
  return '$label：$text';
}
