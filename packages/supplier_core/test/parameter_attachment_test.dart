import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(
    () => tmp = Directory.systemTemp.createTempSync('parameter_attachment'),
  );
  tearDown(() => tmp.deleteSync(recursive: true));

  test('saving a parameter rejects a missing source attachment atomically', () {
    final s = device('A');
    addTearDown(s.close);
    final prod = s.save('product', product('工控机'));
    final before = content(s);
    expect(
      () => s.setParam(prod, 'cpu.cores', {'v': '8'}, attachmentId: newUuid()),
      throwsFormatException,
    );
    expect(content(s), before);
  });

  test(
    'parameters accept existing source attachments and optional sources',
    () {
      final s = device('A');
      addTearDown(s.close);
      final prod = s.save('product', product('工控机'));
      final att = s.addAttachment('规格.txt', utf8.encode('八核'));
      final id = s.setParam(prod, 'cpu.cores', {'v': '8'}, attachmentId: att);
      expect(s.get('product_param', id)!.data['attachment_id'], att);
      final before = content(s);
      expect(
        () =>
            s.setParam(prod, 'cpu.cores', {'v': '16'}, attachmentId: newUuid()),
        throwsFormatException,
      );
      expect(content(s), before);
      s.setParam(prod, 'cpu.cores', {'v': '8'});
      expect(s.get('product_param', id)!.data['attachment_id'], isNull);
    },
  );

  test('exchange rejects missing parameter attachments and rolls back', () {
    final a = device('A');
    final b = device('B');
    addTearDown(a.close);
    addTearDown(b.close);
    final prod = a.save('product', product('工控机'));
    final att = a.addAttachment('规格.txt', utf8.encode('八核'));
    a.setParam(prod, 'cpu.cores', {'v': '8'}, attachmentId: att);
    a.addAttachment('其他.txt', utf8.encode('其他附件'));
    final path = exported(a);
    final db = sqlite3.open(path);
    db.execute('DELETE FROM attachment WHERE id=?', [att]);
    db.close();
    b.save('supplier', supplier('本地供应商'));
    final before = content(b);
    expect(() => b.importFrom(path), throwsFormatException);
    expect(content(b), before);
    expect(b.db.select('SELECT id FROM attachment'), isEmpty);
  });

  test('complete exchange preserves parameter evidence and is idempotent', () {
    final a = device('A');
    final b = device('B');
    addTearDown(a.close);
    addTearDown(b.close);
    final prod = a.save('product', product('工控机'));
    final att = a.addAttachment('规格.txt', utf8.encode('八核'));
    final id = a.setParam(prod, 'cpu.cores', {'v': '8'}, attachmentId: att);
    final path = exported(a);
    b.importFrom(path);
    expect(b.get('product_param', id)!.data['attachment_id'], att);
    expect(utf8.decode(b.attachment(att)!.bytes!), '八核');
    final before = content(b);
    b.importFrom(path);
    expect(content(b), before);
  });
}
