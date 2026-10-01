import 'dart:convert';

import 'package:cryptography/dart.dart';

const _jsonMarker = '\n[Folio JSON-LD declaration]\n';
const _factKeys = {
  'name',
  'brand',
  'model',
  'supplier',
  'price',
  'currency',
  'unit',
  'tax_mode',
  'tax_rate',
  'min_qty',
  'quoted_on',
  'valid_until',
  'shipping',
  'configuration',
  'manufacture_country',
  'brand_origin',
};

/// Host-created source facts. This does not attest to the website's accuracy.
class AssistantWebProduct {
  AssistantWebProduct({
    required this.id,
    required Map<String, String> facts,
    Map<String, String> parameters = const {},
    Map<String, String> evidence = const {},
    List<String> warnings = const [],
  }) : facts = Map.unmodifiable(facts),
       parameters = Map.unmodifiable(parameters),
       evidence = Map.unmodifiable(evidence),
       warnings = List.unmodifiable(warnings) {
    if (id.isEmpty ||
        id.length > 100 ||
        facts.length > 18 ||
        facts.keys.any((key) => !_factKeys.contains(key)) ||
        parameters.length > 24 ||
        evidence.length > 42 ||
        warnings.length > 16)
      throw const FormatException('Invalid product bounds');
    for (final map in [facts, parameters, evidence]) {
      for (final entry in map.entries) {
        if (entry.key.isEmpty ||
            entry.key.length > 100 ||
            entry.value.isEmpty ||
            entry.value.length > (identical(map, evidence) ? 1000 : 500)) {
          throw const FormatException('Invalid product field bounds');
        }
      }
    }
    if (warnings.any((w) => w.length > 200))
      throw const FormatException('Invalid warning');
  }
  final String id;
  final Map<String, String> facts, parameters, evidence;
  final List<String> warnings;
  Map<String, Object?> toJson() => {
    'id': id,
    'facts': facts,
    'parameters': parameters,
    'evidence': evidence,
    'warnings': warnings,
  };
}

/// Immutable, bounded capture. Restoration re-extracts facts rather than trusting
/// serialized product fields. A digest detects corruption, not malicious websites.
class AssistantWebSnapshot {
  AssistantWebSnapshot._(
    this.id,
    this.url,
    this.title,
    this.fetchedAt,
    this.text,
    this.truncated,
    this.digest,
    List<String> jsonLd,
    List<AssistantWebProduct> products,
    this._legacy,
  ) : jsonLd = List.unmodifiable(jsonLd),
      products = List.unmodifiable(products);

  static const maxTextChars = 48000;
  final String id, url, title, fetchedAt, text, digest;
  final bool truncated;
  final List<String> jsonLd;
  final List<AssistantWebProduct> products;
  final bool _legacy;

  factory AssistantWebSnapshot.capture({
    required String url,
    required String title,
    required String fetchedAt,
    required String text,
    required bool truncated,
    List<String> jsonLd = const [],
  }) {
    // Retain complete declarations only: incomplete JSON cannot become facts.
    final body = text.length > 24000 ? text.substring(0, 24000) : text;
    final declarations = <String>[];
    var retainedChars = body.length;
    var omitted = truncated || text.length > 24000;
    for (final declaration in jsonLd.take(8)) {
      if (declaration.length > 16000 ||
          retainedChars + declaration.length > maxTextChars) {
        omitted = true;
        continue;
      }
      declarations.add(declaration);
      retainedChars += declaration.length;
    }
    if (jsonLd.length > 8) omitted = true;
    return _build(url, title, fetchedAt, body, omitted, declarations);
  }

