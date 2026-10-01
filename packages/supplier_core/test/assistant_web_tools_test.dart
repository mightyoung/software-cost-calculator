import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/src/ai_runtime.dart';
import 'package:supplier_core/src/assistant_web_tools.dart';
import 'package:test/test.dart';

AssistantWebResponse response(
  String text, {
  int status = 200,
  String type = 'text/html',
  String? location,
  void Function()? close,
}) => AssistantWebResponse(
  statusCode: status,
  contentType: type,
  location: location,
  body: Stream.value(utf8.encode(text)),
  close: close,
);
Future<List<InternetAddress>> publicDns(String _) async => [
  InternetAddress('93.184.216.34'),
];
Future<Map<String, dynamic>> execute(
  AssistantWebTools tools,
  String name,
  Map<String, Object?> args, {
  AiCancellation? cancellation,
}) async =>
    jsonDecode(
          await tools.execute(
            name,
            args,
            callId: 'test',
            cancellation: cancellation ?? AiCancellation(),
          ),
        )
        as Map<String, dynamic>;

void main() {
  test('rejects unsafe URLs and literal IP ranges before transport', () async {
    var calls = 0;
    final tools = AssistantWebTools(
      resolver: publicDns,
      transport: (uri, addresses, cancel) async {
        calls++;
        return response('bad');
      },
    );
    for (final url in [
      'http://example.com',
      'file:///etc/passwd',
      'https://user:secret@example.com',
      'https://example.com:8443',
      'https://localhost',
      'https://a.local',
      'https://127.0.0.1',
      'https://10.0.0.1',
      'https://172.31.1.1',
      'https://192.168.1.1',
      'https://169.254.169.254',
      'https://100.64.0.1',
      'https://0.0.0.0',
      'https://198.18.0.1',
      'https://192.0.2.1',
      'https://198.51.100.1',
      'https://203.0.113.1',
      'https://224.0.0.1',
      'https://[::1]',
      'https://[::ffff:127.0.0.1]',
      'https://[fe80::1]',
      'https://[fc00::1]',
      'https://[64:ff9b::7f00:1]',
      'https://[2002:7f00:1::]',
      'https://[2001:db8::1]',
      'https://[3fff::1]',
    ]) {
      expect(
        await execute(tools, 'web_fetch', {'url': url}),
        contains('error'),
        reason: url,
      );
    }
    expect(calls, 0);
  });

  test('checks all DNS answers including mixed public and private', () async {
    var calls = 0;
    for (final address in ['127.0.0.1', '169.254.169.254', '::1', 'fd00::1']) {
      final tools = AssistantWebTools(
        resolver: (_) async => [
          InternetAddress('8.8.8.8'),
          InternetAddress(address),
        ],
        transport: (uri, addresses, cancel) async {
          calls++;
          return response('bad');
        },
      );
      expect(
        await execute(tools, 'web_fetch', {'url': 'https://example.com'}),
        contains('error'),
      );
    }
    expect(calls, 0);
  });

  test(
    'passes checked resolution to transport and revalidates redirect DNS',
    () async {
      final hosts = <String>[];
      final tools = AssistantWebTools(
        resolver: (host) async {
          hosts.add(host);
          return [
            InternetAddress(host == 'example.com' ? '8.8.8.8' : '10.0.0.1'),
          ];
        },
        transport: (uri, addresses, cancel) async {
          expect(addresses.single.address, '8.8.8.8');
          return response(
            '',
            status: 302,
            location: 'https://internal.example.com',
          );
        },
      );
      expect(
        await execute(tools, 'web_fetch', {'url': 'https://example.com'}),
        contains('error'),
      );
      expect(hosts, ['example.com', 'internal.example.com']);
    },
  );

  test('rejects redirect downgrade and enforces three-hop limit', () async {
    for (final target in [
      'http://example.com',
      'https://127.0.0.1',
      '/again',
    ]) {
      var calls = 0;
      var closes = 0;
      final tools = AssistantWebTools(
        resolver: publicDns,
        transport: (uri, addresses, cancel) async {
          calls++;
          return response(
            '',
            status: 302,
            location: target,
            close: () => closes++,
          );
        },
      );
      expect(
        await execute(tools, 'web_fetch', {'url': 'https://example.com'}),
        contains('error'),
      );
      expect(calls, target == '/again' ? 4 : 1);
      expect(closes, calls);
    }
  });

  test(
    'reads HTML, strips active content, preserves final source and extracts cached passages',
    () async {
      var calls = 0;
      final tools = AssistantWebTools(
        resolver: publicDns,
        transport: (uri, addresses, cancel) async {
          calls++;
          if (uri.path != '/final')
            return response('', status: 302, location: '/final');
          return response(
            '<html><title>报价 &amp; 资料</title><script>secret()</script><style>hidden</style><p>钢材&#32;价格 100 元</p></html>',
          );
        },
      );
      final fetched = await execute(tools, 'web_fetch', {
        'url': 'https://example.com/start',
      });
      expect(fetched['text'], contains('钢材 价格 100 元'));
      expect(fetched['text'], isNot(contains('secret')));
      expect(fetched['text'], isNot(contains('hidden')));
      expect(fetched['title'], '报价 & 资料');
      expect(fetched['url'], 'https://example.com/final');
      expect(fetched['untrusted'], true);
      final extracted = await execute(tools, 'web_extract', {
        'url': fetched['url'],
        'keywords': ['钢材'],
      });
      expect(extracted['passages'], [fetched['text']]);
      expect(extracted['fetched_at'], fetched['fetched_at']);
      expect(extracted['sources'], fetched['sources']);
      expect(extracted['complete'], true);
      expect(calls, 2);
    },
  );

  test(
    'bounds page body and closes transport on overflow and invalid MIME',
    () async {
      for (final oversized in [true, false]) {
        var closed = false;
        final tools = AssistantWebTools(
          resolver: publicDns,
          transport: (uri, addresses, cancel) async => response(
            oversized ? 'x' * (AssistantWebTools.maxBodyBytes + 1) : 'binary',
            type: oversized ? 'text/html' : 'application/octet-stream',
            close: () => closed = true,
          ),
        );
        final result = await execute(tools, 'web_fetch', {
          'url': 'https://example.com',
        });
        expect(result, contains('error'));
        expect(closed, true);
      }
    },
  );

  test('bounds output and reports truncated cached content', () async {
    final tools = AssistantWebTools(
      resolver: publicDns,
      transport: (uri, addresses, cancel) async =>
          response('keyword ${'\\' * 30000}', type: 'text/plain'),
    );
    final result = await execute(tools, 'web_fetch', {
      'url': 'https://example.com',
    });
    expect(
      jsonEncode(result).length,
      lessThanOrEqualTo(AssistantWebTools.maxOutputChars),
    );
    expect(result['truncated'], true);
    expect(result['complete'], false);
    final extracted = await execute(tools, 'web_extract', {
      'url': result['url'],
      'keywords': ['keyword'],
    });
    expect(extracted['truncated'], true);
    expect(extracted['complete'], false);
  });

  test('cache is session-local and evicts after eight pages', () async {
    final tools = AssistantWebTools(
      resolver: publicDns,
      transport: (uri, addresses, cancel) async => response('keyword'),
    );
    for (var i = 0; i < 9; i++) {
      await execute(tools, 'web_fetch', {'url': 'https://example.com/$i'});
    }
    expect(
      await execute(tools, 'web_extract', {
        'url': 'https://example.com/0',
        'keywords': ['keyword'],
      }),
      contains('error'),
    );
    expect(
      await execute(AssistantWebTools(), 'web_extract', {
        'url': 'https://example.com/8',
        'keywords': ['keyword'],
      }),
      contains('error'),
    );
  });

  test(
    'parses bounded search results with provenance and ignores unsafe links',
    () async {
      final tools = AssistantWebTools(
        resolver: publicDns,
        transport: (uri, addresses, cancel) async {
          expect(uri.host, 'www.bing.com');
          expect(uri.queryParameters, {'format': 'rss', 'q': '钢材报价'});
          return response(
            '<rss><channel><item><title>bad</title><link>https://127.0.0.1</link></item>${List.generate(10, (i) => '<item><title>Result $i</title><link>https://example.com/$i</link><description>Public data</description></item>').join()}</channel></rss>',
            type: 'application/rss+xml',
          );
        },
      );
      final result = await execute(tools, 'web_search', {
        'query': '钢材报价',
        'limit': 8,
      });
      expect(result['returned'], 8);
      expect(result['truncated'], true);
      expect(result['complete'], false);
      expect((result['sources'] as List).first['title'], 'Result 0');
      expect(
        (result['sources'] as List).first['fetched_at'],
        result['fetched_at'],
      );
    },
  );

  test(
    'rejects XML entities, non-RSS and unavailable search service',
    () async {
      for (final text in [
        '<!DOCTYPE rss [<!ENTITY a "expanded">]><rss/>',
        '<html>Challenge</html>',
        'invalid',
      ]) {
        final tools = AssistantWebTools(
          resolver: publicDns,
          transport: (uri, addresses, cancel) async => response(text),
        );
        expect(
          await execute(tools, 'web_search', {'query': 'test'}),
          contains('error'),
        );
      }
    },
  );

  test(
    'rejects unknown arguments, model approvals, and invalid budgets',
    () async {
      var calls = 0;
      final tools = AssistantWebTools(
        resolver: publicDns,
        transport: (uri, addresses, cancel) async {
          calls++;
          return response('');
        },
      );
      for (final args in [
        {'query': 'q', 'approved': true},
        {'query': 'x' * 401},
        {'query': ' '},
        {'query': 'q', 'limit': 9},
        {'query': 'q', 'limit': 1.5},
      ]) {
        expect(await execute(tools, 'web_search', args), contains('error'));
      }
      expect(
        await execute(tools, 'web_fetch', {
          'url': 'https://example.com',
          'headers': {'Authorization': 'secret'},
        }),
        contains('error'),
      );
      expect(calls, 0);
    },
  );

  test(
    'pre-cancelled call propagates domain cancellation without network',
    () async {
      final cancel = AiCancellation()..cancel('user stopped');
      await expectLater(
        execute(AssistantWebTools(), 'web_fetch', {
          'url': 'https://example.com',
        }, cancellation: cancel),
        throwsA(isA<LlmException>()),
      );
    },
  );

  test('cancellation interrupts body stream and closes connection', () async {
    final body = StreamController<List<int>>();
    final started = Completer<void>();
    var closed = false;
    final tools = AssistantWebTools(
      resolver: publicDns,
      transport: (uri, addresses, cancel) async {
        started.complete();
        return AssistantWebResponse(
          statusCode: 200,
          contentType: 'text/plain',
          body: body.stream,
          close: () {
            closed = true;
            unawaited(body.close());
          },
        );
      },
    );
    final cancel = AiCancellation();
    final work = execute(tools, 'web_fetch', {
      'url': 'https://example.com',
    }, cancellation: cancel);
    final assertion = expectLater(work, throwsA(isA<LlmException>()));
    await started.future;
    cancel.cancel();
    await assertion;
    expect(closed, true);
  });

  test('timeout bounds even a hanging DNS resolver', () async {
    var calls = 0;
    final tools = AssistantWebTools(
      timeout: const Duration(milliseconds: 10),
      resolver: (_) => Completer<List<InternetAddress>>().future,
      transport: (uri, addresses, cancel) async {
        calls++;
        return response('');
      },
    );
    final result = await execute(tools, 'web_fetch', {
      'url': 'https://example.com',
    });
    expect(result['error'], contains('超时'));
    expect(calls, 0);
  });

  test('scans near-limit malformed HTML without repeated backtracking', () async {
    for (final marker in ['<', '<script>', '<title>', '<!--']) {
      final html =
          '<p>Visible &amp; safe</p>${marker * ((AssistantWebTools.maxBodyBytes - 100) ~/ marker.length)}';
      final tools = AssistantWebTools(
        resolver: publicDns,
        transport: (uri, addresses, cancel) async => response(html),
      );
      final watch = Stopwatch()..start();
      final result = await execute(tools, 'web_fetch', {
        'url': 'https://example.com',
      });
      watch.stop();
      expect(result, isNot(contains('error')), reason: marker);
      expect(result['text'], contains('Visible & safe'), reason: marker);
      expect(result['text'], isNot(contains('<script>')));
      expect(
        jsonEncode(result).length,
        lessThanOrEqualTo(AssistantWebTools.maxOutputChars),
      );
      expect(
        watch.elapsed,
        lessThan(const Duration(seconds: 2)),
        reason: marker,
      );
    }
  });

  test(
    'HTML scan handles quoted tag delimiters and unclosed active content',
    () async {
      final tools = AssistantWebTools(
        resolver: publicDns,
        transport: (uri, addresses, cancel) async => response(
          '<title data-x=">">Price &amp; source</title>'
          '<p data-x="a>b">Steel &#x31;00</p>'
          '<template><template>hidden</template>also hidden</template>'
          '<p>After template</p><script>never show this',
        ),
      );
      final result = await execute(tools, 'web_fetch', {
        'url': 'https://example.com',
      });
      expect(result['title'], 'Price & source');
      expect(result['text'], 'Price & source Steel 100 After template');
    },
  );
}
