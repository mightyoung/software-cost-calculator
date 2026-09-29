import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/data_center/data_center_page.dart';
import 'package:supplier_app/features/data_center/ontology_graph_host.dart';
import 'package:supplier_app/features/data_center/ontology_payload.dart';
import 'package:supplier_core/supplier_core.dart';

void main() {
  test(
    'bridge exposes schema and counts, rejects unknown selection messages',
    () {
      final payload = ontologyHostPayload(
        counts: {'supplier': 3, 'private': 4},
        selected: 'invalid',
        dark: true,
        reducedMotion: true,
        textScale: 1.4,
      );
      expect(payload['selected'], 'quotation');
      expect((payload['counts'] as Map)['supplier'], 3);
      expect((payload['counts'] as Map).containsKey('private'), isFalse);
      expect(jsonDecode(jsonEncode(payload))['schema'], ontologyGraphSchema());
      final supplier = (ontologyGraphSchema()['nodes'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((node) => node['id'] == 'supplier');
      final fields = ((supplier['data'] as Map)['fields'] as List).cast<Map>();
      expect(
        fields.firstWhere((field) => field['name'] == 'rating')['values'],
        ontology['supplier']!.field('rating')!.values,
      );
      expect(
        fields.firstWhere((field) => field['name'] == 'merged_into')['target'],
        'supplier',
      );
      expect(ontologySelection(['supplier']), 'supplier');
      for (final args in [
        [],
        ['unknown'],
        ['supplier', 'product'],
        [3],
        [
          {'id': 'supplier'},
        ],
      ]) {
        expect(ontologySelection(args), isNull);
      }
      final script = ontologyUpdateScript({'label': "');alert(1);//\n中文"});
      final encoded = script.substring(
        script.indexOf('update(') + 7,
        script.lastIndexOf('); null;'),
      );
      expect(jsonDecode(encoded), {'label': "');alert(1);//\n中文"});
    },
  );

  testWidgets(
    'formal data center propagates live counts, selection, and appearance without writes',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('ontology_host');
      final store = Store.open('${dir.path}/test.db', device: 'test');
      final state = AppState.test(store, dir);
      addTearDown(() {
        store.close();
        dir.deleteSync(recursive: true);
        Tokens.dark = false;
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      OntologyViewConfiguration? current;
      Widget app(bool dark) {
        Tokens.dark = dark;
        return MaterialApp(
          theme: buildTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: true,
              textScaler: const TextScaler.linear(1.4),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: DataCenterPage(
              state: state,
              ontologyViewBuilder: (context, config) {
                current = config;
                return const SizedBox.expand(key: ValueKey('fake-graph'));
              },
            ),
          ),
        );
      }

      await tester.pumpWidget(app(false));
      expect(current!.payload['selected'], 'quotation');
      current!.onRendered();
      await tester.pump();
      final before = store.recordCounts();
      current!.onSelect('supplier');
      await tester.pump();
      expect(current!.payload['selected'], 'supplier');
      current!.onSelect('not-a-type');
      await tester.pump();
      expect(current!.payload['selected'], 'supplier');
      expect(store.recordCounts(), before);
      store.save('supplier', {
        for (final f in Supplier.fields) f: null,
        'name': '新增供应商',
        'aliases': <String>[],
        'categories': <String>[],
      });
      state.changed();
      await tester.pump();
      expect((current!.payload['counts'] as Map)['supplier'], 1);
      await tester.pumpWidget(app(true));
      await tester.pumpAndSettle();
      expect(current!.payload['dark'], true);
      expect(current!.payload['reducedMotion'], true);
      expect(current!.payload['textScale'], 1.4);
      current!.onError('加载失败');
      await tester.pumpAndSettle();
      expect(find.text('加载失败'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ontology-details-supplier')),
        findsOneWidget,
      );
      final stale = current!;
      await tester.tap(find.text('打开关系图'));
      await tester.pump();
      stale.onError('旧请求失败');
      await tester.pump();
      expect(find.text('旧请求失败'), findsNothing);
      current!.onRendered();
      await tester.pump();
      expect(current!.payload['selected'], 'supplier');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      stale.onRendered(); // A late native callback after disposal is harmless.
    },
  );

  testWidgets('silent renderer times out into usable native view', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OntologyGraphHost(
            counts: const {},
            selected: 'quotation',
            onSelect: (_) {},
            fallback: const Text('native fallback'),
            viewBuilder: (_, config) => const SizedBox.expand(),
          ),
        ),
      ),
    );
    expect(find.text('正在打开关系图…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 21));
    expect(find.text('native fallback'), findsOneWidget);
    expect(find.textContaining('加载超时'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
