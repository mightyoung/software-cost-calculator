import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import 'agent_tools.dart';
import 'search_index.dart';
import 'store.dart';

/// MCP protocol versions this server speaks, newest first.
const mcpVersions = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];
const _guideUri = 'siq://guide';

/// A Model Context Protocol server over the [agentTools]: JSON-RPC 2.0
/// messages, one per line on stdin/stdout. Everything it offers is
/// read-only; the database itself is opened read-only by [openReadOnly].
class McpServer {
  McpServer(this.store, {this.version = '0.0.0'});
  final Store store;
  final String version;

  /// Answers one incoming line; null for notifications.
  String? handleLine(String line) {
    final Object? message;
    try {
      message = jsonDecode(line);
    } on FormatException {
      return _error(null, -32700, 'Parse error');
    }
    if (message is! Map<String, Object?> || message['jsonrpc'] != '2.0') {
      return _error(null, -32600, 'Invalid request');
    }
    final id = message['id'];
    final method = message['method'];
    if (method is! String) return _error(id, -32600, 'Invalid request');
    if (id == null) return null; // notifications need no answer
    final params = message['params'] is Map<String, Object?>
        ? message['params']! as Map<String, Object?>
        : const <String, Object?>{};
    return switch (method) {
      'initialize' => _result(id, _initialize(params)),
      'ping' => _result(id, const {}),
      'tools/list' => _result(id, {
        'tools': [
          for (final t in agentTools)
            {
              'name': (t['function']! as Map)['name'],
              'description': (t['function']! as Map)['description'],
              'inputSchema': (t['function']! as Map)['parameters'],
              'annotations': {'readOnlyHint': true, 'openWorldHint': false},
            },
        ],
      }),
      'tools/call' => _call(id, params),
      'resources/list' => _result(id, {
        'resources': [
          {
            'uri': _guideUri,
            'name': 'guide',
            'title': '询价台账数据说明',
            'description': '数据模型、关系、规则和工具说明',
            'mimeType': 'text/markdown',
          },
        ],
      }),
      'resources/read' =>
        params['uri'] == _guideUri
            ? _result(id, {
                'contents': [
                  {
                    'uri': _guideUri,
                    'mimeType': 'text/markdown',
                    'text': agentGuide(),
                  },
                ],
              })
            : _error(id, -32002, 'Resource not found'),
      _ => _error(id, -32601, 'Method not found: $method'),
    };
  }

  Map<String, Object?> _initialize(Map<String, Object?> params) {
    final asked = params['protocolVersion'];
    return {
      'protocolVersion': mcpVersions.contains(asked)
          ? asked
          : mcpVersions.first,
      'capabilities': {
        'tools': {'listChanged': false},
        'resources': {'listChanged': false},
      },
      'serverInfo': {
        'name': 'xunjia-ledger',
        'title': '询价台账',
        'version': version,
      },
      'instructions':
          '只读访问本机询价台账（供应商、物料、报价、项目预算、询价单）。'
          '先读资源 $_guideUri 或调用 describe 了解数据模型；'
          '用 search 找到记录 id，再用 get/query/related 或比价、预算工具。'
          '金额是精确十进制文本，原样引用。',
    };
  }

  String _call(Object id, Map<String, Object?> params) {
    final name = params['name'];
    if (name is! String) return _error(id, -32602, 'Missing tool name');
    final text = store.runTool(name, jsonEncode(params['arguments'] ?? {}));
    final decoded = jsonDecode(text);
    return _result(id, {
      'content': [
        {'type': 'text', 'text': text},
      ],
      'isError': decoded is Map && decoded.containsKey('error'),
    });
  }

  static String _result(Object id, Object result) =>
      jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result});

  static String _error(Object? id, int code, String message) => jsonEncode({
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  });

  /// Serves stdin/stdout until stdin closes. Output is UTF-8 whatever the
  /// console code page.
  Future<void> serve() async {
    await for (final line
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      final reply = handleLine(line);
      if (reply != null) stdout.add(utf8.encode('$reply\n'));
    }
  }
}

/// Opens the app's database without any possibility of writing: read-only
/// mode plus query_only. Refuses a schema other than this build's, since
/// migrating needs the app.
Store openReadOnly(String path) {
  if (!File(path).existsSync()) {
    throw StateError('找不到数据库：$path');
  }
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    db.execute('PRAGMA query_only = 1');
    db.execute('PRAGMA busy_timeout = 5000');
    final rows = db.select(
      "SELECT value FROM meta WHERE key = 'schema_version'",
    );
    final v = rows.isEmpty ? 0 : int.tryParse(rows.first['value'] as String);
    if (v != schemaVersion) {
      throw StateError(
        (v ?? 0) < schemaVersion
            ? '数据库版本较旧（$v），请先用新版询价台账打开一次完成升级'
            : '数据库来自更新版本的询价台账（$v），请更新 siq-mcp',
      );
    }
    registerFunctions(db);
  } catch (_) {
    db.close();
    rethrow;
  }
  return Store(db, device: 'mcp');
}

/// Where the app keeps its database on this computer.
String? defaultDatabasePath() {
  final env = Platform.environment;
  if (Platform.isMacOS) {
    const id = 'com.mightyoung.supplierApp';
    return '${env['HOME']}/Library/Containers/$id/Data/Library/'
        'Application Support/$id/supplier.db';
  }
  if (Platform.isWindows) {
    return '${env['APPDATA']}\\com.mightyoung\\supplier_app\\supplier.db';
  }
  return null;
}
