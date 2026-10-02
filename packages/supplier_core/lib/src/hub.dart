import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'quotation.dart';
import 'store.dart';
import 'values.dart';

// The optional company hub (services/supplier_hub): colleagues publish chosen
// suppliers and quotations there and search what others published. Nothing
// here runs unless a hub address is configured, and nothing is sent without
// the person confirming the exact records first.

class HubException implements Exception {
  HubException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A hub address as typed: http(s), a host, nothing after the path.
Uri parseHubAddress(String text) {
  final t = text.trim().replaceFirst(RegExp(r'/+$'), '');
  final u = Uri.tryParse(t);
  if (u == null ||
      !(u.scheme == 'http' || u.scheme == 'https') ||
      u.host.isEmpty ||
      u.userInfo.isNotEmpty ||
      u.hasQuery ||
      u.hasFragment) {
    throw const FormatException(
      '中心地址应类似 https://hub.example.com 或 http://127.0.0.1:8080',
    );
  }
  return u;
}

/// Plain HTTP to another machine: a token would cross the network readable.
bool hubAddressIsPlainRemote(Uri u) {
  if (u.scheme != 'http') return false;
  if (u.host == 'localhost') return false;
  final ip = InternetAddress.tryParse(u.host);
  return ip == null || !ip.isLoopback;
}

/// One published supplier or quotation as the hub lists it.
class HubSummary {
  HubSummary.fromJson(Map<String, Object?> j)
    : origin = j['origin']! as String,
      publicationId = j['publication_id']! as String,
      revision = j['revision']! as int,
      withdrawn = j['withdrawn'] == true,
      kind = j['kind']! as String,
      title = j['title'] as String? ?? '',
      rootId = j['root_id']! as String,
      context = (j['context'] as Map?)?.cast<String, Object?>() ?? const {};
  final String origin, publicationId, kind, title, rootId;
  final int revision;
  final bool withdrawn;
  final Map<String, Object?> context;
}

class HubClient {
  HubClient(
    this.base, {
    this.token,
    this.timeout = const Duration(seconds: 20),
  });
  final Uri base;
  final String? token;
  final Duration timeout;

  static const _maxResponse = 8 * 1024 * 1024;

  Future<Map<String, Object?>> status() async =>
      (await _send('GET', '/v1/status'))!;

  Future<List<HubSummary>> search({
    String q = '',
    String? kind,
    bool includeWithdrawn = false,
    int limit = 50,
    int offset = 0,
  }) async {
    final r = await _send(
      'GET',
      '/v1/publications',
      query: {
        'q': q.trim(),
        'kind': ?kind,
        if (includeWithdrawn) 'include_withdrawn': 'true',
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    return [
      for (final x in (r!['items'] as List? ?? const []))
        HubSummary.fromJson((x as Map).cast()),
    ];
  }

  /// The latest revision, or null when the hub has never seen it.
  Future<Map<String, Object?>?> publication(String origin, String id) =>
      _send('GET', '/v1/publications/$origin/$id', missingIsNull: true);

  Future<List<Map<String, Object?>>> history(String origin, String id) async {
    final r = await _send(
      'GET',
      '/v1/publications/$origin/$id/history',
      query: {'limit': '20'},
    );
    return [
      for (final x in (r!['items'] as List? ?? const []))
        (x as Map).cast<String, Object?>(),
    ];
  }

  /// Validates without writing.
  Future<void> preview(Map<String, Object?> draft) async {
    await _send('POST', '/v1/publications/preview', body: draft);
  }

  Future<Map<String, Object?>> publish(Map<String, Object?> draft) async =>
      (await _send('POST', '/v1/publications', body: draft))!;

  Future<Map<String, Object?>?> _send(
    String method,
    String path, {
    Map<String, String>? query,
    Object? body,
    bool missingIsNull = false,
  }) async {
    final uri = base.replace(path: '${base.path}$path', queryParameters: query);
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (token case final t? when t.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close().timeout(timeout);
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        bytes.addAll(chunk);
        if (bytes.length > _maxResponse) throw HubException('中心返回的数据过大');
      }
      if (missingIsNull && response.statusCode == 404) return null;
      Map<String, Object?>? json;
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map) json = decoded.cast<String, Object?>();
      } on FormatException {
        json = null;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (json == null) throw HubException('中心返回的内容无法识别，请确认地址指向公司资料中心');
        return json;
      }
      throw HubException(_failure(response.statusCode, json));
    } on HubException {
      rethrow;
    } on TimeoutException {
      throw HubException('连接公司资料中心超时，请检查网络或稍后再试');
    } on SocketException catch (e) {
      throw HubException('连不上公司资料中心（${e.osError?.message ?? e.message}）');
    } on HandshakeException {
      throw HubException('中心的 HTTPS 证书无法验证，请联系管理员');
    } on HttpException catch (e) {
      throw HubException('与中心通信失败：${e.message}');
    } finally {
      client.close(force: true);
    }
  }

  static String _failure(int status, Map<String, Object?>? json) {
    final code = json?['error'], message = json?['message'];
    return switch (status) {
      401 => '访问令牌不对或没有填写',
      403 when code == 'local_origin_required' =>
        '这个中心只接受本机访问；从其他电脑连接需要中心配置访问令牌',
      403 => '中心拒绝访问（HTTP 403）',
      404 => '中心没有这份资料',
      409 => '中心已有其他人更新的版本，请重新发布一次',
      422 => '中心拒绝了这份资料：${message ?? code ?? '格式不符合要求'}',
      413 => '资料超过中心的大小上限',
      >= 500 => '公司资料中心暂时不可用，请稍后再试',
      _ => '中心返回错误（HTTP $status）',
    };
  }
}

