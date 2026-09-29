import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late File notice;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('notice-security-');
    notice = File('${dir.path}/版本.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('bounds actual notice bytes before JSON decoding', () {
    const json = '{"version":"1.0.12","notes":"中文","file":"安装包.zip"}';
    final bytes = utf8.encode(json);
    notice.writeAsBytesSync([
      ...bytes,
      ...List.filled(65536 - bytes.length, 32),
    ]);
    final valid = readUpdate(dir.path, current: '1.0.5')!;
    expect(
      (valid.version, valid.notes, valid.file),
      ('1.0.12', '中文', '安装包.zip'),
    );
    notice.writeAsStringSync(' ', mode: FileMode.append);
    expect(readUpdate(dir.path, current: '1.0.5'), isNull);
  });

  test('rejects oversized display fields and excessive version segments', () {
    for (final payload in [
      {'version': '2.0', 'notes': 'x' * 8193},
      {'version': '2.0', 'file': 'x' * 1025},
      {'version': '2.${'0.' * 64}1'},
      {'version': '2.${'1' * 128}'},
    ]) {
      notice.writeAsStringSync(jsonEncode(payload));
      expect(
        readUpdate(dir.path, current: '1.0'),
        isNull,
        reason: payload.keys.toString(),
      );
    }
  });

  test('malformed UTF-8, JSON and field types remain harmless', () {
    for (final bytes in [
      [0xff],
      utf8.encode('{'),
      utf8.encode('[]'),
      utf8.encode('{"version":2}'),
      utf8.encode('{"version":"2.0","notes":[]}'),
      utf8.encode('{"version":"2.0","file":{}}'),
    ]) {
      notice.writeAsBytesSync(bytes);
      expect(readUpdate(dir.path, current: '1.0'), isNull);
    }
  });

  test('optional fields, prerelease notation and numeric ordering remain', () {
    notice.writeAsStringSync('{"version":"1.0.12-beta+2"}');
    expect(readUpdate(dir.path, current: '1.0.5')!.notes, isNull);
    expect(readUpdate(dir.path, current: '1.0.5')!.file, isNull);
    expect(readUpdate(dir.path, current: '1.1.0'), isNull);
    expect(readUpdate('${dir.path}/absent', current: '1.0'), isNull);
  });
}
