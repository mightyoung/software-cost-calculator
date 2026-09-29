/// Cable parameters decoded from a model code (design §9.2): flame and fire
/// prefixes after GB/T 19666, series and material letters after GB/T 9330
/// (control), GB/T 5023 (flexible) and GB/T 12706 (power), then cores ×
/// cross-section. "ZR-KVVP-4×1.5" → 阻燃, 控制电缆, 铜芯, V/V, 编织屏蔽,
/// 4 芯, 1.5 mm². Empty when the code does not read as a cable model.
Map<String, Map<String, Object?>> decodeCableModel(String model) {
  final t = model
      .toUpperCase()
      .replaceAll(RegExp(r'[＊*xX×]'), '×')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final m = RegExp(
    r'^(WDZ[ABC]?N?|Z[ABC]N?|ZR|NH|N)?-?'
    r'(DJ|K|R)?'
    r'(L)?'
    r'(YJ|V|Y|X|F)'
    r'(L)?' // YJLV: aluminium written after the insulation
    r'(YJ|V|Y|X|F)?'
    r'(P2|P3|P|R)?'
    r'(?:\d{2})?'
    r'(?:[- ]+[\d.]+/[\d.]+\s*KV)?'
    r'[- ]+(\d{1,3})×([\d.]+)((?:\+\d{1,3}×[\d.]+)*)',
  ).firstMatch(t);
  if (m == null) return const {};
  final prefix = m[1] ?? '';
  final series = m[2];
  final flame = switch (prefix) {
    'ZR' || 'WDZ' || 'WDZN' => 'ZR',
    final p when p.contains('ZA') => 'ZA',
    final p when p.contains('ZB') => 'ZB',
    final p when p.contains('ZC') => 'ZC',
    _ => null,
  };
  var cores = int.parse(m[8]!);
  for (final extra in RegExp(r'\+(\d{1,3})×').allMatches(m[10]!)) {
    cores += int.parse(extra[1]!);
  }
  final shield = switch (m[7]) {
    'P' || 'P2' || 'P3' => m[7]!,
    _ => 'none',
  };
  return {
    'cable.use': {
      'v': switch (series) {
        'K' => 'control',
        'R' => 'flexible',
        'DJ' => 'computer',
        _ => 'power',
      },
    },
    'cable.conductor': {'v': m[3] == null && m[5] == null ? 'Cu' : 'Al'},
    'cable.insulation': {'v': m[4]!},
    if (m[6] != null) 'cable.sheath': {'v': m[6]!},
    'cable.shield': {'v': shield},
    'cable.flame': {'v': flame ?? 'none'},
    if (prefix.contains('N')) 'cable.fire_resistant': {'v': true},
    'cable.cores': {'v': '$cores'},
    'cable.csa': {'v': m[9]!, 'u': 'mm2'},
  };
}
