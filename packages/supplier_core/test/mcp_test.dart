import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('supplier_mcp'));
  tearDown(() => tmp.deleteSync(recursive: true));

  late String path, pump;
  setUp(() {
    path = '${tmp.path}/app.db';
    final app = Store.open(path, device: '采购部-01');
    pump = app.save('product', {...product('离心泵'), 'model': 'IS80'});
    app.close();
  });

  Map<String, Object?> call(McpServer s, Object request) =>
      jsonDecode(s.handleLine(jsonEncode(request))!) as Map<String, Object?>;
  Map<String, Object?> request(int id, String method, [Object? params]) => {
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': ?params,
  };

  test('initialize, list and call tools, read the guide', () {
    final s = McpServer(openReadOnly(path), version: '1.0.9');
    final init =
        call(
              s,
              request(1, 'initialize', {
                'protocolVersion': '2025-06-18',
                'capabilities': {},
                'clientInfo': {'name': 'test', 'version': '1'},
              }),
            )['result']!
            as Map;
    expect(init['protocolVersion'], '2025-06-18');
    expect((init['serverInfo']! as Map)['version'], '1.0.9');
    expect(
      s.handleLine(
        jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
      ),
      isNull,
    );

    final tools =
        (call(s, request(2, 'tools/list'))['result']! as Map)['tools'] as List;
    expect(tools, hasLength(agentTools.length));
    expect(
      tools.every((t) => (t['annotations'] as Map)['readOnlyHint'] == true),
      isTrue,
    );

    final found =
        call(
              s,
              request(3, 'tools/call', {
                'name': 'search',
                'arguments': {
                  'type': 'product',
                  'keywords': ['lxb'],
                },
              }),
            )['result']!
            as Map;
    expect(found['isError'], isFalse);
    final text = ((found['content']! as List).single as Map)['text'] as String;
    expect((jsonDecode(text) as List).single['id'], pump);

    final bad =
        call(
              s,
              request(4, 'tools/call', {
                'name': 'drop_everything',
                'arguments': {},
              }),
            )['result']!
            as Map;
    expect(bad['isError'], isTrue);

    final guide = call(s, request(5, 'resources/read', {'uri': 'siq://guide'}));
    expect(
      (((guide['result']! as Map)['contents'] as List).single as Map)['text'],
      contains('## 工具（只读）'),
    );
  });

  test('protocol errors follow JSON-RPC', () {
    final s = McpServer(openReadOnly(path));
    expect(
      (jsonDecode(s.handleLine('{not json')!) as Map)['error'],
      containsPair('code', -32700),
    );
    expect(
      call(s, request(1, 'sampling/createMessage'))['error'],
      containsPair('code', -32601),
    );
    expect(
      call(
        s,
        request(2, 'resources/read', {'uri': 'file:///etc/passwd'}),
      )['error'],
      containsPair('code', -32002),
    );
    expect(
      (call(
            s,
            request(3, 'initialize', {'protocolVersion': '1999-01-01'}),
          )['result']!
          as Map)['protocolVersion'],
      mcpVersions.first,
    );
  });

  test('the database cannot be written, and other versions are refused', () {
    final store = openReadOnly(path);
    expect(
      () => store.save('supplier', supplier('新')),
      throwsA(isA<SqliteException>()),
    );
    store.close();

    final db = sqlite3.open(path);
    db.execute("UPDATE meta SET value = '99' WHERE key = 'schema_version'");
    db.close();
    expect(
      () => openReadOnly(path),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('更新')),
      ),
    );
    expect(
      () => openReadOnly('${tmp.path}/missing.db'),
      throwsA(isA<StateError>()),
    );
  });
}