const _hubTypes = {
  'supplier',
  'contact',
  'product',
  'quotation',
  'project',
  'project_item',
  'inquiry',
};

/// A publication of one supplier or quotation and everything it references,
/// as the hub requires. Contacts of a supplier go only when asked for:
/// they are people's phone numbers. No change log, attachments or unrelated
/// records; at most 256 records and 1 MiB.
Map<String, Object?> buildHubPublication(
  Store store, {
  required String type,
  required String id,
  required String publicationId,
  required int revision,
  bool withdrawn = false,
  bool includeContacts = false,
}) {
  if (!['supplier', 'quotation'].contains(type)) {
    throw ArgumentError('首版只支持 supplier 或 quotation 根记录');
  }
  requireUuid(id, 'entity_id');
  requireUuid(publicationId, 'publication_id');
  if (revision < 1 || revision > 2147483647) {
    throw ArgumentError('发布版本必须为 1..2147483647');
  }
  final records = <Map<String, Object?>>[];
  final seen = <String>{};
  final pending = [(type, id)];
  if (type == 'supplier' && includeContacts) {
    for (final r in store.db.select(
      "SELECT id FROM contact WHERE deleted = 0 "
      "AND json_extract(data,'\$.supplier_id') = ? ORDER BY id",
      [id],
    )) {
      pending.add(('contact', r['id'] as String));
    }
  }
  store.db.execute('BEGIN');
  try {
    while (pending.isNotEmpty) {
      final (kind, entityId) = pending.removeLast();
      if (!seen.add('$kind:$entityId')) continue;
      if (!_hubTypes.contains(kind) || seen.length > 256) {
        throw StateError('超出首版支持的实体类型或 256 条引用上限');
      }
      final record = store.get(kind, entityId);
      if (record == null || record.deleted) {
        throw StateError('记录不存在或已删除：$kind/$entityId');
      }
      final data = validatePayload(kind, record.data);
      if (kind == 'quotation' &&
          ((data['attachment_ids'] as List?)?.isNotEmpty ?? false)) {
        throw StateError('首版暂不传输附件；不能静默丢弃此报价的附件');
      }
      if (kind == 'product' &&
          ((data['source_attachment_ids'] as List?)?.isNotEmpty ?? false)) {
        throw StateError('首版暂不传输附件；不能静默丢弃此物料的来源附件');
      }
      records.add({
        'entity_type': kind,
        'entity_id': entityId,
        'source_version': record.version,
        'data': data,
      });
      for (final ref
          in (references[kind] ?? const <String, String>{}).entries) {
        if (data[ref.key] case final String referencedId) {
          pending.add((ref.value, referencedId));
        }
      }
      for (final ref
          in (listReferences[kind] ?? const <String, String>{}).entries) {
        for (final referencedId in (data[ref.key] as List?) ?? const []) {
          pending.add((ref.value, referencedId as String));
        }
      }
    }
    records.sort(
      (a, b) => '${a['entity_type']}:${a['entity_id']}'.compareTo(
        '${b['entity_type']}:${b['entity_id']}',
      ),
    );
    final result = <String, Object?>{
      'publication_id': publicationId,
      'revision': revision,
      'withdrawn': withdrawn,
      'root': {'entity_type': type, 'entity_id': id},
      'records': records,
    };
    if (utf8.encode(jsonEncode(result)).length > 1024 * 1024) {
      throw StateError('发布内容超过首版 1 MiB 上限');
    }
    store.db.execute('COMMIT');
    return result;
  } catch (_) {
    store.db.execute('ROLLBACK');
    rethrow;
  }
}

/// What publishing one record would send, decided against the hub's
/// current copy: a record is published under its own id, so republishing
/// after an edit becomes the next revision instead of a second entry.
class HubDraft {
  HubDraft(this.draft, {required this.upToDate, required this.previous});
  final Map<String, Object?> draft;

  /// The hub already has exactly these record versions.
  final bool upToDate;

  /// The hub's latest revision, 0 when never published.
  final int previous;

  List<Map<String, Object?>> get records =>
      (draft['records']! as List).cast<Map<String, Object?>>();
}

Future<HubDraft> prepareHubPublication(
  HubClient client,
  Store store, {
  required String type,
  required String id,
  bool includeContacts = false,
}) async {
  final center = (await client.status())['center_id'];
  if (center is! String) throw HubException('中心状态缺少中心编号，请确认地址指向公司资料中心');
  final current = await client.publication(center, id);
  Map<String, Object?> build(int revision) => buildHubPublication(
    store,
    type: type,
    id: id,
    publicationId: id,
    revision: revision,
    includeContacts: includeContacts,
  );
  final previous = (current?['revision'] as int?) ?? 0;
  final fresh = build(previous + 1);
  Set<String> versions(Object? records) => {
    for (final r in (records as List? ?? const []))
      '${(r as Map)['entity_type']}:${r['entity_id']}:${r['source_version']}',
  };
  final same =
      current != null &&
      current['withdrawn'] != true &&
      versions(current['records']).length ==
          versions(fresh['records']).length &&
      versions(current['records']).containsAll(versions(fresh['records']));
  if (!same) await client.preview(fresh);
  return HubDraft(
    same ? build(previous) : fresh,
    upToDate: same,
    previous: previous,
  );
}
