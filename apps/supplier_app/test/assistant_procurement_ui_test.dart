import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supplier_app/app/app_state.dart';
import 'package:supplier_app/app/theme.dart';
import 'package:supplier_app/features/ai/ask_page.dart';
import 'package:supplier_core/supplier_core.dart';

const _url = 'https://catalog.example/product';
const _fabrication = '虚构品牌幻影机型价格999999元';

String _page() =>
    '''<html><title>真实来源产品</title>
<script type="application/ld+json">${jsonEncode({
      '@type': 'Product',
      'name': '来源服务器',
      'model': 'REAL-8',
      'brand': '来源品牌',
      'additionalProperty': [
        for (final entry in {'unit': '件', 'tax_mode': 'included', 'tax_rate': '13', 'min_qty': '1', 'shipping': 'included', 'configuration': '8 cores', 'manufacture_country': '中国', 'brand_origin': '中国', 'cpu.cores': '8核'}.entries) {'@type': 'PropertyValue', 'name': entry.key, 'value': entry.value},
      ],
      'offers': {
        '@type': 'Offer',
        'price': '100',
        'priceCurrency': 'CNY',
        'seller': {'name': '来源供应商'},
        'validFrom': '2026-01-01',
        'priceValidUntil': '2099-12-31',
      },
    })}</script><body>来源服务器 REAL-8，网页参考价。</body></html>''';

class _State extends AppState {
  _State(super.store, super.dataDir, Transport transport)
    : client = LlmClient(const LlmConfig(apiKey: 'fake'), transport: transport),
      super.test();
  final LlmClient client;
  int networkRequests = 0;
  @override
  Future<LlmClient?> llm() async => client;
  @override
  AssistantWebTools createAssistantWebTools(String jobId) => AssistantWebTools(
    resolver: (_) async => [InternetAddress('93.184.216.34')],
    transport: (uri, addresses, cancellation) async {
      networkRequests++;
      expect(uri.toString(), _url);
      return AssistantWebResponse(
        statusCode: 200,
        contentType: 'text/html',
        body: Stream.value(utf8.encode(_page())),
      );
    },
    restoredSnapshots: assistantWebSnapshots(jobId),
    onSnapshot: (snapshot) => saveAssistantWebSnapshot(jobId, snapshot),
  );
}

Map<String, Object?> _reply(String text) => {
  'choices': [
    {
      'message': {'content': text},
    },
  ],
};
Map<String, Object?> _call(int step, String name, Map<String, Object?> args) =>
    {
      'choices': [
        {
          'message': {
            'tool_calls': [
              {
                'id': 'procurement-$step',
                'type': 'function',
                'function': {'name': name, 'arguments': jsonEncode(args)},
              },
            ],
          },
        },
      ],
    };

Map<String, dynamic> _lastResult(Map<String, Object?> body) {
  final messages = body['messages'] as List;
  final message = messages.lastWhere((m) => m['role'] == 'tool') as Map;
  return jsonDecode(message['content'] as String) as Map<String, dynamic>;
}

Future<void> _mount(WidgetTester tester, AppState state, {double scale = 1}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(body: AskPage(state: state)),
      ),
    );
Future<void> _send(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), '按项目技术要求研究可采购的产品');
  await tester.pump();
  await tester.tap(find.byTooltip('发送'));
  await _advance(tester);
}

