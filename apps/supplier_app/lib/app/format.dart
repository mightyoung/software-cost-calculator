/// Exact decimal text to display text: thousands separators, 2 to 6
/// fraction digits, never through a double.
/// Chinese labels for payload fields, used in messages and conflict lists.
const fieldLabels = {
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
  'start_date': '开始日期',
  'decimal': '数值',
  'aliases': '别名',
  'address': '地址',
  'categories': '主营类别',
  'notes': '备注',
  'brand': '品牌',
  'model': '型号',
  'specification': '规格参数',
  'category': '类别',
  'phone': '电话',
  'wechat': '微信',
  'email': '邮箱',
  'currency': '币种',
  'tax_mode': '含税口径',
  'tax_rate': '税率',
  'min_qty': '起订量',
  'quoted_on': '报价日期',
  'valid_until': '有效期至',
  'lead_time_days': '交期',
  'status': '状态',
  'customer': '客户',
  'leader': '负责人',
  'contract_no': '合同号',
  'merged_into': '合并去向',
};

String money(String? decimal, {String prefix = ''}) {
  if (decimal == null) return '—';
  final negative = decimal.startsWith('-');
  final parts = (negative ? decimal.substring(1) : decimal).split('.');
  final grouped = parts.first.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  final fraction = (parts.length > 1 ? parts[1] : '').padRight(2, '0');
  return '${negative ? '-' : ''}$prefix$grouped.$fraction';
}

/// Quantities keep their exact digits but lose the forced ".00".
String qty(String decimal) {
  final parts = decimal.split('.');
  final grouped = parts.first.replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return parts.length > 1 ? '$grouped.${parts[1]}' : grouped;
}

/// Whole-yuan summary figure for ledger strips (rounded half-up).
String yuan(String decimal) {
  final negative = decimal.startsWith('-');
  final parts = (negative ? decimal.substring(1) : decimal).split('.');
  var whole = BigInt.parse(parts.first);
  if (parts.length > 1 && int.parse(parts[1][0]) >= 5) whole += BigInt.one;
  return money('${negative ? '-' : ''}$whole', prefix: '¥').split('.').first;
}

/// Percentage with one decimal from two exact decimals; null when base is 0.
String? percent(String part, String whole) {
  BigInt micros(String d) {
    final negative = d.startsWith('-');
    final p = (negative ? d.substring(1) : d).split('.');
    final v =
        BigInt.parse(p.first) * BigInt.from(1000000) +
        BigInt.parse((p.length > 1 ? p[1] : '').padRight(6, '0'));
    return negative ? -v : v;
  }

  final base = micros(whole);
  if (base == BigInt.zero) return null;
  final tenths =
      (micros(part) * BigInt.from(1000) + base ~/ BigInt.two) ~/ base;
  final sign = tenths.isNegative ? '-' : '';
  final abs = tenths.abs();
  return '$sign${abs ~/ BigInt.from(10)}.${abs % BigInt.from(10)}%';
}

const statusLabels = {
  'planning': '策划中',
  'active': '进行中',
  'done': '已完成',
  'cancelled': '已取消',
};
