import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_basis'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('budget or contract prevents relabeling project money', () {
    final s = device('A');
    addTearDown(s.close);
    final p = s.save('project', project('P'));
    s.save('project_item', item(p, 'labor', name: '安装', cost: '10'));
    expect(
      () => s.save('project', {
        ...s.get('project', p)!.data,
        'currency': 'USD',
      }, id: p),
      throwsFormatException,
    );
    expect(
      () => s.save('project', {
        ...s.get('project', p)!.data,
        'tax_mode': 'excluded',
      }, id: p),
      throwsFormatException,
    );
    expect(s.get('project', p)!.data['currency'], 'CNY');
    final contracted = s.save('project', project('C', contract: '100'));
    expect(
      () => s.save('project', {
        ...s.get('project', contracted)!.data,
        'currency': 'USD',
      }, id: contracted),
      throwsFormatException,
    );
    final empty = s.save('project', project('E'));
    s.save('project', {
      ...s.get('project', empty)!.data,
      'currency': 'USD',
    }, id: empty);
    expect(s.get('project', empty)!.data['currency'], 'USD');
  });

  test('concurrent project basis change and old-basis line rolls back', () {
    final a = device('A');
    final p = a.save('project', project('P'));
    final b = device('B', start: DateTime.utc(2026, 9, 2));
    addTearDown(a.close);
    addTearDown(b.close);
    b.importFrom(exported(a));
    a.save('project', {...a.get('project', p)!.data, 'currency': 'USD'}, id: p);
    b.save('project_item', item(p, 'labor', name: '安装', cost: '10'));
    final beforeA = content(a);
    final beforeB = content(b);
    expect(() => a.importFrom(exported(b)), throwsFormatException);
    expect(() => b.importFrom(exported(a)), throwsFormatException);
    expect(content(a), beforeA);
    expect(content(b), beforeB);
  });

  test('new-basis lines merge with unrelated project edits', () {
    final a = device('A');
    final p = a.save('project', project('P'));
    final b = device('B', start: DateTime.utc(2026, 9, 2));
    addTearDown(a.close);
    addTearDown(b.close);
    b.importFrom(exported(a));
    a.save('project', {...a.get('project', p)!.data, 'currency': 'USD'}, id: p);
    a.save('project_item', item(p, 'labor', name: '安装', cost: '10'));
    b.save('project', {...b.get('project', p)!.data, 'notes': '现场项目'}, id: p);
    a.importFrom(exported(b));
    b.importFrom(exported(a));
    expect(a.get('project', p)!.data['currency'], 'USD');
    expect(b.get('project', p)!.data['currency'], 'USD');
    expect(b.get('project', p)!.data['notes'], '现场项目');
    expect(b.budget(p).cost, '10');
  });

  test('deleting old budget before changing basis synchronizes cleanly', () {
    final a = device('A');
    final p = a.save('project', project('P'));
    final line = a.save(
      'project_item',
      item(p, 'labor', name: '安装', cost: '10'),
    );
    final b = device('B', start: DateTime.utc(2026, 9, 2));
    addTearDown(a.close);
    addTearDown(b.close);
    b.importFrom(exported(a));
    a.delete('project_item', line);
    a.save('project', {...a.get('project', p)!.data, 'currency': 'USD'}, id: p);
    b.importFrom(exported(a));
    expect(b.get('project', p)!.data['currency'], 'USD');
    expect(b.get('project_item', line)!.deleted, isTrue);
    a.importFrom(exported(b));
    expect(content(a), content(b));
  });
}
