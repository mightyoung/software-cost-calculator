import 'dart:io';
import 'dart:convert';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';
import '../tool/hub_export.dart';
import 'fixtures.dart' as fixture;

void main() {
  late Directory dir;
  late Store store;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('hub-export-');
    store = Store.open('${dir.path}/local.db', device: 'test');
  });
  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  test(
    'read-only export keeps exact quote context without logs or other suppliers',
    () {
      final supplier = store.save('supplier', fixture.supplier('选中供应商'));
      store.save('supplier', fixture.supplier('未选供应商'));
      final product = store.save('product', fixture.product('设备'));
      final project = store.save('project', fixture.project('P-1'));
      final quote = store.save(
        'quotation',
        fixture.quotation(supplier, product, project, '123456789012.123456'),
      );
      final before = fixture.content(store);
      final reader = openReadOnly('${dir.path}/local.db');
      try {
        final result = buildHubPublication(
          reader,
          type: 'quotation',
          id: quote,
          publicationId: '99999999-9999-4999-8999-999999999999',
          revision: 1,
        );
        final records = result['records'] as List<Map<String, Object?>>;
        expect(records.length, 4);
        final row = records.singleWhere((r) => r['entity_type'] == 'quotation');
        expect((row['data'] as Map)['price'], '123456789012.123456');
        expect((row['data'] as Map)['inquirer_name'], '张三');
        expect(jsonEncode(result), isNot(contains('未选供应商')));
        expect(jsonEncode(result), isNot(contains('change_log')));
        expect(fixture.content(store), before);
        // Optional handoff to the Rust HTTP smoke test, using this real Dart-validated fixture.
        final output = Platform.environment['HUB_EXPORT_FIXTURE'];
        if (output != null) {
          File(output).writeAsStringSync(jsonEncode(result));
        }
      } finally {
        reader.close();
      }
    },
  );

  test('supplier root exports no implicit contact children', () {
    final supplier = store.save('supplier', fixture.supplier('供应商'));
    store.save('contact', {
      'supplier_id': supplier,
      'name': '联系人',
      'phone': '123',
      'wechat': null,
      'email': null,
      'notes': null,
    });
    final result = buildHubPublication(
      store,
      type: 'supplier',
      id: supplier,
      publicationId: '99999999-9999-4999-8999-999999999999',
      revision: 1,
    );
    expect((result['records'] as List).length, 1);
  });

  test('rejects missing roots and invalid revisions without writes', () {
    expect(
      () => buildHubPublication(
        store,
        type: 'supplier',
        id: '88888888-8888-4888-8888-888888888888',
        publicationId: '99999999-9999-4999-8999-999999999999',
        revision: 1,
      ),
      throwsStateError,
    );
    expect(
      () => buildHubPublication(
        store,
        type: 'supplier',
        id: '88888888-8888-4888-8888-888888888888',
        publicationId: '99999999-9999-4999-8999-999999999999',
        revision: 0,
      ),
      throwsArgumentError,
    );
  });
}
