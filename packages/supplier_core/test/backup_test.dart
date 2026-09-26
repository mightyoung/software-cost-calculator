import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_backup'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('one snapshot per day, newest seven kept, each restorable', () {
    final a = device('A');
    a.save('supplier', supplier('甲'));
    final dir = '${tmp.path}/backups';
    final first = a.dailyBackup(dir, now: DateTime(2026, 9, 1));
    expect(first, endsWith('2026-09-01.siq'));
    expect(a.dailyBackup(dir, now: DateTime(2026, 9, 1, 18)), isNull);
    for (var d = 2; d <= 10; d++) {
      a.dailyBackup(dir, now: DateTime(2026, 9, d));
    }
    final names = Directory(
      dir,
    ).listSync().map((f) => f.uri.pathSegments.last).toList()..sort();
    expect(names, hasLength(7));
    expect(names.first, contains('2026-09-04'));
    expect(names.last, contains('2026-09-10'));

    final restored = device('R');
    restored.importFrom('$dir/${names.last}');
    expect(content(restored), content(a));
  });
}