Future<void> _advance(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory dir;
  late Store store;
  late String itemId;
  late String originalQuoteId;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('assistant_procurement_ui');
    store = Store.open('${dir.path}/data.db', device: 'ui');
    final projectId = store.save('project', {
      for (final field in payloadFields('project')) field: null,
      'code': 'A',
      'name': '原A项目',
      'status': 'active',
      'type': 'market',
      'level': 'A',
      'currency': 'CNY',
      'tax_mode': 'included',
      'markup_rate': '0',
    });
    final productId = store.save('product', {
      for (final field in payloadFields('product')) field: null,
      'name': '原物料',
      'unit': '件',
    });
    final supplierId = store.save('supplier', {
      for (final field in payloadFields('supplier')) field: null,
      'name': '原供应商',
      'aliases': <String>[],
      'categories': <String>[],
    });
    originalQuoteId = store.save('quotation', {
      for (final field in payloadFields('quotation')) field: null,
      'supplier_id': supplierId,
      'product_id': productId,
      'project_id': projectId,
      'price': '250',
      'currency': 'CNY',
      'tax_mode': 'included',
      'unit_snapshot': '件',
      'min_qty': '1',
      'quoted_on': '2026-09-01',
      'tax_rate': '13',
      'inquirer_name': '原询价员',
      'inquiry_precision': 'date',
      'inquiry_date': '2026-09-01',
      'capture_mode': 'standard',
    });
    itemId = store.save('project_item', {
      for (final field in payloadFields('project_item')) field: null,
      'project_id': projectId,
      'category': 'material',
      'product_id': productId,
      'quotation_id': originalQuoteId,
      'name': '原预算物料',
      'qty': '2',
      'unit': '件',
      'unit_cost': '250',
      'unit_price': '300',
      'requirement': '物理核数>=8核；中国制造',
    });
  });
  tearDown(() {
    store.close();
    dir.deleteSync(recursive: true);
  });

  testWidgets('ungrounded model prose is shown with a no-evidence warning', (
    tester,
  ) async {
    final state = _State(store, dir, (_) async => _reply(_fabrication));
    addTearDown(state.dispose);
    await _mount(tester, state);
    await _send(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining(_fabrication), findsOneWidget);
    expect(find.textContaining('尚无查询依据'), findsWidgets);
  });

  for (final scenario in ['product', 'quotation', 'pricing', 'requirement']) {
    for (final forgedConsent in [false, true]) {
      testWidgets(
        'generic $scenario write cannot bypass source review (forged consent: $forgedConsent)',
        (tester) async {
          var turn = 0;
          final before = store.get('project_item', itemId)!;
          final writes = store.db
              .select('SELECT COUNT(*) AS n FROM change_log')
              .single['n'];
          final state = _State(
            store,
            dir,
            (_) async => ++turn == 1
                ? _call(
                    turn,
                    scenario == 'product' || scenario == 'quotation'
                        ? 'create_record'
                        : 'update_record',
                    {
                      'type': scenario == 'product' || scenario == 'quotation'
                          ? scenario
                          : 'project_item',
                      if (scenario == 'pricing' || scenario == 'requirement')
                        'id': itemId,
                      'values': switch (scenario) {
                        'product' => {'name': _fabrication, 'unit': '件'},
                        'quotation' => {
                          ...store.get('quotation', originalQuoteId)!.data,
                          'price': '1',
                        },
                        'pricing' => {'unit_cost': '1'},
                        _ => {'requirement': '无技术要求'},
                      },
                      if (forgedConsent) ...{
                        'confirmed': true,
                        'source_url': _url,
                      },
                    },
                  )
                : _reply(_fabrication),
          );
          addTearDown(state.dispose);
          await _mount(tester, state);
          await _send(tester);
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(
            turn,
            2,
            reason: 'The rejected tool must return to the model loop',
          );
          expect(store.get('project_item', itemId)!.data, before.data);
          expect(store.get('project_item', itemId)!.version, before.version);
          expect(
            store.db.select('SELECT COUNT(*) AS n FROM change_log').single['n'],
            writes,
          );
        },
      );
    }
  }

  for (final approve in [false, true]) {
    testWidgets(
      'source import ${approve ? 'approval preserves reference evidence' : 'refusal writes nothing'}',
      (tester) async {
        var turn = 0;
        String? sourceId;
        final before = store.get('project_item', itemId)!;
        final originalQuote = store.get('quotation', originalQuoteId)!;
        final changes = store.db
            .select('SELECT COUNT(*) AS n FROM change_log')
            .single['n'];
        final state = _State(store, dir, (body) async {
          turn++;
          if (turn == 1) return _call(turn, 'web_fetch', {'url': _url});
          final result = _lastResult(body);
          expect(result, isNot(contains('error')), reason: '$result');
          if (turn == 2) {
            sourceId = result['source_id'] as String;
            return _call(turn, 'web_product_rows', {'source_id': sourceId});
          }
          if (turn == 3) {
            final rows = result['products'] as List;
            expect(rows, hasLength(1));
            return _call(turn, 'procurement_stage', {
              'source_id': sourceId,
              'row_id': rows.single['id'],
              'item_id': itemId,
            });
          }
          if (turn == 4) {
            return _call(turn, 'procurement_import', {
              'candidate_id': result['candidate_id'],
              'operation': 'catalog',
            });
          }
          return _reply(_fabrication);
        })..assistantWebEnabled = true;
        addTearDown(state.dispose);
        if (!approve) {
          tester.view.physicalSize = const Size(320, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
        }
        await _mount(tester, state, scale: approve ? 1 : 2);
        await _send(tester);
        expect(state.networkRequests, 0);
        expect(find.text(_url), findsOneWidget);
        await tester.tap(find.text('允许此次请求'));
        await _advance(tester);
        expect(state.networkRequests, 1);
        expect(find.text('确认导入来源资料'), findsOneWidget);
        expect(find.textContaining('物理核数>=8核；中国制造'), findsWidgets);
        expect(find.textContaining('REAL-8'), findsWidgets);
        expect(find.textContaining(_url), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(approve ? '确认操作' : '拒绝'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(store.get('project_item', itemId)!.data, before.data);
        expect(store.get('project_item', itemId)!.version, before.version);
        expect(
          store.get('quotation', originalQuoteId)!.data,
          originalQuote.data,
        );
        final products = store.db.select('SELECT data FROM product');
        expect(products.length, approve ? 2 : 1);
        final quotes = store.db.select('SELECT data FROM quotation');
        expect(quotes.length, approve ? 2 : 1);
        if (approve) {
          final imported = quotes
              .map((r) => jsonDecode(r['data'] as String) as Map)
              .singleWhere((q) => q['price_basis'] == 'reference');
          expect(imported['price'], '100');
          expect(imported['currency'], 'CNY');
          expect(imported['tax_mode'], 'included');
          expect(imported['attachment_ids'], hasLength(1));
          final attachment = store.attachment(
            (imported['attachment_ids'] as List).single as String,
          )!;
          final provenance = utf8.decode(attachment.bytes!);
          expect(provenance, contains(_url));
          expect(provenance, contains('selected_row_id'));
          expect(provenance, contains('REAL-8'));
        } else {
          expect(
            store.db.select('SELECT COUNT(*) AS n FROM change_log').single['n'],
            changes,
          );
        }
        expect(state.setting('ask_history'), isNot(contains(_fabrication)));
        expect(find.textContaining(_fabrication), findsNothing);
      },
    );
  }

  testWidgets(
    'domestic criterion starts unresolved and changes through native permission menu',
    (tester) async {
      final state = _State(store, dir, (_) async => _reply('国产指国产品牌'));
      addTearDown(state.dispose);
      await _mount(tester, state);
      expect(state.assistantDomesticCriterion, isNull);
      await _send(tester);
      await tester.pumpAndSettle();
      expect(state.assistantDomesticCriterion, isNull);
      await tester.tap(find.byTooltip('助手权限'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('国产指国产品牌').last);
      await tester.pumpAndSettle();
      expect(state.assistantDomesticCriterion, 'brand');
      await tester.tap(find.byTooltip('助手权限'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('国产口径待明确'));
      await tester.pumpAndSettle();
      expect(state.assistantDomesticCriterion, isNull);
    },
  );
}
