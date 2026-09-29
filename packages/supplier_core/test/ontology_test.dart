import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_ontology'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('the ontology matches the code', () {
    test('every stored field is described, in order', () {
      for (final type in entityTypes) {
        expect(
          [for (final f in ontology[type]!.fields) f.name],
          payloadFields(type),
          reason: type,
        );
        for (final f in ontology[type]!.fields) {
          expect(f.label, isNotEmpty, reason: '$type.${f.name}');
        }
      }
    });

    test('references are links, and links are references', () {
      final declared = {
        for (final MapEntry(key: from, value: fields) in references.entries)
          for (final MapEntry(key: field, value: to) in fields.entries)
            '$from.$field': (to, Kind.ref),
        for (final MapEntry(key: from, value: fields) in listReferences.entries)
          for (final MapEntry(key: field, value: to) in fields.entries)
            '$from.$field': (to, Kind.refList),
      };
      final described = {
        for (final t in ontology.values)
          for (final f in t.fields)
            if (f.target != null) '${t.name}.${f.name}': (f.target!, f.kind),
      };
      expect(described, declared);
      expect({for (final l in links) l.name}, declared.keys.toSet());
    });

    test('enum values are the ones the validators accept', () {
      validatorEnums.forEach((key, allowed) {
        final [type, field] = key.split('.');
        expect(
          ontology[type]!.field(field)!.values!.keys.toSet(),
          allowed.toSet(),
          reason: key,
        );
      });
      for (final t in ontology.values) {
        for (final f in t.fields.where((f) => f.kind == Kind.enumeration)) {
          expect(f.values, isNotEmpty, reason: '${t.name}.${f.name}');
        }
      }
    });

    test('fields marked required are rejected when empty', () {
      final s = device('A');
      final sup = s.save('supplier', supplier('甲'));
      final prod = s.save('product', product('泵'));
      final pro = s.save('project', project('P1'));
      final samples = {
        'supplier': supplier('甲'),
        'contact': {
          'supplier_id': sup,
          'name': '张三',
          'phone': '1',
          'wechat': null,
          'email': null,
          'notes': null,
        },
        'product': product('泵'),
        'project': project('P1'),
        'project_item': item(pro, 'material', productId: prod),
        'quotation': quotation(sup, prod, pro, '1'),
        'inquiry': {
          'project_id': pro,
          'title': '询价',
          'item_ids': <String>[],
          'supplier_ids': <String>[],
          'due_date': null,
          'status': 'open',
          'notes': null,
        },
        'product_param': {
          'product_id': prod,
          'property': 'cpu.cores',
          'value': {'v': '8'},
          'cond': null,
          'source': 'manual',
          'evidence': null,
          'attachment_id': null,
          'confirmed': true,
          'dict_version': 1,
        },
        'spec_request': {
          'project_id': pro,
          'title': '技术要求',
          'source_name': null,
          'dict_version': 1,
          'notes': null,
        },
        'spec_item': {
          'request_id': s.createSpecRequest('技术要求', []),
          'seq': 1,
          'name': '工控机',
          'spec_class': null,
          'qty': null,
          'unit': null,
          'text': null,
          'project_item_id': null,
          'clauses': <Object>[],
          'chosen_product_id': null,
          'chosen_snapshot': null,
          'notes': null,
        },
        'spec_response': {
          'item_id': s.specItemsOf(
            s.createSpecRequest('技术要求', [draftItem('工控机', 'CPU八核')]),
          ).single.id,
          'supplier_id': sup,
          'inquiry_id': null,
          'rows': <Object>[],
          'received_on': null,
          'notes': null,
        },
      };
      for (final t in ontology.values) {
        validatePayload(t.name, samples[t.name]!); // the sample is valid
        for (final f in t.fields.where((f) => f.required)) {
          expect(
            () => validatePayload(t.name, {...samples[t.name]!, f.name: null}),
            throwsFormatException,
            reason: '${t.name}.${f.name} is marked required',
          );
        }
      }
    });

    test('the prompt card stays small', () {
      final card = ontologyCard();
      for (final t in ontology.values) {
        expect(card, contains('### ${t.name} ${t.label}'));
      }
      // About one token per 1.5 characters of mixed Chinese and ASCII.
      expect(card.length, lessThan(7000), reason: '${card.length} chars');
    });
  });

  group('agent tools', () {
    late Store s;
    late String jia, yi, pump, pro, line;
    Object? run(String name, Map<String, Object?> args) =>
        jsonDecode(s.runTool(name, jsonEncode(args)));

    setUp(() {
      s = device('A');
      jia = s.save('supplier', supplier('上海甲泵业'));
      yi = s.save('supplier', supplier('乙机电'));
      pump = s.save('product', {...product('离心泵'), 'model': 'IS80'});
      pro = s.save('project', project('P1'));
      line = s.save('project_item', item(pro, 'material', productId: pump));
      s.save('quotation', quotation(jia, pump, pro, '99'));
      s.save('quotation', {
        ...quotation(yi, pump, pro, '100'),
        'includes': ['freight'],
      });
    });

    test('every declared tool runs', () {
      final inq = s.createInquiry(
        pro,
        '泵询价',
        itemIds: [line],
        supplierIds: [jia, yi],
      );
      final calls = <String, Map<String, Object?>>{
        'describe': {},
        'search': {
          'type': 'product',
          'keywords': ['lxb'],
        },
        'get': {'type': 'product', 'id': pump},
        'query': {'type': 'quotation'},
        'related': {'link': 'quotation.supplier_id', 'id': jia},
        'compare_quotes': {'product_id': pump},
        'quote_options': {'project_id': pro, 'product_id': pump, 'qty': '2'},
        'project_budget': {'project_id': pro},
        'inquiry_matrix': {'inquiry_id': inq},
        'data_quality': {},
        'spec_classes': {'class': 'sensor.th'},
        'match_item': {'class': 'sensor.th', 'requirement': '防护等级IP65'},
      };
      expect({
        for (final t in agentTools) (t['function']! as Map)['name'],
      }, calls.keys.toSet());
      calls.forEach((name, args) {
        final r = run(name, args);
        expect(
          r,
          isNot(isA<Map>().having((m) => m['error'], 'error', isNotNull)),
          reason: '$name: $r',
        );
      });
      expect(
        (run('search', {
                  'type': 'product',
                  'keywords': ['lxb'],
                })!
                as List)
            .single['id'],
        pump,
      );
    });

    test('query compares decimals by value and lists by element', () {
      Map<String, Object?> q(List<Map<String, Object?>> where) =>
          run('query', {'type': 'quotation', 'where': where})!
              as Map<String, Object?>;
      // As text "99" > "100"; by value it is not.
      expect(
        q([
          {'field': 'price', 'op': 'gte', 'value': '100'},
        ])['total'],
        1,
      );
      expect(
        q([
          {'field': 'includes', 'op': 'eq', 'value': 'freight'},
        ])['total'],
        1,
      );
      expect(
        q([
          {'field': 'includes', 'op': 'is_null'},
        ])['total'],
        1,
      );
      expect(
        q([
          {
            'field': 'supplier_id',
            'op': 'in',
            'value': [jia, yi],
          },
          {'field': 'price', 'op': 'lt', 'value': 100},
        ])['total'],
        1,
      );
      final rows =
          run('related', {'link': 'quotation.supplier_id', 'id': yi})!
              as Map<String, Object?>;
      expect((rows['rows']! as List).single['price'], '100');
      expect(
        (rows['rows']! as List).single.containsKey('notes'),
        isFalse,
        reason: 'empty fields are left out',
      );
    });

    test('bad or hostile arguments come back as errors', () {
      for (final (name, args) in [
        ('query', {'type': 'quotation; DROP TABLE supplier'}),
        (
          'query',
          {
            'type': 'quotation',
            'where': [
              {'field': "price') OR 1=1 --", 'op': 'eq', 'value': 1},
            ],
          },
        ),
        (
          'query',
          {
            'type': 'quotation',
            'where': [
              {'field': 'price', 'op': 'like', 'value': 1},
            ],
          },
        ),
        (
          'query',
          {'type': 'quotation', 'order_by': 'price; DROP TABLE supplier'},
        ),
        ('related', {'link': 'supplier.name', 'id': jia}),
        ('get', {'type': 'attachment', 'id': jia}),
        ('describe', {'type': 'nope'}),
      ]) {
        expect(
          run(name, args),
          containsPair('error', isNotNull),
          reason: '$name $args',
        );
      }
      expect(s.get('supplier', jia), isNotNull);
    });

    test('merged and deleted records are not listed', () {
      final dup = s.save('supplier', supplier('上海甲泵业有限公司'));
      s.mergeInto('supplier', dup, jia);
      s.delete('supplier', yi);
      final r = run('query', {'type': 'supplier'})! as Map<String, Object?>;
      expect(r['total'], 1);
      expect((r['rows']! as List).single['id'], jia);
    });
  });
}
