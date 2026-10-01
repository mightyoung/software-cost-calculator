import 'ai_runtime.dart';

/// Optional capabilities are supplied by the application, never by the model.
abstract interface class AssistantToolset {
  List<Map<String, Object?>> get tools;

  Future<String> execute(
    String name,
    Map<String, Object?> arguments, {
    required String callId,
    required AiCancellation cancellation,
  });
}
