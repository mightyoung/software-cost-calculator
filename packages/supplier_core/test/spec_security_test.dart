import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('spec_security'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('rejects malformed explosion-protection types at domain boundary', () {
    final p = specProperty('prot.ex')!;
    for (final types in [
      <Object?>[''],
      [1],
      ['unknown'],
      'db',
    ]) {
      expect(
        () => normalizeParamValue(p, {
          'marks': [
            {'types': types, 'group': 'IIC', 'temp': 'T4', 'epl': 'Gb'},
          ],
        }),
        throwsFormatException,
        reason: '$types',
      );
    }
    for (final text in ['Ex db IIC T4 Gb', 'Ex IIC T4 Gb']) {
      final raw = parseParamText(p, text)!;
      expect(normalizeParamValue(p, raw), raw);
    }
  });

  test(
    'malicious chosen snapshot rolls back import and leaves exports usable',
    () {
      final source = device('source');
      final request = source.createSpecRequest('要求', [draftItem('设备', '原厂证明')]);
      final item = source.specItemsOf(request).single;
      final path = exported(source);
      final file = sqlite3.open(path);
      final data = Map<String, Object?>.from(item.data);
      data['chosen_snapshot'] = {
        'rows': [
          {'n': 1, 'outcome': 'bogus'},
        ],
      };
      file.execute('UPDATE spec_item SET data=? WHERE id=?', [
        jsonEncode(data),
        item.id,
      ]);
      file.close();
      final target = device('target');
      expect(() => target.importFrom(path), throwsFormatException);
      expect(target.get('spec_request', request), isNull);
      expect(source.deviationXlsx(request), isNotEmpty);
    },
  );

  test('valid chosen snapshots keep manual responses through exchange', () {
    final source = device('source');
    final material = source.save('product', product('设备'));
    final request = source.createSpecRequest('要求', [draftItem('设备', '原厂证明')]);
    final item = source.specItemsOf(request).single;
    source.chooseProduct(item.id, material);
    source.setClauseResponse(item.id, 1, '可提供原厂证明', Outcome.exact);
    final target = device('target');
    target.importFrom(exported(source));
    expect(
      deviationTable(target, request).rows,
      deviationTable(source, request).rows,
    );
    expect(
      deviationTable(target, request).headings,
      deviationTable(source, request).headings,
    );
    expect(target.deviationXlsx(request), isNotEmpty);
  });
}
