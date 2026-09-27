import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// UDP port devices announce themselves on, and the HTTP port pushes go to
/// (typed by hand when broadcasts don't get through).
const lanDiscoveryPort = 47810, lanHttpPort = 47811;

/// Largest push accepted.
const maxPushBytes = 300 * 1024 * 1024;

/// A device is listed while its announcements keep arriving.
const _announceEvery = Duration(seconds: 3),
    _forgetAfter = Duration(seconds: 10);

class LanPeer {
  LanPeer(this.id, this.name, this.address, this.port, this.seen);
  final String id, name, address;
  final int port;
  final DateTime seen;
}

/// A file another device pushed, saved under the inbox until the user
/// accepts or declines it.
class LanPush {
  LanPush(this.fromId, this.fromName, this.address, this.path, this.at);
  final String fromId, fromName, address, path;
  final DateTime at;
}

class LanException implements Exception {
  LanException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// This device on the local network: announces itself over UDP broadcast,
/// answers announcements so devices that miss broadcasts (Android) still
/// learn about us, and receives pushes over HTTP. Nothing is imported here:
/// pushes wait in [inbox] for the user.
class LanNode {
  LanNode._(
    this.id,
    this.name,
    this.inbox,
    this._http,
    this._udp,
    this._discoveryPort,
    this._onPush,
    this._onPeers,
  );

  static Future<LanNode> start({
    required String id,
    required String name,
    required Directory inbox,
    required void Function(LanPush push) onPush,
    void Function()? onPeers,
    int discoveryPort = lanDiscoveryPort,
    int httpPort = lanHttpPort,
  }) async {
    inbox.createSync(recursive: true);
    HttpServer http;
    try {
      http = await HttpServer.bind(InternetAddress.anyIPv4, httpPort);
    } on SocketException {
      // Port taken (a second copy of the app): discovery still finds us.
      http = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    final RawDatagramSocket udp;
    try {
      udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        discoveryPort,
        reuseAddress: true,
      );
    } catch (_) {
      await http.close(force: true);
      rethrow;
    }
    udp.broadcastEnabled = true;
    final node = LanNode._(
      id,
      name,
      inbox,
      http,
      udp,
      discoveryPort,
      onPush,
      onPeers,
    );
    http.listen(node._serve);
    udp.listen(
      (e) {
        if (e == RawSocketEvent.read) node._receive();
      },
      // Failed sends surface here (an adapter without broadcast, network
      // down); discovery just tries again on the next tick.
      onError: (Object _) {},
    );
    node._timer = Timer.periodic(_announceEvery, (_) => node._tick());
    unawaited(node._tick());
    return node;
  }

  final String id, name;
  final Directory inbox;
  final HttpServer _http;
  final RawDatagramSocket _udp;
  final int _discoveryPort;
  final void Function(LanPush) _onPush;
  final void Function()? _onPeers;
  final _peers = <String, LanPeer>{};
  late final Timer _timer;

  int get httpPort => _http.port;
  int get discoveryPort => _udp.port;

  /// Devices heard from recently, by name.
  List<LanPeer> get peers {
    final cutoff = DateTime.now().subtract(_forgetAfter);
    return [
      for (final p in _peers.values)
        if (p.seen.isAfter(cutoff)) p,
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> stop() async {
    _timer.cancel();
    _udp.close();
    await _http.close(force: true);
  }

  // --- Discovery -----------------------------------------------------------

  List<int> _hello({bool reply = false}) => utf8.encode(
    jsonEncode({
      'siq': 1,
      'id': id,
      'name': name,
      'port': httpPort,
      if (reply) 'reply': true,
    }),
  );

  /// Announces this device to one address (tests, or a known device).
  void helloTo(InternetAddress address, int port) =>
      _udp.send(_hello(), address, port);

  var _listed = 0;

  Future<void> _tick() async {
    for (final target
        in _discoveryPort == 0
            ? const <InternetAddress>[]
            : await _broadcastTargets()) {
      try {
        _udp.send(_hello(), target, _discoveryPort);
      } on SocketException {
        // An interface without broadcast; the others still work.
      }
    }
    // Tell the UI when a device dropped off.
    if (peers.length != _listed) {
      _listed = peers.length;
      _onPeers?.call();
    }
  }

  /// The limited broadcast plus each interface's /24 broadcast: Windows
  /// sends 255.255.255.255 out of one adapter only, and Dart doesn't expose
  /// netmasks.
  // ponytail: assumes /24 office networks; add a netmask lookup if a site
  // uses larger subnets and devices go unseen.
  static Future<Set<InternetAddress>> _broadcastTargets() async {
    final targets = {InternetAddress('255.255.255.255')};
    try {
      for (final i in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )) {
        for (final a in i.addresses) {
          final b = a.rawAddress;
          targets.add(InternetAddress('${b[0]}.${b[1]}.${b[2]}.255'));
        }
      }
    } on SocketException {
      // No interface list: the limited broadcast alone.
    }
    return targets;
  }

  void _receive() {
    for (var d = _udp.receive(); d != null; d = _udp.receive()) {
      final Map<String, Object?> m;
      try {
        m = jsonDecode(utf8.decode(d.data)) as Map<String, Object?>;
      } on FormatException {
        continue;
      }
      if (m['siq'] != 1 ||
          m['id'] is! String ||
          m['name'] is! String ||
          m['port'] is! int ||
          m['id'] == id) {
        continue;
      }
      final isNew = !peers.any((p) => p.id == m['id']);
      _peers[m['id']! as String] = LanPeer(
        m['id']! as String,
        m['name']! as String,
        d.address.address,
        m['port']! as int,
        DateTime.now(),
      );
      if (m['reply'] != true) _udp.send(_hello(reply: true), d.address, d.port);
      if (isNew) _onPeers?.call();
    }
  }

  // --- Transfer ------------------------------------------------------------

  Future<void> _serve(HttpRequest req) async {
    final res = req.response;
    try {
      if (req.method == 'GET' && req.uri.path == '/hello') {
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({'siq': 1, 'id': id, 'name': name}));
      } else if (req.method == 'POST' && req.uri.path == '/push') {
        await _acceptPush(req);
      } else {
        res.statusCode = HttpStatus.notFound;
      }
    } catch (_) {
      res.statusCode = HttpStatus.badRequest;
    } finally {
      await res.close();
    }
  }