  static AssistantWebSnapshot _build(
    String url,
    String title,
    String fetchedAt,
    String text,
    bool truncated,
    List<String> jsonLd, {
    bool legacy = false,
  }) {
    final uri = Uri.tryParse(url);
    if (url.length > 2048 ||
        uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.host.isEmpty ||
        uri.port != 443 ||
        title.length > 200 ||
        fetchedAt.length > 40 ||
        DateTime.tryParse(fetchedAt) == null ||
        text.length > maxTextChars)
      throw const FormatException('Invalid snapshot bounds');
    // Legacy mixed text cannot prove whether a marker came from the host or
    // the page. Marker-free legacy snapshots retain their original identities.
    if (jsonLd.length > 8 ||
        jsonLd.any((value) => value.length > 16000) ||
        text.length + jsonLd.fold<int>(0, (sum, value) => sum + value.length) >
            maxTextChars ||
        legacy && text.contains(_jsonMarker)) {
      throw const FormatException('Invalid or ambiguous snapshot declarations');
    }
    final products = _products(text, jsonLd, truncated);
    final payload = {
      'url': url,
      'title': title,
      'fetched_at': fetchedAt,
      'text': text,
      'truncated': truncated,
      if (!legacy) 'json_ld': jsonLd,
      'products': products.map((p) => p.toJson()).toList(),
    };
    final digest = _digest(payload);
    return AssistantWebSnapshot._(
      'web_$digest',
      url,
      title,
      fetchedAt,
      text,
      truncated,
      digest,
      jsonLd,
      products,
      legacy,
    );
  }

  factory AssistantWebSnapshot.fromJson(Map<String, Object?> json) {
    final legacy = !json.containsKey('json_ld');
    const keys = {
      'id',
      'url',
      'title',
      'fetched_at',
      'text',
      'truncated',
      'digest',
      'products',
      'json_ld',
    };
    if (json.length != keys.length - (legacy ? 1 : 0) ||
        json.keys.any((k) => !keys.contains(k)) ||
        json['truncated'] is! bool ||
        json['products'] is! List ||
        (json['products'] as List).length > 8)
      throw const FormatException('Invalid snapshot');
    String string(String key, int limit) {
      final value = json[key];
      if (value is! String || value.length > limit)
        throw FormatException('Invalid snapshot $key');
      return value;
    }

    final rawDeclarations = legacy ? const <String>[] : json['json_ld'];
    if (rawDeclarations is! List ||
        rawDeclarations.length > 8 ||
        rawDeclarations.any(
          (value) => value is! String || value.length > 16000,
        )) {
      throw const FormatException('Invalid snapshot declarations');
    }
    final result = _build(
      string('url', 2048),
      string('title', 200),
      string('fetched_at', 40),
      string('text', maxTextChars),
      json['truncated'] as bool,
      rawDeclarations.cast<String>(),
      legacy: legacy,
    );
    if (string('id', 100) != result.id ||
        string('digest', 64) != result.digest ||
        !_sameProducts(json['products'] as List, result.products)) {
      throw const FormatException(
        'Snapshot digest or extracted facts mismatch',
      );
    }
    return result;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'url': url,
    'title': title,
    'fetched_at': fetchedAt,
    'text': text,
    'truncated': truncated,
    if (!_legacy) 'json_ld': jsonLd,
    'digest': digest,
    'products': products.map((p) => p.toJson()).toList(),
  };
}

bool _sameProducts(List raw, List<AssistantWebProduct> expected) {
  if (raw.length != expected.length) return false;
  // Compare only the bounded expected structure: do not encode an arbitrary
  // restored object before validating its shape and leaf lengths.
  bool equal(Object? actual, Object? wanted) {
    if (wanted is Map) {
      if (actual is! Map || actual.length != wanted.length) return false;
      return wanted.entries.every(
        (e) => actual.containsKey(e.key) && equal(actual[e.key], e.value),
      );
    }
    if (wanted is List) {
      if (actual is! List || actual.length != wanted.length) return false;
      for (var i = 0; i < wanted.length; i++) {
        if (!equal(actual[i], wanted[i])) return false;
      }
      return true;
    }
    return actual is String &&
        wanted is String &&
        actual.length == wanted.length &&
        actual == wanted;
  }

  for (var i = 0; i < raw.length; i++) {
    if (!equal(raw[i], expected[i].toJson())) return false;
  }
  return true;
}

