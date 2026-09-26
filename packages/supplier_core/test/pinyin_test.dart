import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_pinyin'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('pinyin initials find Chinese names', () {
    expect(pinyinInitials('离心泵'), 'lxb');
    expect(pinyinInitials('甲泵业 IS80'), 'jbyis80');
    final s = device('A');
    final pump = s.save('product', product('离心泵'));
    s.save('product', product('闸阀'));
    final jia = s.save('supplier', {
      ...supplier('上海甲泵业有限公司'),
      'aliases': ['甲泵'],
    });
    expect(s.searchProducts(['lxb']).map((h) => h.id), [pump]);
    expect(s.searchProducts(['LXB']).map((h) => h.id), [pump]);
    expect(s.searchByName('supplier', 'jby').map((h) => h.id), [jia]);
    expect(s.searchByName('supplier', 'jb').map((h) => h.id), [jia]);
    // Renaming refreshes the cached initials.
    s.save('product', {...product('多级泵')}, id: pump);
    expect(s.searchProducts(['lxb']), isEmpty);
    expect(s.searchProducts(['djb']).map((h) => h.id), [pump]);
  });
}
