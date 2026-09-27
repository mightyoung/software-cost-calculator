import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_dup'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('keys ignore spacing, punctuation, width, case and company suffix', () {
    expect(normalizeKey(' CR 10－5 '), 'cr105');
    expect(normalizeKey('Z41H-16C DN100'), 'z41h16cdn100');
    expect(companyKey('上海甲泵业有限公司'), '上海甲泵业');
    expect(companyKey('永泰阀门（集团）股份有限公司'), '永泰阀门');
    expect(companyKey('公司'), '公司', reason: 'never strips to nothing');
  });

  test('similar suppliers: same by name or alias, possible by containment', () {
    final s = device('A');
    final yt = s.save('supplier', supplier('永泰阀门'));
    final jia = s.save('supplier', {
      ...supplier('甲泵业'),
      'aliases': ['上海甲泵'],
    });
    s.save('supplier', supplier('乙机电'));

    Map<String, Similarity> of(String name, {String? excludeId}) => {
      for (final d in s.similarSuppliers(name, excludeId: excludeId))
        d.hit.id: d.level,
    };
    expect(of('永泰阀门有限公司'), {yt: Similarity.same});
    expect(of('上海甲泵有限公司'), {jia: Similarity.same});
    expect(of('甲泵'), {jia: Similarity.possible});
    expect(of('丙电缆'), isEmpty);
    expect(of('永泰阀门', excludeId: yt), isEmpty);
  });

  test('similar products: same model is the same material', () {
    final s = device('A');
    final cr = s.save('product', {
      ...product('立式多级泵'),
      'brand': '格兰富',
      'model': 'CR10-5',
    });
    final valve = s.save('product', {
      ...product('闸阀'),
      'specification': 'DN100 PN16',
    });
    Map<String, Similarity> of(Map<String, Object?> p) => {
      for (final d in s.similarProducts(p)) d.hit.id: d.level,
    };
    expect(of({'name': '多级泵', 'brand': '格兰富', 'model': 'cr 10-5'}), {
      cr: Similarity.same,
    });
    expect(of({'name': '多级泵', 'brand': '威乐', 'model': 'CR10-5'}), {
      cr: Similarity.possible,
    }, reason: 'same model, different brand');
    expect(of({'name': '闸阀', 'specification': 'DN100  PN16'}), {
      valve: Similarity.same,
    });
    expect(of({'name': '闸阀', 'specification': 'DN150'}), {
      valve: Similarity.possible,
    });
    expect(of({'name': '蝶阀'}), isEmpty);
  });
}
