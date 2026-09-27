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
    if (state.lanVisible) unawaited(state.setLanVisible(true));
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
      final r = await store.inBackground(_syncJob(dir, own, seen, passphrase));
      lastSync = r;
      lastSyncError = null;
      saveSetting('sync_seen', jsonEncode(r.seen)); // also refreshes pages
    } on FormatException catch (e) {
      lastSyncError = friendlyError(e.message);
      notifyListeners();
    } catch (e) {
      lastSyncError = '$e';
      notifyListeners();
    }
  }

  // --- Local network ------------------------------------------------------
  LanNode? lan;
  String? lanError;

  /// Pushes received this session, newest first, waiting for the user.
  final incoming = <LanPush>[];
  static const _maxIncoming = 10;

  bool get lanVisible => setting('lan_visible') == '1';
  Directory get _inbox => Directory('${dataDir.path}/lan-inbox');

  /// Starts or stops announcing this device and accepting pushes.
  Future<void> setLanVisible(bool on) async {
    await lan?.stop();
    lan = null;
    lanError = null;
    incoming.clear();
    if (_inbox.existsSync()) _inbox.deleteSync(recursive: true);
    saveSetting('lan_visible', on ? '1' : null);
    if (!on) return;
    try {
      lan = await LanNode.start(
        id: deviceId,
        name: deviceName,
        inbox: _inbox,
        onPush: _received,
        onPeers: notifyListeners,
      );
    } catch (e) {
      lanError = '无法在局域网中开启：$e';
    }
    notifyListeners();
  }

  void _received(LanPush push) {
    incoming.insert(0, push);
    // Unanswered pushes from a noisy sender must not fill the disk.
    while (incoming.length > _maxIncoming) {
      dismissPush(incoming.last, notify: false);
    }
    notifyListeners();
  }

  void dismissPush(LanPush push, {bool notify = true}) {
    incoming.remove(push);
    final f = File(push.path);
    if (f.existsSync()) f.deleteSync();
    if (notify) notifyListeners();
  }

  /// Packs the chosen records (with what they need) and sends them to [to],
  /// encrypted when an exchange passphrase is set. Returns an error message.
  Future<String?> pushTo(LanPeer to, Map<String, List<String>> chosen) async {
    final node = lan;
    if (node == null) return '请先打开"局域网可见"';
    final temp = Directory('${dataDir.path}/tmp')..createSync(recursive: true);
    final path =
        '${temp.path}/push-${DateTime.now().microsecondsSinceEpoch}.siq';
    try {
      final passphrase = await exchangePassphrase();
      await store.inBackground(_shareJob(path, chosen, passphrase));
      await node.push(to, path);
      return null;
    } on LanException catch (e) {
      return e.message;
    } finally {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
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
void Function(Store) _backupJob(String dir) =>
    (s) => s.dailyBackup(dir);

Future<FolderSync> Function(Store) _syncJob(
  String dir,
  String own,
  Map<String, String> seen,
  String? passphrase,
) =>
    (s) =>
        s.syncWithFolder(dir, ownName: own, seen: seen, passphrase: passphrase);

Future<void> Function(Store) _shareJob(
  String path,
  Map<String, List<String>> chosen,
  String? passphrase,
) =>
    (s) => s.exportSelection(path, chosen, passphrase: passphrase);

/// Maps core validation messages ("field: reason") to short Chinese text.
String friendlyError(String message) {
  if (message.contains('incompatible concurrent field edits')) {
    final match = RegExp(
      r'^(quotation|product|project_item|project) (\S+) has incompatible',
    ).firstMatch(message);
    final type = switch (match?.group(1)) {
      'quotation' => '报价',
      'product' => '物料',
      'project_item' => '预算行',
      'project' => '项目',
      _ => '记录',
    };
    final id = match?.group(2);
    return '两台设备对同一$type的修改互相矛盾，导入已撤销。'
        '请核对价格口径、单位、日期或有效期后再交换。'
        '${id == null ? '' : '记录：$id'}';
  }
  const reasons = {
    'required': '必填',
    'precision exceeded': '位数超出（最多 12 位整数、6 位小数）',
    'expected unsigned decimal text': '应为不带符号的数字',
    'must be positive': '必须大于 0',
    'currency or tax mode differs from project': '币种或含税口径与项目不一致',
    'currency, tax mode or unit cannot be converted': '币种、含税口径或单位无法换算到项目预算口径',
    'clear budget and contract amount before changing project price basis':
        '已有预算行或合同金额。请先处理这些金额，再修改项目币种或含税口径',
    'must use the project price basis': '采用报价时，成本单价须使用项目税口径和预算行单位的折算价',
    'clear or reconfigure conversions when changing the base unit':
        '修改基准单位前请清空旧换算，或按新基准单位重新设置',
    'expected at most 50 conversions': '最多设置 50 条单位换算',
    'duplicate or base unit, or invalid factor': '来源单位不能重复或等于基准单位，换算数量须为正数',
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
