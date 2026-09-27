import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supplier_core/supplier_core.dart';

import 'format.dart';

/// Holds the device's store. Pages read the store directly (SQLite is
/// synchronous and local) and call [changed] after writing so every
/// listener rebuilds with fresh data.
// ponytail: one global change signal; split per-table notifiers only if
// rebuild cost ever becomes visible.
class AppState extends ChangeNotifier {
  AppState._(this.store, this.dataDir, this._settings);

  @visibleForTesting
  AppState.test(this.store, this.dataDir)
    : _settings = {'device_name': store.device};

  final Store store;
  final Directory dataDir;
  final Map<String, Object?> _settings;

  static Future<AppState> open() async {
    final dir = await getApplicationSupportDirectory();
    await dir.create(recursive: true);
    final settingsFile = File('${dir.path}/settings.json');
    final settings = settingsFile.existsSync()
        ? jsonDecode(settingsFile.readAsStringSync()) as Map<String, Object?>
        : <String, Object?>{};
    final device = settings['device_name'] as String? ?? _defaultDeviceName();
    settings['device_name'] = device;
    settingsFile.writeAsStringSync(jsonEncode(settings));
    final state = AppState._(
      Store.open('${dir.path}/supplier.db', device: device),
      dir,
      settings,
    );
    unawaited(state._backup().then((_) => state.syncNow()));
    return state;
  }

  String get backupDir => '${dataDir.path}/backups';

  /// Why today's automatic backup failed, shown in settings; null if fine.
  String? backupError;

  // Runs in the background after the window opens. A failed backup must not
  // stop the app; it is reported in settings instead.
  Future<void> _backup() async {
    final dir = backupDir;
    try {
      await store.inBackground(_backupJob(dir));
      backupError = null;
    } catch (e) {
      backupError = '$e';
    }
  }

  static String _defaultDeviceName() {
    final host = Platform.localHostname.trim();
    return host.isEmpty ? '本机' : host;
  }

  String get deviceName => _settings['device_name']! as String;

  /// Stable per installation; names this device's file in a shared folder
  /// (device names may repeat).
  String get deviceId {
    final id = setting('device_id');
    if (id != null) return id;
    final created = newUuid();
    saveSetting('device_id', created);
    return created;
  }

  // --- Shared folder sync (desktop) ---------------------------------------
  String? get syncDir => setting('sync_dir');

  String get syncFileName =>
      '询价台账-${deviceName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}-'
      '${deviceId.substring(0, 8)}.siq';

  /// Result of the last sync in this session, for the exchange page.
  FolderSync? lastSync;
  String? lastSyncError;

  // --- Exchange passphrase (secure storage, never in the database) ---
  static const _passName = 'exchange_passphrase';

  Future<String?> exchangePassphrase() async {
    try {
      final v = await _secure.read(key: _passName);
      return v == null || v.isEmpty ? null : v;
    } catch (_) {
      return null; // unavailable secure storage = no passphrase set
    }
  }

  Future<void> saveExchangePassphrase(String? value) async {
    value == null
        ? await _secure.delete(key: _passName)
        : await _secure.write(key: _passName, value: value);
    // Our shared-folder file must be rewritten in the new mode.
    saveSetting('sync_seen', null);
  }

  Future<void>? _syncing;

  /// Imports other devices' files from the shared folder and writes ours,
  /// in the background. A second call while one runs joins it.
  Future<void> syncNow() =>
      _syncing ??= _sync().whenComplete(() => _syncing = null);

  Future<void> _sync() async {
    final dir = syncDir;
    if (dir == null) return;
    try {
      final own = syncFileName, stored = setting('sync_seen');
      final Map<String, String> seen = stored == null
          ? {}
          : (jsonDecode(stored) as Map).cast<String, String>();
      final passphrase = await exchangePassphrase();
      final r = await store.inBackground(
        _syncJob(dir, own, seen, passphrase),
      );
      lastSync = r;
      lastSyncError = null;
      saveSetting('sync_seen', jsonEncode(r.seen)); // also refreshes pages
    } catch (e) {
      lastSyncError = '$e';
      notifyListeners();
    }
  }

