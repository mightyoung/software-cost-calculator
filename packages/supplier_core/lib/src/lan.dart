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

/// Resource budgets; file format and transport remain unchanged.
class LanLimits {
  const LanLimits({
    this.maxPeers = 256,
    this.maxUploads = 4,
    this.maxUploadsPerAddress = 2,
    this.maxReservedBytes = 600 * 1024 * 1024,
    this.peerLifetime = _forgetAfter,
    this.uploadIdle = const Duration(seconds: 30),
    this.transferTimeout = const Duration(minutes: 15),
    this.probeTimeout = const Duration(seconds: 10),
  }) : assert(maxPeers > 0),
       assert(maxUploads > 0),
       assert(maxUploadsPerAddress > 0),
       assert(maxReservedBytes > 0);

  final int maxPeers, maxUploads, maxUploadsPerAddress, maxReservedBytes;
  final Duration peerLifetime, uploadIdle, transferTimeout, probeTimeout;
}

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
    this._limits,
  );

  static Future<LanNode> start({
    required String id,
    required String name,
    required Directory inbox,
    required void Function(LanPush push) onPush,
    void Function()? onPeers,
    int discoveryPort = lanDiscoveryPort,
    int httpPort = lanHttpPort,
    LanLimits limits = const LanLimits(),
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
      limits,
    );
    http.listen((request) {
      final pending = node._serve(request);
      node._requests.add(pending);
      unawaited(pending.whenComplete(() => node._requests.remove(pending)));
    }, onError: (Object _) {});
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
  final LanLimits _limits;
  final _peers = <String, LanPeer>{};
  final _requests = <Future<void>>{};
  final _uploads = <StreamIterator<List<int>>>{};
  final _uploadsByAddress = <String, int>{};
  int _reservedBytes = 0;
  bool _stopped = false;
  Timer? _peerNotification;
  Future<void>? _stopping;
  late final Timer _timer;

  int get httpPort => _http.port;
  int get discoveryPort => _udp.port;

  /// Devices heard from recently, by name.
  List<LanPeer> get peers {
    _expirePeers();
    return _peers.values.toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    _stopped = true;
    _timer.cancel();
    _peerNotification?.cancel();
    _udp.close();
    await Future.wait(_uploads.toList().map((u) => u.cancel()));
    await _http.close(force: true);
    await Future.wait(_requests.toList());
  }

  void _expirePeers() {
    final cutoff = DateTime.now().subtract(_limits.peerLifetime);
    _peers.removeWhere((_, peer) => !peer.seen.isAfter(cutoff));
  }

  void _notifyPeers() {
    if (_stopped || _peerNotification != null) return;
    _peerNotification = Timer(const Duration(milliseconds: 100), () {
      _peerNotification = null;
      if (!_stopped) _onPeers?.call();
    });
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
        if (_stopped) return;
        _udp.send(_hello(), target, _discoveryPort);
      } on SocketException {
        // An interface without broadcast; the others still work.
      }
    }
    // Tell the UI when a device dropped off.
    if (peers.length != _listed) {
      _listed = peers.length;
      _notifyPeers();
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
    // Leave remaining datagrams for the next socket event so UI work can run.
    for (var count = 0; count < 32 && !_stopped; count++) {
      final d = _udp.receive();
      if (d == null) break;
      if (d.data.length > 4096) continue;
      final Map<String, Object?> m;
      try {
        final decoded = jsonDecode(utf8.decode(d.data));
        if (decoded is! Map<String, Object?>) continue;
        m = decoded;
      } on FormatException {
        continue;
      }
      if (!_validIdentity(m) ||
          m['port'] is! int ||
          (m['port']! as int) < 1 ||
          (m['port']! as int) > 65535 ||
          m['id'] == id) {
        continue;
      }
      _expirePeers();
      final isNew = !_peers.containsKey(m['id']);
      if (isNew && _peers.length >= _limits.maxPeers) continue;
      _peers[m['id']! as String] = LanPeer(
        m['id']! as String,
        m['name']! as String,
        d.address.address,
        m['port']! as int,
        DateTime.now(),
      );
      if (isNew && m['reply'] != true) {
        try {
          _udp.send(_hello(reply: true), d.address, d.port);
        } on SocketException {
          // Discovery retries later.
        }
      }
      if (isNew) _notifyPeers();
    }
  }

  static bool _validIdentity(Map<String, Object?> m) =>
      m['siq'] == 1 &&
      m['id'] is String &&
      (m['id']! as String).isNotEmpty &&
      utf8.encode(m['id']! as String).length <= 128 &&
      m['name'] is String &&
      utf8.encode(m['name']! as String).length <= 256;

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
      try {
        res.statusCode = HttpStatus.badRequest;
        res.persistentConnection = false;
      } catch (_) {
        // The socket may already be closed during shutdown.
      }
    } finally {
      try {
        await res.close();
      } catch (_) {
        // Client disconnected or the server was stopped.
      }
    }
  }

  Future<void> _acceptPush(HttpRequest req) async {
    final length = req.contentLength;
    if (length <= 0 || length > maxPushBytes) {
      req.response.statusCode = HttpStatus.requestEntityTooLarge;
      req.response.persistentConnection = false;
      return;
    }
    final address = req.connectionInfo!.remoteAddress.address;
    final active = _uploadsByAddress[address] ?? 0;
    if (_stopped ||
        _uploads.length >= _limits.maxUploads ||
        active >= _limits.maxUploadsPerAddress ||
        _reservedBytes + length > _limits.maxReservedBytes) {
      req.response.statusCode = HttpStatus.serviceUnavailable;
      req.response.persistentConnection = false;
      return;
    }
    final fromId = req.headers.value('x-siq-id') ?? '';
    final fromName = Uri.decodeComponent(req.headers.value('x-siq-name') ?? '');
    final at = DateTime.now();
    if (utf8.encode(fromId).length > 128 ||
        utf8.encode(fromName).length > 256) {
      throw const FormatException('sender identity too long');
    }
    final input = StreamIterator(req.timeout(_limits.uploadIdle));
    _uploads.add(input);
    _uploadsByAddress[address] = active + 1;
    _reservedBytes += length;
    var timedOut = false;
    final deadline = Timer(_limits.transferTimeout, () {
      timedOut = true;
      unawaited(input.cancel());
    });
    Directory? staging;
    RandomAccessFile? sink;
    var retained = false;
    var received = 0;
    try {
      staging = await inbox.createTemp('push-');
      final file = File('${staging.path}/data.siq');
      sink = await file.open(mode: FileMode.write);
      while (await input.moveNext()) {
        final chunk = input.current;
        received += chunk.length;
        if (received > length) throw const FormatException('too long');
        await sink.writeFrom(chunk);
      }
      await sink.close();
      sink = null;
      if (timedOut || _stopped) throw const FormatException('transfer stopped');
      if (received != length) throw const FormatException('cut short');
      // Move out of the unique staging directory: callers delete only the file.
      final finalFile = await file.rename('${staging.path}.siq');
      try {
        if (timedOut || _stopped)
          throw const FormatException('transfer stopped');
        _onPush(
          LanPush(
            fromId,
            fromName.isEmpty ? address : fromName,
            address,
            finalFile.path,
            at,
          ),
        );
        retained = true;
      } finally {
        if (!retained && await finalFile.exists()) await finalFile.delete();
      }
    } finally {
      deadline.cancel();
      try {
        try {
          await input.cancel();
        } finally {
          try {
            await sink?.close();
          } finally {
            if (staging != null && await staging.exists()) {
              await staging.delete(recursive: true);
            }
          }
        }
      } finally {
        _uploads.remove(input);
        _reservedBytes -= length;
        final remaining = (_uploadsByAddress[address] ?? 1) - 1;
        if (remaining == 0) {
          _uploadsByAddress.remove(address);
        } else {
          _uploadsByAddress[address] = remaining;
        }
      }
    }
  }

  static HttpClient _client() =>
      HttpClient()..connectionTimeout = const Duration(seconds: 5);

  static Future<List<int>> _responseBytes(HttpClientResponse response) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > 4096) {
        throw const FormatException('response too large');
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  /// Looks up a device by address when discovery can't see it.
  Future<LanPeer> probe(String host, {int port = lanHttpPort}) async {
    final client = _client();
    try {
      final m = await (() async {
        final req = await client.get(host, port, '/hello');
        req.followRedirects = false;
        final res = await req.close();
        if (res.statusCode != HttpStatus.ok) throw const FormatException();
        final decoded = jsonDecode(utf8.decode(await _responseBytes(res)));
        if (decoded is! Map<String, Object?> || !_validIdentity(decoded)) {
          throw const FormatException();
        }
        return decoded;
      })().timeout(_limits.probeTimeout);
      final peer = LanPeer(
        m['id']! as String,
        m['name']! as String,
        host,
        port,
        DateTime.now(),
      );
      _expirePeers();
      if (_stopped) throw LanException('局域网已关闭');
      if (!_peers.containsKey(peer.id) && _peers.length >= _limits.maxPeers) {
        throw LanException('附近设备过多，请稍后再试');
      }
      _peers[peer.id] = peer;
      _notifyPeers();
      return peer;
    } on FormatException {
      throw LanException('$host 上运行的不是询价台账');
    } on IOException {
      throw LanException('连不上 $host：确认对方已打开"局域网可见"，且在同一网络');
    } on TimeoutException {
      throw LanException('连接 $host 超时');
    } finally {
      client.close(force: true);
    }
  }

  /// Sends [file] to [to]; completes once the device has stored it.
  Future<void> push(LanPeer to, String file) async {
    final client = _client();
    try {
      await (() async {
        final req = await client.post(to.address, to.port, '/push');
        req.followRedirects = false;
        final length = File(file).lengthSync();
        req.headers
          ..contentType = ContentType.binary
          ..contentLength = length
          ..set('x-siq-id', id)
          ..set('x-siq-name', Uri.encodeComponent(name));
        await req.addStream(File(file).openRead());
        final res = await req.close();
        await _responseBytes(res);
        if (res.statusCode != HttpStatus.ok) {
          throw LanException(
            res.statusCode == HttpStatus.requestEntityTooLarge
                ? '内容太大，对方拒收（上限 ${maxPushBytes ~/ 1048576} MB）'
                : '对方没有收下（HTTP ${res.statusCode}）',
          );
        }
      })().timeout(_limits.transferTimeout);
    } on IOException {
      throw LanException('发送给 ${to.name} 失败：对方可能已关闭"局域网可见"或离开网络');
    } on TimeoutException {
      throw LanException('发送给 ${to.name} 超时');
    } on FormatException {
      throw LanException('来自 ${to.name} 的响应无效');
    } finally {
      client.close(force: true);
    }
  }
}
