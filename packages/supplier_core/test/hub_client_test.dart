import 'dart:io';

import 'package:supplier_core/supplier_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart' as fixture;

// Runs the client against the real Rust hub when it has been built
// (cargo build in services/supplier_hub); skipped otherwise.
final _binary = File(
  '../../services/supplier_hub/target/debug/supplier-hub'
  '${Platform.isWindows ? '.exe' : ''}',
);
const _token = 'test-token-0123456789abcdef0123456789abcdef';

void main() {
  test('hub addresses', () {
    expect(
      parseHubAddress(' https://hub.example.com/ ').toString(),
      'https://hub.example.com',
    );
    expect(parseHubAddress('http://127.0.0.1:8080').port, 8080);
    for (final bad in [
      'hub.example.com',
      'ftp://x',
      'https://u:p@x',
      'https://x/?a=1',
    ]) {
      expect(() => parseHubAddress(bad), throwsFormatException, reason: bad);
    }
    expect(
      hubAddressIsPlainRemote(Uri.parse('http://127.0.0.1:8080')),
      isFalse,
    );
    expect(
      hubAddressIsPlainRemote(Uri.parse('http://localhost:8080')),
      isFalse,
    );
    expect(hubAddressIsPlainRemote(Uri.parse('http://10.0.0.5:8080')), isTrue);
    expect(hubAddressIsPlainRemote(Uri.parse('https://10.0.0.5')), isFalse);
  });

  group('against the real hub', () {
    late Directory dir;
    late Process hub;
    late Store store;
    late Uri base;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('hub-client-');
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final config = File('${dir.path}/hub.toml')
        ..writeAsStringSync(
          'center_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"\n'
          'bind = "127.0.0.1:$port"\n'
          'database = "hub.sqlite"\n'
          '[sync]\nenabled = false\n',
        );
      hub = await Process.start(
        _binary.absolute.path,
        ['serve', config.path],
        environment: {'HUB_API_TOKEN': _token},
      );
      base = Uri.parse('http://127.0.0.1:$port');
      for (var i = 0; ; i++) {
        try {
          await HubClient(base, token: _token).status();
          break;
        } on HubException {
          if (i > 100) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
      store = Store.open('${dir.path}/local.db', device: 'test');
    });

    tearDown(() async {
      store.close();
      hub.kill();
      await hub.exitCode;
      dir.deleteSync(recursive: true);
    });

    test('publish, detect up to date, republish an edit, search', () async {
      final client = HubClient(base, token: _token);
      final supplier = store.save('supplier', fixture.supplier('华东泵业'));
      store.save('contact', {
        'supplier_id': supplier,
        'name': '王工',
        'phone': '13800000000',
        'wechat': null,
        'email': null,
        'notes': null,
      });

      var d = await prepareHubPublication(
        client,
        store,
        type: 'supplier',
        id: supplier,
        includeContacts: true,
      );
      expect(d.upToDate, isFalse);
      expect(d.previous, 0);
      expect(d.records, hasLength(2));
      final receipt = await client.publish(d.draft);
      expect(receipt['revision'], 1);

      d = await prepareHubPublication(
        client,
        store,
        type: 'supplier',
        id: supplier,
        includeContacts: true,
      );
      expect(d.upToDate, isTrue, reason: 'nothing changed');

      store.save('supplier', {
        ...store.get('supplier', supplier)!.data,
        'rating_note': '交货准时',
      }, id: supplier);
      d = await prepareHubPublication(
        client,
        store,
        type: 'supplier',
        id: supplier,
        includeContacts: true,
      );
      expect((d.upToDate, d.previous, d.draft['revision']), (false, 1, 2));
      await client.publish(d.draft);

      final found = await client.search(q: '华东', kind: 'supplier');
      expect(found.single.title, '华东泵业');
      expect(found.single.revision, 2);
      final history = await client.history(found.single.origin, supplier);
      expect(history, hasLength(2));
      expect(await client.publication(found.single.origin, newUuid()), isNull);
    });

    test('a wrong token is a readable error', () async {
      await expectLater(
        HubClient(base, token: 'wrong-token-0123456789abcdef012345').status(),
        throwsA(
          isA<HubException>().having(
            (e) => e.message,
            'message',
            contains('令牌'),
          ),
        ),
      );
    });
  }, skip: _binary.existsSync() ? false : 'supplier-hub not built');
}