  String? setting(String key) => _settings[key] as String?;

  void saveSetting(String key, String? value) {
    _settings[key] = value;
    File(
      '${dataDir.path}/settings.json',
    ).writeAsStringSync(jsonEncode(_settings));
    notifyListeners();
  }

  // --- AI (DeepSeek or any OpenAI-compatible endpoint) -------------------
  // The API key lives in the OS secure store (Keychain / DPAPI / Keystore),
  // never in the database, so it cannot travel inside exchange files.
  static const _keyName = 'llm_api_key';
  static const _secure = FlutterSecureStorage();

  String get aiBaseUrl => setting('ai_base_url') ?? 'https://api.deepseek.com';
  String get aiModel => setting('ai_model') ?? 'deepseek-flash';

  Future<bool> hasAiKey() async {
    try {
      return (await _secure.read(key: _keyName))?.isNotEmpty ?? false;
    } catch (_) {
      return false; // secure storage unavailable counts as "not configured"
    }
  }

  Future<void> saveAi({
    required String baseUrl,
    required String model,
    String? apiKey,
  }) async {
    if (apiKey != null) {
      apiKey.isEmpty
          ? await _secure.delete(key: _keyName)
          : await _secure.write(key: _keyName, value: apiKey);
    }
    _settings['ai_base_url'] = baseUrl;
    saveSetting('ai_model', model);
  }

  /// Null when no key is configured.
  Future<LlmClient?> llm() async {
    final String? key;
    try {
      key = await _secure.read(key: _keyName);
    } catch (e) {
      throw LlmException('无法读取系统安全存储中的 API Key（$e）');
    }
    if (key == null || key.isEmpty) return null;
    return LlmClient(
      LlmConfig(apiKey: key, baseUrl: aiBaseUrl, model: aiModel),
    );
  }

  void changed() => notifyListeners();

  /// Runs a write and refreshes listeners. Validation errors come back as a
  /// user-facing message instead of an exception.
  String? write(void Function(Store store) action) {
    try {
      action(store);
      notifyListeners();
      return null;
    } on FormatException catch (e) {
      return friendlyError(e.message);
    }
  }

  /// [write] for long work (imports) run by [Store.inBackground]; [action]
  /// must not capture the store.
  Future<String?> writeInBackground(
    FutureOr<void> Function(Store store) action,
  ) async {
    try {
      await store.inBackground(action);
      notifyListeners();
      return null;
    } on FormatException catch (e) {
      return friendlyError(e.message);
    }
  }
}

// Background jobs are built at top level so they capture only their
// arguments, never AppState (which holds the window's database handle).
void Function(Store) _backupJob(String dir) => (s) => s.dailyBackup(dir);

Future<FolderSync> Function(Store) _syncJob(
  String dir,
  String own,
  Map<String, String> seen,
  String? passphrase,
) => (s) =>
    s.syncWithFolder(dir, ownName: own, seen: seen, passphrase: passphrase);

/// Maps core validation messages ("field: reason") to short Chinese text.
String friendlyError(String message) {
  const reasons = {
    'required': '必填',
    'precision exceeded': '位数超出（最多 12 位整数、6 位小数）',
    'expected unsigned decimal text': '应为不带符号的数字',
    'must be positive': '必须大于 0',
    'currency or tax mode differs from project': '币种或含税口径与项目不一致',
    'record does not exist': '记录已被删除',
    'clearing existing information requires explicit confirmation':
        '不能直接清空已有内容',
    'standard cannot be downgraded': '标准记录不能改为历史资料',
  };
  final i = message.indexOf(': ');
  if (i < 0) return message;
  final field = message.substring(0, i);
  final reason = message.substring(i + 2);
  final label = fieldLabels[field.split('.').last] ?? field;
  return '$label：${reasons[reason] ?? reason}';
}