  Future<void> _acceptPush(HttpRequest req) async {
    final length = req.contentLength;
    if (length <= 0 || length > maxPushBytes) {
      req.response.statusCode = HttpStatus.requestEntityTooLarge;
      return;
    }
    final fromId = req.headers.value('x-siq-id') ?? '';
    final fromName = Uri.decodeComponent(req.headers.value('x-siq-name') ?? '');
    final at = DateTime.now();
    final file = File('${inbox.path}/push-${at.microsecondsSinceEpoch}.siq');
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in req) {
        received += chunk.length;
        if (received > length) throw const FormatException('too long');
        sink.add(chunk);
      }
      await sink.close();
      if (received != length) throw const FormatException('cut short');
    } catch (_) {
      await sink.close();
      if (file.existsSync()) file.deleteSync();
      rethrow;
    }
    _onPush(
      LanPush(
        fromId,
        fromName.isEmpty ? req.connectionInfo!.remoteAddress.address : fromName,
        req.connectionInfo!.remoteAddress.address,
        file.path,
        at,
      ),
    );
  }

  static HttpClient _client() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 5);

  /// Looks up a device by address when discovery can't see it.
  Future<LanPeer> probe(String host, {int port = lanHttpPort}) async {
    final client = _client();
    try {
      final res = await (await client.get(host, port, '/hello')).close();
      final m =
          jsonDecode(await utf8.decodeStream(res)) as Map<String, Object?>;
      if (m['siq'] != 1 || m['id'] is! String || m['name'] is! String) {
        throw const FormatException();
      }
      final peer = LanPeer(
        m['id']! as String,
        m['name']! as String,
        host,
        port,
        DateTime.now(),
      );
      _peers[peer.id] = peer;
      _onPeers?.call();
      return peer;
    } on FormatException {
      throw LanException('$host 上运行的不是询价台账');
    } on IOException {
      throw LanException('连不上 $host：确认对方已打开"局域网可见"，且在同一网络');
    } finally {
      client.close();
    }
  }

  /// Sends [file] to [to]; completes once the device has stored it.
  Future<void> push(LanPeer to, String file) async {
    final client = _client();
    try {
      final req = await client.post(to.address, to.port, '/push');
      final length = File(file).lengthSync();
      req.headers
        ..contentType = ContentType.binary
        ..contentLength = length
        ..set('x-siq-id', id)
        ..set('x-siq-name', Uri.encodeComponent(name));
      await req.addStream(File(file).openRead());
      final res = await req.close();
      await res.drain<void>();
      if (res.statusCode != HttpStatus.ok) {
        throw LanException(
          res.statusCode == HttpStatus.requestEntityTooLarge
              ? '内容太大，对方拒收（上限 ${maxPushBytes ~/ 1048576} MB）'
              : '对方没有收下（HTTP ${res.statusCode}）',
        );
      }
    } on IOException {
      throw LanException('发送给 ${to.name} 失败：对方可能已关闭"局域网可见"或离开网络');
    } finally {
      client.close();
    }
  }
}
