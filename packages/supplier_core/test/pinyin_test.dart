import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
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
    // Renaming refreshes the indexed initials.
    s.save('product', {...product('多级泵')}, id: pump);
    expect(s.searchProducts(['lxb']), isEmpty);
    expect(s.searchProducts(['djb']).map((h) => h.id), [pump]);
  });

  test('search index follows edits, deletes, merges and imports', () {
    final a = device('A'), b = device('B');
    List<String> find(Store s, String w) =>
        s.searchProducts([w]).map((h) => h.id).toList();
    final pump = a.save('product', product('立式多级离心泵'));
    final valve = a.save('product', product('闸阀'));
    expect(find(a, '泵'), [pump], reason: 'short terms scan the index');
    expect(find(a, '多级离心'), [pump], reason: 'long terms use trigrams');
    a.save('product', product('卧式离心泵'), id: pump);
    expect(find(a, '多级离心'), isEmpty);
    expect(find(a, '卧式离心'), [pump]);
    a.delete('product', valve);
    expect(find(a, '闸阀'), isEmpty);
    final dup = a.save('product', product('卧式离心泵机组'));
    a.mergeInto('product', dup, pump);
    expect(find(a, '卧式离心'), [pump], reason: 'merged rows leave the index');

    a.exportTo('${tmp.path}/a.siq');
    final file = sqlite3.open('${tmp.path}/a.siq');
    expect(
      file.select("SELECT name FROM sqlite_master WHERE name LIKE '%search%'"),
      isEmpty,
      reason: 'exchange files carry data only',
    );
    file.close();
    b.importFrom('${tmp.path}/a.siq');
    expect(find(b, '卧式离心'), [pump]);
    expect(b.searchByName('product', 'wslxb').map((h) => h.id), [pump]);
  });
}
