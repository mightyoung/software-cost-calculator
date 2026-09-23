import 'package:supplier_core/supplier_core.dart';

enum RestoreWorkflowState {
  idle,
  preparing,
  ready,
  activating,
  completed,
  cancelled,
  failed,
}

/// Only a successfully validated, installation-owned candidate reaches the UI.
final class RestorePreview {
  const RestorePreview({
    required this.candidateId,
    required this.sourceName,
    required this.summary,
  });
  final String candidateId;
  final String sourceName;
  final BackupSummary summary;
}

/// Activation can fence the old host even when it rolls back. A recovered
/// workspace must replace it, while the original failure remains visible.
final class RestoreActivationFailure<T> implements Exception {
  const RestoreActivationFailure({
    required this.cause,
    required this.stackTrace,
    required this.activationCompleted,
    this.recoveredWorkspace,
    this.recoveryError,
  });
  final Object cause;
  final StackTrace stackTrace;
  final bool activationCompleted;
  final T? recoveredWorkspace;
  final Object? recoveryError;
  @override
  String toString() => activationCompleted
      ? '备份已切换，但重新打开资料库失败：$cause'
      : '恢复失败：$cause${recoveryError == null ? '' : '；重新打开失败：$recoveryError'}';
}

/// Two distinct calls enforce the preview/confirmation boundary. The owner
/// presents [RestorePreview] and calls [confirmAndActivate] only on confirmation.
final class RestoreWorkflow<T> {
  RestoreWorkflow({
    required this._prepare,
    required this._activate,
    required this._closeCurrent,
    required this._reopen,
  });

  final Future<RestorePreview> Function() _prepare;
  final Future<DatabaseVersion> Function(String) _activate;
  final Future<void> Function() _closeCurrent;
  final Future<T> Function() _reopen;
  RestoreWorkflowState _state = RestoreWorkflowState.idle;
  RestorePreview? _preview;
  RestoreWorkflowState get state => _state;
  RestorePreview? get preview => _preview;

  Future<RestorePreview> prepare() async {
    if (_state != RestoreWorkflowState.idle) {
      throw StateError('Restore has already started');
    }
    _state = RestoreWorkflowState.preparing;
    try {
      final result = await _prepare();
      _preview = result;
      _state = RestoreWorkflowState.ready;
      return result;
    } catch (_) {
      _state = RestoreWorkflowState.failed;
      rethrow;
    }
  }

  void cancel() {
    if (_state != RestoreWorkflowState.idle &&
        _state != RestoreWorkflowState.ready) {
      throw StateError('Cannot cancel a restore in progress');
    }
    // Retain the isolated candidate for diagnostics; never delete old libraries.
    _state = RestoreWorkflowState.cancelled;
  }

  Future<T> confirmAndActivate(RestorePreview confirmedPreview) async {
    if (_state != RestoreWorkflowState.ready ||
        !identical(confirmedPreview, _preview)) {
      throw StateError('Confirmation must match the prepared preview');
    }
    _state = RestoreWorkflowState.activating;
    try {
      await _activate(confirmedPreview.candidateId);
    } catch (error, stack) {
      _state = RestoreWorkflowState.failed;
      T? recovered;
      Object? recoveryError;
      try {
        await _closeCurrent();
        recovered = await _reopen();
      } catch (failure) {
        recoveryError = failure;
      }
      throw RestoreActivationFailure<T>(
        cause: error,
        stackTrace: stack,
        activationCompleted: false,
        recoveredWorkspace: recovered,
        recoveryError: recoveryError,
      );
    }
    try {
      await _closeCurrent();
      final workspace = await _reopen();
      _state = RestoreWorkflowState.completed;
      return workspace;
    } catch (error, stack) {
      _state = RestoreWorkflowState.failed;
      throw RestoreActivationFailure<T>(
        cause: error,
        stackTrace: stack,
        activationCompleted: true,
      );
    }
  }
}
