import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supplier_core/supplier_core.dart';

import 'errors.dart';

export 'errors.dart' show friendlyError;

const assistantDomesticCriteria = {
  'unspecified': '国产口径待明确',
  'manufacture': '国产指中国制造',
  'brand': '国产指国产品牌',
};

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
  AiJobStore? _aiJobs;
  bool _restoring = false;
  bool _disposed = false;

  AiJobStore get _jobs =>
      _aiJobs ??= AiJobStore.open('${dataDir.path}/ai-jobs.sqlite');

  List<AiJob> get aiTasks {
    final jobs = _jobs.jobs;
    for (final job in jobs) {
      if (job.status == 'ready' &&
          job.epoch == _jobs.epoch &&
          _hasAiReceipt(job.id)) {
        _jobs.finish(job.id);
      }
    }
    return _jobs.jobs;
  }

  AiJob aiTask(String id) => _jobs.get(id);
  bool _hasAiReceipt(String id) => store.db.select(
    'SELECT 1 FROM meta WHERE key=?',
    ['ai_applied:$id'],
  ).isNotEmpty;

  Future<T> runAiTask<T>(
    AiTask task,
    Map<String, Object?> input,
    Future<T> Function(LlmClient) action, {
    String? resumeId,
    AiCancellation? cancellation,
    void Function(String)? onCreated,
  }) async {
    if (_disposed || _restoring) throw LlmException('资料库当前不可用，请稍后开始AI任务');
    final client = await llm();
    cancellation?.check();
    if (_disposed || _restoring) throw LlmException('资料库当前不可用，请稍后开始AI任务');
    if (client == null) throw LlmException('还没有配置 AI 服务，请在设置中填写 API Key');
    final job = resumeId == null
        ? _jobs.create(task, input)
        : _jobs.get(resumeId);
    if (job.task != task || jsonEncode(job.input) != jsonEncode(input)) {
      throw LlmException('任务输入已变化，请以新输入开始，不可套用旧检查点');
    }
    if (_hasAiReceipt(job.id)) throw LlmException('此任务已经确认入库，不能重复执行');
    final session = _jobs.start(job.id, cancellation: cancellation);
    try {
      onCreated?.call(job.id);
      notifyListeners();
      final result = await action(client.withCheckpoint(session));
      session.check();
      session.ready();
      return result;
    } catch (_) {
      // Provider errors may contain private request text: retain a generic state,
      // while the page reports the original actionable error for this attempt.
      session.pause('任务未完成，已保存成功步骤；可继续');
      rethrow;
    } finally {
      if (!_disposed) notifyListeners();
    }
  }

  void validateAiTask(String id) {
    if (_restoring) throw LlmException('资料库正在恢复，旧AI结果不能应用');
    if (_hasAiReceipt(id)) throw LlmException('此任务已经确认入库');
    _jobs.validate(id);
  }

  void finishAiTask(String id) {
    _jobs.finish(id);
    notifyListeners();
  }

  void discardAiTask(String id) {
    _jobs.discard(id);
    notifyListeners();
  }

  /// Business changes and the opaque apply receipt commit in one transaction.
  /// A crash before the local task status update cannot apply the draft twice.
  void commitAiTask(String? id, void Function(Store) action) {
    if (id == null) {
      action(store);
      return;
    }
    try {
      validateAiTask(id);
    } on LlmException catch (e) {
      throw FormatException(e.message);
    }
    store.transaction(() {
      if (_hasAiReceipt(id)) throw const FormatException('该任务已经确认，请查看现有记录');
      action(store);
      store.db.execute('INSERT INTO meta(key,value) VALUES(?,?)', [
        'ai_applied:$id',
        _jobs.epoch,
      ]);
    });
    try {
      _jobs.finish(id);
    } catch (_) {
      // The business receipt is authoritative. aiTasks reconciles this after a
      // restart; never replay a successful write because task storage failed.
    }
  }

  void finishRestore() {
    _restoring = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _aiJobs?.close();
    super.dispose();
  }

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
      throw const FormatException('无法读取系统安全存储中的交换口令；请恢复安全存储后重试');
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
    _restoring = true;
    _jobs.invalidateAll();
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
      if (passphrase == null) return '请先在交换页面设置交换口令，再发送局域网推送';
      await store.inBackground(_shareJob(path, chosen, passphrase));
      await node.push(to, path);
      return null;
    } on LanException catch (e) {
      return e.message;
    } on FormatException catch (e) {
      return e.message;
    } catch (e) {
      return '发送失败：$e';
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

  bool get assistantWebEnabled => setting('assistant_web') == '1';
  set assistantWebEnabled(bool value) =>
      saveSetting('assistant_web', value ? '1' : null);

  AssistantPermission get assistantPermission =>
      setting('assistant_permission') == 'readOnly'
      ? AssistantPermission.readOnly
      : AssistantPermission.confirmWrites;
  set assistantPermission(AssistantPermission value) =>
      saveSetting('assistant_permission', value.name);

  String? get assistantDomesticCriterion {
    final value = setting('assistant_domestic_criterion');
    return value == 'manufacture' || value == 'brand' ? value : null;
  }

  set assistantDomesticCriterion(String? value) {
    if (value != null && value != 'manufacture' && value != 'brand') {
      throw ArgumentError.value(value, 'domesticCriterion');
    }
    saveSetting('assistant_domestic_criterion', value);
  }

  String _webCacheKey(String id) => 'assistant_web_sources:${jsonEncode(id)}';

  /// A host-owned factory also gives UI tests a bounded transport seam.
  AssistantWebTools createAssistantWebTools(String jobId) => AssistantWebTools(
    restoredSnapshots: assistantWebSnapshots(jobId),
    onSnapshot: (source) => saveAssistantWebSnapshot(jobId, source),
  );

  List<AssistantWebSnapshot> assistantWebSnapshots(String jobId) {
    validateAssistantSession(jobId);
    final rows = store.db.select('SELECT value FROM meta WHERE key=?', [
      _webCacheKey(jobId),
    ]);
    if (rows.isEmpty) return const [];
    try {
      final text = rows.single['value'] as String;
      if (text.length > 1024 * 1024 || utf8.encode(text).length > 1024 * 1024) {
        throw const FormatException('Source cache exceeds task budget');
      }
      final decoded = jsonDecode(text);
      if (decoded is! List || decoded.length > 8) {
        throw const FormatException('Invalid source cache shape');
      }
      return [
        for (final row in decoded)
          AssistantWebSnapshot.fromJson((row as Map).cast<String, Object?>()),
      ];
    } on FormatException {
      throw LlmException('任务网页来源缓存损坏或超限，不能恢复该任务。请重新开始采购研究。');
    } on TypeError {
      throw LlmException('任务网页来源缓存结构损坏，不能恢复该任务。请重新开始采购研究。');
    }
  }

  void saveAssistantWebSnapshot(String jobId, AssistantWebSnapshot source) {
    validateAssistantSession(jobId);
    final prior = assistantWebSnapshots(jobId);
    final sources = [...prior.where((s) => s.id != source.id), source];
    final encoded = jsonEncode([
      for (final s in sources.skip(sources.length > 8 ? sources.length - 8 : 0))
        s.toJson(),
    ]);
    if (utf8.encode(encoded).length > 1024 * 1024) {
      throw LlmException('本任务网页证据超过1MiB，请分批研究');
    }
    store.db.execute(
      'INSERT INTO meta(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      [_webCacheKey(jobId), encoded],
    );
  }

  void clearAssistantWebSnapshots(String jobId) =>
      store.db.execute('DELETE FROM meta WHERE key=?', [_webCacheKey(jobId)]);

  /// Conversation actions validate a running job, rather than a ready draft.
  void validateAssistantSession(String id) {
    if (_disposed || _restoring) throw LlmException('资料库当前不可用，操作已停止');
    final job = _jobs.get(id);
    if (job.epoch != _jobs.epoch || job.status != 'running') {
      throw LlmException('任务已经失效，请重新开始并确认操作');
    }
  }

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

  // --- Company hub (optional) --------------------------------------------
  // Like the AI key, the hub token stays in the OS secure store.
  static const _hubTokenName = 'hub_api_token';

  String? get hubAddress => setting('hub_address');

  Future<bool> hasHubToken() async {
    try {
      return (await _secure.read(key: _hubTokenName))?.isNotEmpty ?? false;
    } catch (_) {
      return false;
    }
  }

  /// [token] null keeps the saved one, empty deletes it.
  Future<void> saveHub({required String? address, String? token}) async {
    if (token != null) {
      token.isEmpty
          ? await _secure.delete(key: _hubTokenName)
          : await _secure.write(key: _hubTokenName, value: token);
    }
    saveSetting('hub_address', address);
  }

  /// Null when no hub is configured.
  Future<HubClient?> hub() async {
    final address = hubAddress;
    if (address == null) return null;
    final String? token;
    try {
      token = await _secure.read(key: _hubTokenName);
    } catch (e) {
      throw HubException('无法读取系统安全存储中的中心访问令牌（$e）');
    }
    return HubClient(parseHubAddress(address), token: token);
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
