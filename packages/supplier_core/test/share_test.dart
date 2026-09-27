import 'dart:async';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_share'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a pushed project brings exactly what it needs', () async {
    final a = device('A'), b = device('B');
    final sup = a.save('supplier', supplier('甲泵业'));
    final other = a.save('supplier', supplier('无关供应商'));
    final cid = a.save('contact', {
      'supplier_id': sup,
      'name': '张三',
      'phone': '1',
      'wechat': null,
      'email': null,
      'notes': null,
    });
    final pump = a.save('product', product('离心泵'));
    final valve = a.save('product', product('闸阀'));
    final pro = a.save('project', project('P1'));
    final unrelated = a.save('project', project('P2'));
    final q = a.save('quotation', quotation(sup, pump, pro, '100'));
    final line = a.save(
      'project_item',
      item(pro, 'material', productId: pump, quotationId: q),
    );
    final ids = a.shareClosure({
      'project': [pro],
    });
    expect(ids['project'], {pro});
    expect(ids['project_item'], {line});
    expect(ids['quotation'], {q});
    expect(ids['product'], {pump});
    expect(ids['supplier'], {sup});
    expect(ids['contact'], isEmpty, reason: 'the quote names no contact');
    expect(
      a.shareClosure({
        'supplier': [sup],
      })['contact'],
      {cid},
      reason: 'a supplier brings its contacts',
    );

    final file = '${tmp.path}/p1.siq';
    await a.exportSelection(file, {
      'project': [pro],
    });
    final preview = b.previewImport(file);
    expect(preview['project']!.added, 1);
    b.importFrom(file);
    expect(b.get('project_item', line), isNotNull);
    expect(b.get('supplier', sup), isNotNull);
    for (final (type, id) in [
      ('supplier', other),
      ('product', valve),
      ('project', unrelated),
    ]) {
      expect(b.get(type, id), isNull, reason: 'not part of the selection');
    }
    // Receiving again, or later the full file, merges as usual.
    b.importFrom(file);
    b.importFrom(exported(a));
    expect(content(b), content(a));
  });

  test('encrypted push needs the passphrase', () async {
    final a = device('A'), b = device('B');
    final sup = a.save('supplier', supplier('甲'));
    final file = '${tmp.path}/s.siq';
    await a.exportSelection(file, {
      'supplier': [sup],
    }, passphrase: 'correct horse');
    expect(isEncryptedExchange(file), isTrue);
    final plain = await decryptExchange(file, 'correct horse', tmp);
    b.importFrom(plain);
    expect(b.get('supplier', sup), isNotNull);
  });

  test('devices find each other and push over the network', () async {
    final pushes = StreamController<LanPush>();
    final inbox = Directory('${tmp.path}/inbox');
    final a = await LanNode.start(
      id: 'a',
      name: '采购部-01',
      inbox: Directory('${tmp.path}/a'),
      onPush: (_) {},
      discoveryPort: 0,
      httpPort: 0,
    );
    final b = await LanNode.start(
      id: 'b',
      name: '仓库平板',
      inbox: inbox,
      onPush: pushes.add,
      discoveryPort: 0,
      httpPort: 0,
    );
    addTearDown(() async {
      await a.stop();
      await b.stop();
    });
    // Discovery ports are random here, so announce directly; b answers.
    a.helloTo(InternetAddress.loopbackIPv4, b.discoveryPort);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(b.peers.map((p) => p.name), ['采购部-01']);
    expect(a.peers.map((p) => p.name), ['仓库平板'], reason: 'reply heard');

    final found = await a.probe('127.0.0.1', port: b.httpPort);
    expect(found.name, '仓库平板');
    final file = File('${tmp.path}/x.siq')..writeAsBytesSync([1, 2, 3, 4]);
    await a.push(found, file.path);
    final got = await pushes.stream.first;
    expect(got.fromName, '采购部-01');
    expect(File(got.path).readAsBytesSync(), [1, 2, 3, 4]);

    await expectLater(
      a.probe('127.0.0.1', port: 1),
      throwsA(isA<LanException>()),
    );
  });
}