String _digest(Object value) => const DartSha256()
    .hashSync(utf8.encode(jsonEncode(value)))
    .bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join();

const _labels = <String, String>{
  '产品名称': 'name',
  '商品名称': 'name',
  '名称': 'name',
  'name': 'name',
  '品牌': 'brand',
  'brand': 'brand',
  '型号': 'model',
  'model': 'model',
  '供应商': 'supplier',
  'supplier': 'supplier',
  '单价': 'price',
  '报价': 'price',
  '价格': 'price',
  'price': 'price',
  '币种': 'currency',
  'currency': 'currency',
  '单位': 'unit',
  'unit': 'unit',
  '税制': 'tax_mode',
  '含税方式': 'tax_mode',
  'tax_mode': 'tax_mode',
  '税率': 'tax_rate',
  'tax_rate': 'tax_rate',
  '最小起订量': 'min_qty',
  '起订量': 'min_qty',
  'min_qty': 'min_qty',
  '报价日期': 'quoted_on',
  'quoted_on': 'quoted_on',
  '有效期至': 'valid_until',
  'valid_until': 'valid_until',
  '运费': 'shipping',
  'shipping': 'shipping',
  '配置': 'configuration',
  'configuration': 'configuration',
  '制造国': 'manufacture_country',
  '制造地': 'manufacture_country',
  'manufacture_country': 'manufacture_country',
  '品牌来源国': 'brand_origin',
  'brand_origin': 'brand_origin',
};
const _technical = {
  '功率',
  '电压',
  '电流',
  '频率',
  '流量',
  '扬程',
  '压力',
  '材质',
  '尺寸',
  '重量',
  '精度',
  '防护等级',
  '容量',
  '转速',
  '温度',
  '技术要求',
  'power',
  'voltage',
  'pressure',
  'material',
  'dimensions',
};

class _Row {
  final facts = <String, String>{},
      parameters = <String, String>{},
      evidence = <String, String>{};
  final conflicts = <String>{};
  final warnings = <String>[];
  void add(String key, Object? raw, String proof, {bool parameter = false}) {
    final value = _scalar(raw);
    final target = parameter ? parameters : facts;
    final evidenceKey = parameter ? 'parameter:$key' : key;
    if (value == null) {
      if (raw != null) {
        target.remove(key);
        evidence.remove(evidenceKey);
        conflicts.add(evidenceKey);
        if (warnings.length < 16) warnings.add('$key 声明无法完整识别，未采纳');
      }
      return;
    }
    if (conflicts.contains(evidenceKey)) return;
    if (target.containsKey(key) && target[key] != value) {
      target.remove(key);
      evidence.remove(evidenceKey);
      conflicts.add(evidenceKey);
      if (warnings.length < 16) warnings.add('$key 存在冲突，未采纳');
      return;
    }
    if (parameter && target.length >= 24 && !target.containsKey(key)) return;
    target[key] = value;
    evidence[evidenceKey] = proof.length > 1000
        ? proof.substring(0, 1000)
        : proof;
  }

  void noPrice(String warning) {
    facts.remove('price');
    evidence.remove('price');
    conflicts.add('price');
    if (warnings.length < 16 && !warnings.contains(warning))
      warnings.add(warning);
  }

