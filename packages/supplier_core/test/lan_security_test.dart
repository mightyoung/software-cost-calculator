import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supplier_core/src/lan.dart';
import 'package:test/test.dart';

void main() {
  Future<LanNode> start({
    LanLimits limits = const LanLimits(),
    void Function(LanPush)? onPush,
    void Function()? onPeers,
  }) async {
    final dir = Directory.systemTemp.createTempSync('lan-security-');
    final node = await LanNode.start(
      id: 'local',
      name: 'Local',
      inbox: dir,
      onPush: onPush ?? (_) {},
      onPeers: onPeers,
      limits: limits,
      discoveryPort: 0,
      httpPort: 0,
    );
    addTearDown(() async {
      await node.stop();
      dir.deleteSync(recursive: true);
    });
    return node;
  }

  Future<int> post(LanNode node, List<int> bytes) async {
    final client = HttpClient();
    try {
      final req = await client.post('127.0.0.1', node.httpPort, '/push');
      req.contentLength = bytes.length;
      req.add(bytes);
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  Future<Socket> partial(LanNode node, {int length = 100}) async {
    final socket = await Socket.connect('127.0.0.1', node.httpPort);
    socket.write(
      'POST /push HTTP/1.1\r\nHost: localhost\r\n'
      'Content-Length: $length\r\nConnection: close\r\n\r\nx',
    );
    await socket.flush();
    addTearDown(socket.destroy);
    return socket;
  }

  Future<void> expectInboxEmpty(LanNode node) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      if (node.inbox.listSync().isEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(node.inbox.listSync(), isEmpty);
  }

  Future<void> allowConnectionReset(Future<void> completion) async {
    try {
      await completion;
    } on SocketException catch (error) {
      // Cancelling an incomplete HTTP request can send a TCP reset rather
      // than a FIN. Accept only ECONNRESET (macOS/Linux/Windows); timeouts
      // and other socket failures must still fail the regression.
      if (!{54, 104, 10054}.contains(error.osError?.errorCode)) rethrow;
    }
  }

  Future<void> expectPeerClose(Socket socket) async {
    // Socket exposes failures on both its read stream and its write sink.
    // Attach both handlers immediately, including while a timer is writing.
    unawaited(allowConnectionReset(socket.done.then<void>((_) {})));
    try {
      await allowConnectionReset(
        socket.drain<void>().timeout(const Duration(seconds: 2)),
      );
    } finally {
      socket.destroy();
    }
  }

  test('malformed discovery roots do not escape the socket callback', () async {
    final dir = Directory.systemTemp.createTempSync('lan-security-');
    final node = await LanNode.start(
      id: 'local',
      name: 'Local',
      inbox: dir,
      onPush: (_) {},
      discoveryPort: 0,
      httpPort: 0,
    );
    final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() async {
      udp.close();
      await node.stop();
      dir.deleteSync(recursive: true);
    });
    for (final text in ['[]', 'null', '42', '"name"', '{']) {
      udp.send(
        utf8.encode(text),
        InternetAddress.loopbackIPv4,
        node.discoveryPort,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    udp.send(
      utf8.encode(
        jsonEncode({
          'siq': 1,
          'id': 'valid',
          'name': 'Valid',
          'port': 1234,
          'reply': true,
        }),
      ),
      InternetAddress.loopbackIPv4,
      node.discoveryPort,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(node.peers.map((p) => p.id), ['valid']);
  });

  test(
    'peer flood is capped, invalid fields rejected and expired peers replaced',
    () async {
      var notifications = 0;
      final node = await start(
        limits: const LanLimits(
          maxPeers: 4,
          peerLifetime: Duration(milliseconds: 400),
        ),
        onPeers: () => notifications++,
      );
      final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(udp.close);
      void send(String id, {Object port = 1234, String name = 'Peer'}) {
        udp.send(
          utf8.encode(
            jsonEncode({
              'siq': 1,
              'id': id,
              'name': name,
              'port': port,
              'reply': true,
            }),
          ),
          InternetAddress.loopbackIPv4,
          node.discoveryPort,
        );
      }

      send('zero', port: 0);
      send('negative', port: -1);
      send('overflow', port: 65536);
      send('long', name: 'x' * 257);
      send('x' * 129);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(node.peers, isEmpty);
      for (var i = 0; i < 80; i++) send('peer-$i');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(node.peers, hasLength(4));
      expect(notifications, lessThanOrEqualTo(2));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      send('replacement');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(node.peers.map((p) => p.id), ['replacement']);
    },
  );

  for (final limits in [
    const LanLimits(maxUploads: 1, uploadIdle: Duration(milliseconds: 200)),
    const LanLimits(
      maxUploadsPerAddress: 1,
      uploadIdle: Duration(milliseconds: 200),
    ),
    const LanLimits(
      maxReservedBytes: 100,
      uploadIdle: Duration(milliseconds: 200),
    ),
  ]) {
    test(
      'active upload budgets reject excess and recover after idle timeout $limits',
      () async {
        final received = <LanPush>[];
        final node = await start(limits: limits, onPush: received.add);
        final stalled = await partial(node);
        final response = expectPeerClose(stalled);
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(await post(node, [1, 2]), HttpStatus.serviceUnavailable);
        // Cancelling an incomplete HTTP body may close before an error response.
        await response;
        expect(received, isEmpty);
        await expectInboxEmpty(node);
        expect(await post(node, [1, 2]), HttpStatus.ok);
        expect(received, hasLength(1));
        expect(File(received.single.path).readAsBytesSync(), [1, 2]);
      },
    );
  }

  test(
    'absolute deadline ends a trickling upload and removes partial data',
    () async {
      final node = await start(
        limits: const LanLimits(
          uploadIdle: Duration(milliseconds: 300),
          transferTimeout: Duration(milliseconds: 150),
        ),
      );
      final stalled = await partial(node);
      final response = expectPeerClose(stalled);
      final trickle = Timer.periodic(
        const Duration(milliseconds: 25),
        (_) => stalled.add([1]),
      );
      try {
        await response;
      } finally {
        trickle.cancel();
      }
      await expectInboxEmpty(node);
      expect(await post(node, [7]), HttpStatus.ok);
    },
  );

  test(
    'stop cancels pending uploads and completes cleanup before returning',
    () async {
      final node = await start();
      final socket = await partial(node);
      final response = expectPeerClose(socket);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await node.stop().timeout(const Duration(seconds: 2));
      await response;
      expect(node.inbox.listSync(), isEmpty);
    },
  );

  test(
    'callback failure removes the received file and releases admission',
    () async {
      var calls = 0;
      final node = await start(
        limits: const LanLimits(maxUploads: 1),
        onPush: (_) {
          if (calls++ == 0) throw StateError('receiver unavailable');
        },
      );
      expect(await post(node, [1, 2]), HttpStatus.badRequest);
      await expectInboxEmpty(node);
      expect(await post(node, [3, 4]), HttpStatus.ok);
      expect(node.inbox.listSync(), hasLength(1));
    },
  );

  test('probe bounds malformed, oversized and stalled responses', () async {
    final node = await start(
      limits: const LanLimits(probeTimeout: Duration(milliseconds: 100)),
    );
    for (final body in ['[]', 'x' * 5000, null]) {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        if (body != null) {
          req.response.write(body);
          await req.response.close();
        }
      });
      try {
        await expectLater(
          node.probe('127.0.0.1', port: server.port),
          throwsA(isA<LanException>()),
        );
      } finally {
        await server.close(force: true);
      }
    }
  });

  test('push bounds a receiver that never responds', () async {
    final node = await start(
      limits: const LanLimits(transferTimeout: Duration(milliseconds: 100)),
    );
    final file = File('${node.inbox.path}/out')..writeAsBytesSync([1]);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      req.drain<void>();
    });
    try {
      await expectLater(
        node.push(
          LanPeer('remote', 'Remote', '127.0.0.1', server.port, DateTime.now()),
          file.path,
        ),
        throwsA(isA<LanException>()),
      );
    } finally {
      await server.close(force: true);
    }
  });
}
