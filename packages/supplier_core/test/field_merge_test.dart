import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

/// Two devices that both hold supplier [id] as created on A.
(Store, Store, String) pair() {
  final a = device('A');
  final id = a.save('supplier', supplier('甲'));
  final b = device('B', start: DateTime.utc(2026, 9, 2));
  b.importFrom(exported(a));
  return (a, b, id);
}

void sync(Store a, Store b) {
  a.importFrom(exported(b));
  b.importFrom(exported(a));
}

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_fields'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('edits to different fields on two devices are both kept', () {
    final (a, b, id) = pair();
    a.save('supplier', {...supplier('甲'), 'address': '上海'}, id: id);
    b.save('supplier', {...supplier('甲'), 'notes': '常用'}, id: id);
    sync(a, b);
    for (final s in [a, b]) {
      expect(s.get('supplier', id)!.data['address'], '上海');
      expect(s.get('supplier', id)!.data['notes'], '常用');
      expect(s.openConflicts(), isEmpty);
    }
    expect(content(a), content(b));
  });

  test(
    'the later edit of a field wins, however often the other side saved',
    () {
      final (a, b, id) = pair();
      a.save('supplier', {...supplier('甲'), 'notes': 'A1'}, id: id);
      a.save('supplier', {...supplier('甲'), 'notes': 'A2'}, id: id);
      b.save('supplier', {...supplier('甲'), 'notes': 'B'}, id: id); // later
      sync(a, b);
      expect(a.get('supplier', id)!.data['notes'], 'B');
      expect(content(a), content(b));
    },
  );

  test('concurrent edits of one field become a conflict to resolve', () {
    final (a, b, id) = pair();
    a.save('supplier', {...supplier('甲'), 'address': '上海'}, id: id);
    b.save('supplier', {...supplier('甲'), 'address': '苏州'}, id: id);
    sync(a, b);
    expect(a.get('supplier', id)!.data['address'], '苏州');
    final conflict = a.openConflicts().single;
    expect(conflict.entityId, id);
    expect(conflict.field, 'address');
    expect({conflict.first.value, conflict.second.value}, {'上海', '苏州'});
    expect(b.openConflicts(), hasLength(1));

    a.resolveConflict(conflict, '上海');
    expect(a.get('supplier', id)!.data['address'], '上海');
    expect(a.openConflicts(), isEmpty);
    sync(a, b);
    expect(b.get('supplier', id)!.data['address'], '上海');
    expect(b.openConflicts(), isEmpty, reason: 'settled for everyone');
  });

  test('edits passed along a chain of devices are not conflicts', () {
    final (a, b, id) = pair();
    final c = device('C', start: DateTime.utc(2026, 9, 3));
    c.importFrom(exported(a));
    a.save('supplier', {...supplier('甲'), 'notes': '1'}, id: id);
    b.importFrom(exported(a));
    b.save('supplier', {...supplier('甲'), 'notes': '2'}, id: id);
    c.importFrom(exported(b));
    expect(c.get('supplier', id)!.data['notes'], '2');
    expect(c.openConflicts(), isEmpty);
  });

  test('a merge that breaks a rule keeps the whole winning record', () {
    final a = device('A');
    final sup = a.save('supplier', supplier('甲'));
    final prod = a.save('product', product('泵'));
    final pro = a.save('project', project('P1'));
    final q = a.save(
      'quotation',
      quotation(sup, prod, pro, '1', validUntil: '2026-12-31'),
    );
    final b = device('B', start: DateTime.utc(2026, 9, 2));
    b.importFrom(exported(a));
    final base = a.get('quotation', q)!.data;
    a.save('quotation', {...base, 'quoted_on': '2026-11-01'}, id: q);
    b.save('quotation', {...base, 'valid_until': '2026-10-01'}, id: q);
    sync(a, b);
    a.importFrom(exported(b));
    expect(content(a), content(b));
    final merged = a.get('quotation', q)!.data;
    expect(
      (merged['valid_until']! as String).compareTo(
            merged['quoted_on']! as String,
          ) >=
          0,
      isTrue,
    );
  });

  test('a delete wins over a concurrent edit', () {
    final (a, b, id) = pair();
    a.delete('supplier', id);
    b.save('supplier', {...supplier('甲'), 'notes': '还在用'}, id: id);
    sync(a, b);
    expect(a.get('supplier', id)!.deleted, isTrue);
    expect(b.get('supplier', id)!.deleted, isTrue);
    expect(content(a), content(b));
  });
}