  AssistantWebProduct? finish() {
    if (!facts.containsKey('name') || conflicts.contains('name')) return null;
    final model = facts['model'];
    if (conflicts.contains('model') ||
        model != null &&
            RegExp(
              r'[,，、/;；或和及与]|\b(?:or|and)\b',
              caseSensitive: false,
            ).hasMatch(model)) {
      noPrice('多个型号或型号冲突，价格无法绑定到单一产品');
    }
    final price = facts['price'];
    if (price != null &&
        (!RegExp(
              r'^(?:0|[1-9][0-9]{0,14})(?:\.[0-9]{1,6})?$',
            ).hasMatch(price) ||
            (num.tryParse(price) ?? 0) <= 0))
      noPrice('价格不是明确的单一正数，需人工核验');
    if (!facts.containsKey('model') && warnings.length < 16)
      warnings.add('来源未明确型号');
    return AssistantWebProduct(
      id: 'product_${_digest({'facts': facts, 'parameters': parameters, 'evidence': evidence})}',
      facts: facts,
      parameters: parameters,
      evidence: evidence,
      warnings: warnings,
    );
  }
}

String? _scalar(Object? value) {
  if (value is! String && value is! num) return null;
  final text = value.toString().trim();
  return text.isEmpty || text.length > 500 ? null : text;
}

String? _named(Object? value) =>
    value is Map ? _scalar(value['name']) : _scalar(value);
bool _type(Map value, String type) =>
    value['@type'] == type ||
    value['@type'] is List && (value['@type'] as List).contains(type);

List<AssistantWebProduct> _products(
  String text,
  List<String> jsonLd,
  bool truncated,
) {
  final found = <AssistantWebProduct>[];
  for (final raw in jsonLd) {
    if (raw.length > 16000 || !_safeJson(raw)) continue;
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      continue;
    }
    final queue = <Object?>[decoded];
    for (var i = 0; i < queue.length && i < 256 && found.length < 8; i++) {
      final node = queue[i];
      if (node is List) {
        queue.addAll(node.take(64));
        continue;
      }
      if (node is! Map) continue;
      if (node['@graph'] is List)
        queue.addAll((node['@graph'] as List).take(64));
      if (!_type(node, 'Product')) continue;
      final row = _Row();
      for (final key in ['name', 'model']) {
        row.add(
          key,
          node[key],
          'JSON-LD Product.$key = ${jsonEncode(node[key])}',
        );
      }
      row.add(
        'brand',
        _named(node['brand']),
        'JSON-LD Product.brand = ${jsonEncode(node['brand'])}',
      );
      row.add(
        'manufacture_country',
        _named(node['countryOfOrigin']),
        'JSON-LD Product.countryOfOrigin = ${jsonEncode(node['countryOfOrigin'])}',
      );
      final additional = node['additionalProperty'];
      for (final property in additional is List ? additional : [additional]) {
        if (property is! Map || !_type(property, 'PropertyValue')) continue;
        final label = _scalar(property['name']);
        if (label == null || label.length > 80) continue;
        final key = _labels[label.toLowerCase()];
        row.add(
          key ?? label,
          property['value'],
          'JSON-LD Product.additionalProperty ${jsonEncode(property)}',
          parameter: key == null,
        );
      }
      final offers = node['offers'];
      final offerEntries = offers is List ? offers : [offers];
      var invalidOffer = offerEntries.length != 1;
      var offerCount = 0;
      for (final offer in offerEntries.take(16)) {
        if (offer == null) {
          invalidOffer = true;
          continue;
        }
        offerCount++;
        if (offer is! Map ||
            !_type(offer, 'Offer') ||
            offer.containsKey('lowPrice') ||
            offer.containsKey('highPrice')) {
          invalidOffer = true;
          continue;
        }
        // Product.additionalProperty must never supply a missing Offer price.
        // Even an otherwise identifiable Offer needs its own scalar quote.
        if (_scalar(offer['price']) == null) invalidOffer = true;
        final offered = offer['itemOffered'];
        if (offered != null &&
            (offered is! Map ||
                offered['model'] != node['model'] ||
                offered['name'] != node['name']))
          invalidOffer = true;
        final description =
            '${offer['description'] ?? ''} ${node['description'] ?? ''}';
        if (_uncertainPrice(description) ||
            offer.containsKey('priceSpecification'))
          invalidOffer = true;
        for (final entry in {
          'price': 'price',
          'priceCurrency': 'currency',
          'priceValidUntil': 'valid_until',
          'validFrom': 'quoted_on',
        }.entries) {
          row.add(
            entry.value,
            offer[entry.key],
            'JSON-LD Product.offers.${entry.key} = ${jsonEncode(offer[entry.key])}',
          );
        }
        row.add(
          'supplier',
          _named(offer['seller']),
          'JSON-LD Product.offers.seller = ${jsonEncode(offer['seller'])}',
        );
      }
      if (offerCount != 1)
        invalidOffer =
            true; // Never blend commercial terms across sellers/offers.
      if (invalidOffer) row.noPrice('报价缺少唯一 Offer 自身的明确价格，或为区间、起价及绑定不明确，需人工核验');
      if (_uncertainPrice(text)) row.noPrice('来源说明包含总价、非单价或不确定报价，需人工核验');
      if (truncated) row.noPrice('来源内容不完整，无法排除遗漏的报价条件或冲突');
      final product = row.finish();
      if (product != null) found.add(product);
    }
  }
  if (found.isNotEmpty) return found;
  final row = _Row();
  var nameCount = 0;
  final lines = text.split('\n');
  // A capture limit must never turn a partially retained number into a price.
  if (truncated && lines.isNotEmpty) lines.removeLast();
  for (final line in lines) {
    final separator = line.indexOf(RegExp(r'[:：]'));
    if (separator < 1 || separator > 80) continue;
    final label = line.substring(0, separator).trim().toLowerCase();
    final value = line.substring(separator + 1).trim();
    final key = _labels[label];
    if (key == 'name') nameCount++;
    if (key != null) {
      row.add(key, value, line.trim());
    } else if (_technical.contains(label)) {
      row.add(label, value, line.trim(), parameter: true);
    }
  }
  if (nameCount != 1)
    return const []; // Explicitly single-product records only.
  if (_uncertainPrice(text)) row.noPrice('来源说明包含总价、非单价或不确定报价，需人工核验');
  if (truncated) row.noPrice('来源内容不完整，无法排除遗漏的报价条件或冲突');
  final product = row.finish();
  return product == null ? const [] : [product];
}

