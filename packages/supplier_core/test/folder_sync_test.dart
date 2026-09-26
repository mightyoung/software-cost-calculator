import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_folder'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('devices converge through a shared folder, importing only changes', () {
    final dir = Directory('${tmp.path}/shared')..createSync();
    final a = device('A'), b = device('B'), c = device('C');
    final seen = {
      'A': <String, String>{},
      'B': <String, String>{},
      'C': <String, String>{},
    };
    FolderSync sync(Store s, String name) {
      final r = s.syncWithFolder(
        dir.path,
        ownName: '$name.siq',
        seen: seen[name]!,
      );
      seen[name] = r.seen;
      return r;
    }

    final sa = a.save('supplier', supplier('甲'));
    expect(sync(a, 'A').imported, isEmpty);
    b.save('supplier', supplier('乙'));
    expect(sync(b, 'B').imported, ['A.siq']);
    // C hears about A's supplier through B's file alone.
    c.importFrom(exported(c)); // no-op; C starts empty
    expect(sync(c, 'C').imported, containsAll(['A.siq', 'B.siq']));
    expect(c.get('supplier', sa), isNotNull);

    expect(sync(a, 'A').imported, containsAll(['B.siq', 'C.siq']));
    final before = File('${dir.path}/A.siq').lastModifiedSync();
    expect(sync(a, 'A').imported, isEmpty, reason: 'nothing changed');
    expect(
      File('${dir.path}/A.siq').lastModifiedSync(),
      before,
      reason: 'unchanged data is not rewritten',
    );
    sync(b, 'B');
    sync(c, 'C');
    expect(content(a), content(b));
    expect(content(b), content(c));

    File('${dir.path}/broken.siq').writeAsBytesSync([1, 2, 3]);
    final r = sync(a, 'A');
    expect(r.failed.keys, ['broken.siq']);
    expect(r.seen.containsKey('broken.siq'), isFalse, reason: 'retried later');
  });

  test('update notice from the shared folder', () {
    final dir = Directory('${tmp.path}/shared')..createSync();
    expect(readUpdate(dir.path, current: '1.0.5'), isNull);
    File('${dir.path}/版本.json').writeAsStringSync(
      '{"version": "1.0.12", "notes": "新增询价单", "file": "询价台账-1.0.12.zip"}',
    );
    final u = readUpdate(dir.path, current: '1.0.5')!;
    expect(
      (u.version, u.notes, u.file),
      ('1.0.12', '新增询价单', '询价台账-1.0.12.zip'),
    );
    expect(readUpdate(dir.path, current: '1.0.12'), isNull);
    expect(readUpdate(dir.path, current: '1.1.0'), isNull);
    File('${dir.path}/版本.json').writeAsStringSync('not json');
    expect(readUpdate(dir.path, current: '1.0.5'), isNull);
  });
}
