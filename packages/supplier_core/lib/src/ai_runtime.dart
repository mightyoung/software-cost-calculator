import 'dart:async';

class LlmException implements Exception {
  LlmException(this.message);
  final String message;
  @override
  String toString() => 'LlmException: $message';
}

enum AiTask {
  conversation,
  offerExtraction,
  listProposal,
  clauseReading,
  parameterExtraction,
}

/// Cancellation belongs to a whole business task, including retries and batches.
class AiCancellation {
  final _done = Completer<void>();
  final _listeners = <void Function()>{};
  String _reason = '已停止 AI 任务';
  bool get isCancelled => _done.isCompleted;

  void cancel([String reason = '已停止 AI 任务']) {
    if (isCancelled) return;
    _reason = reason;
    _done.complete();
    for (final listener in _listeners.toList()) listener();
    _listeners.clear();
  }

  void check() {
    if (isCancelled) throw LlmException(_reason);
  }

  void Function() onCancel(void Function() listener) {
    if (isCancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
    return () => _listeners.remove(listener);
  }

  Future<T> wait<T>(Future<T> work) => Future.any([
    work,
    _done.future.then<T>((_) => throw LlmException(_reason)),
  ]);
}

class AiLimits {
  const AiLimits({
    this.maxCalls = 24,
    this.timeout = const Duration(minutes: 3),
    this.maxRequestChars = 100000,
    this.maxResponseChars = 128000,
  });
  final int maxCalls, maxRequestChars, maxResponseChars;
  final Duration timeout;
}

/// Local metadata only: excludes prompts, outputs, API keys and hidden reasoning.
class AiCallEvent {
  const AiCallEvent(this.task, this.call, this.elapsed, this.receivedResponse);
  final AiTask task;
  final int call;
  final Duration elapsed;

  /// A provider response is not proof that the domain output was accepted.
  final bool receivedResponse;
}

/// One bounded run shared by every model call in a business operation.
class AiRun {
  AiRun(
    this.task, {
    this.limits = const AiLimits(),
    AiCancellation? cancellation,
    this.onCall,
  }) : cancellation = cancellation ?? AiCancellation();
  final AiTask task;
  final AiLimits limits;
  final AiCancellation cancellation;
  final void Function(AiCallEvent)? onCall;
  final _watch = Stopwatch()..start();
  var calls = 0;

  static void validateInput(String text) {
    if (text.length > 60000) throw LlmException('输入超过 60000 字符，请分批处理');
  }

  void check() {
    cancellation.check();
    if (_watch.elapsed >= limits.timeout) {
      cancellation.cancel('AI 任务超时，请分批处理或缩小范围');
      cancellation.check();
    }
  }

  Future<T> call<T>(
    Future<T> Function() send, {
    required int requestChars,
  }) async {
    check();
    if (calls >= limits.maxCalls) throw LlmException('AI 调用预算已用完，请分批处理');
    if (requestChars > limits.maxRequestChars)
      throw LlmException('AI 请求过大，请缩小范围');
    final number = ++calls;
    final watch = Stopwatch()..start();
    var received = false;
    try {
      final result = await cancellation.wait(
        send().timeout(
          limits.timeout - _watch.elapsed,
          onTimeout: () {
            cancellation.cancel('AI 任务超时，请分批处理或缩小范围');
            throw LlmException('AI 任务超时，请分批处理或缩小范围');
          },
        ),
      );
      check();
      received = true;
      return result;
    } finally {
      // Optional telemetry must not turn a valid task into an application error.
      try {
        onCall?.call(AiCallEvent(task, number, watch.elapsed, received));
      } catch (_) {
        // Observers own reporting failures; no payload is logged here.
      }
    }
  }
}
