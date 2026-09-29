import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supplier_core/supplier_core.dart';

import 'errors.dart';

export 'errors.dart' show friendlyError;

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
  final _pendingBackgroundWrites = <Future<void>>{};

  /// Imports other devices' files from the shared folder and writes ours,
  /// in the background. A second call while one runs joins it.
  Future<void> syncNow() =>
      _syncing ??= _sync().whenComplete(() => _syncing = null);

  /// Stop folder sync before replacing the library. A sync already in flight
  /// must finish first, or it could merge newer records into the restored DB.
  Future<void> suspendSyncForRestore() async {
    saveSetting('sync_dir', null);
    await _syncing;
    await Future.wait(_pendingBackgroundWrites.toList());
    saveSetting('sync_seen', null);
    lastSync = null;
    lastSyncError = null;
    notifyListeners();
  }

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

  /// Technical requirements may be sent to the AI service (off by default:
  /// requirements can be confidential; a local model is an option).
  bool get specAi => setting('spec_ai') == '1';
  set specAi(bool on) => saveSetting('spec_ai', on ? '1' : null);

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
    final pending = Completer<void>();
    _pendingBackgroundWrites.add(pending.future);
    try {
      await store.inBackground(action);
      notifyListeners();
      return null;
    } on FormatException catch (e) {
      return friendlyError(e.message);
    } finally {
      _pendingBackgroundWrites.remove(pending.future);
      pending.complete();
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