bool _uncertainPrice(String context) => RegExp(
  r'总价|总额|合计|非单价|不是单价|整套|整批|打包|起价|起步|起售|面议|区间价|'
  r'\b(?:starting|total|subtotal|lump\s+sum|negotiable|range)\b|from\s',
  caseSensitive: false,
).hasMatch(context);

/// Bounded depth and duplicate-key rejection before JSON decoding. Scans each
/// string once; arbitrary nested declarations cannot exhaust parser recursion.
bool _safeJson(String raw) {
  final objects = <Set<String>?>[];
  for (var i = 0; i < raw.length; i++) {
    final code = raw.codeUnitAt(i);
    if (code == 123 || code == 91) {
      objects.add(code == 123 ? <String>{} : null);
      if (objects.length > 32) return false;
    } else if (code == 125 || code == 93) {
      if (objects.isEmpty) return false;
      objects.removeLast();
    } else if (code == 34) {
      final start = i++;
      while (i < raw.length && raw.codeUnitAt(i) != 34) {
        if (raw.codeUnitAt(i) == 92) i++;
        i++;
      }
      if (i >= raw.length) return false;
      var next = i + 1;
      while (next < raw.length && raw.codeUnitAt(next) <= 32) {
        next++;
      }
      if (next < raw.length &&
          raw.codeUnitAt(next) == 58 &&
          objects.isNotEmpty &&
          objects.last != null) {
        try {
          final key = jsonDecode(raw.substring(start, i + 1)) as String;
          if (!objects.last!.add(key)) return false;
        } on FormatException {
          return false;
        }
      }
    }
  }
  return objects.isEmpty;
}
