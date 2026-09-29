import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_runtime.dart';
export 'ai_runtime.dart';

/// OpenAI-compatible chat endpoint; DeepSeek by default. Model names change
/// between DeepSeek releases, so both are settings, not constants.
class LlmConfig {
  const LlmConfig({
    required this.apiKey,
    this.baseUrl = 'https://api.deepseek.com',
    this.model = 'deepseek-flash',
    this.timeout = const Duration(seconds: 120),
  });
  final String apiKey, baseUrl, model;
  final Duration timeout;
}

/// Sends one chat-completions request body and returns the decoded response.
typedef Transport =
    Future<Map<String, Object?>> Function(Map<String, Object?> body);

class LlmClient {
  LlmClient(this.config, {Transport? transport, this.run})
    : _transport = transport;
  final LlmConfig config;
  final Transport? _transport;
  final AiRun? run;

  LlmClient forTask(
    AiTask task, {
    AiCancellation? cancellation,
    AiLimits limits = const AiLimits(),
  }) {
    if (run != null) {
      if (cancellation != null && !identical(cancellation, run!.cancellation)) {
        throw LlmException('同一 AI 任务必须使用同一个取消器');
      }
      return this;
    }
    return LlmClient(
      config,
      transport: _transport,
      run: AiRun(task, cancellation: cancellation, limits: limits),
    );
  }

  /// Returns the assistant message (content and/or tool_calls).
  Future<Map<String, Object?>> complete(
    List<Map<String, Object?>> messages, {
    List<Map<String, Object?>>? tools,
    bool json = false,
    int maxTokens = 8000,
  }) async {
    final body = <String, Object?>{
      'model': config.model,
      'messages': messages,
      'max_tokens': maxTokens,
      'tools': ?tools,
      if (json) 'response_format': {'type': 'json_object'},
    };
    Future<Map<String, Object?>> send() async {
      final result = await (_transport ?? _http(config, run))(body);
      if (jsonEncode(result).length >
          (run?.limits.maxResponseChars ?? 128000)) {
        throw LlmException('AI 响应过大，请分批处理');
      }
      return result;
    }

    final response = run == null
        ? await send()
        : await run!.call(send, requestChars: jsonEncode(body).length);
    final choices = response['choices'];
    if (choices is! List || choices.isEmpty) {
      throw LlmException('响应缺少 choices');
    }
    final choice = choices.first;
    if (choice is! Map) throw LlmException('响应 choices 格式无效');
    if (choice['finish_reason'] == 'length') {
      throw LlmException('模型输出被长度限制截断，请缩小输入范围后重试');
    }
    final message = choice['message'];
    if (message is! Map<String, Object?>) throw LlmException('响应缺少 message');
    if (message['content'] != null && message['content'] is! String) {
      throw LlmException('响应 content 格式无效');
    }
    return message;
  }

  /// JSON-mode call. DeepSeek documents occasional empty JSON content, so an
  /// empty or unparsable reply is retried once before giving up.
  Future<Map<String, Object?>> json(
    String system,
    String user, {
    bool Function(Map<String, Object?>)? validate,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final message = await complete([
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ], json: true);
      final content = message['content'];
      if (content is String && content.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(content);
          if (decoded is Map<String, Object?> &&
              (validate == null || validate(decoded)))
            return decoded;
        } on FormatException {
          // retry below
        }
      }
    }
    throw LlmException('模型未返回符合任务结构的 JSON，请重试或缩小范围');
  }

  Future<List<Map<String, Object?>>> records(
    String system,
    String user, {
    required String key,
    required bool Function(Map<String, Object?>) validate,
    int maxRecords = 200,
  }) async {
    final result = await json(
      system,
      user,
      validate: (value) {
        final rows = value[key];
        return rows is List &&
            rows.length <= maxRecords &&
            rows.every((row) => row is Map<String, Object?> && validate(row));
      },
    );
    return (result[key] as List).cast<Map<String, Object?>>();
  }
}

Transport _http(LlmConfig config, AiRun? run) => (body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  final unregister = run?.cancellation.onCancel(
    () => client.close(force: true),
  );
  try {
    final request = await client
        .postUrl(Uri.parse('${config.baseUrl}/chat/completions'))
        .timeout(config.timeout);
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}')
      ..contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(config.timeout);
    final buffer = StringBuffer();
    await for (final part
        in response.transform(utf8.decoder).timeout(config.timeout)) {
      buffer.write(part);
      if (buffer.length > (run?.limits.maxResponseChars ?? 128000)) {
        throw LlmException('AI 响应过大，请分批处理');
      }
    }
    final text = buffer.toString();
    if (response.statusCode != 200) {
      final brief = text.length > 300 ? '${text.substring(0, 300)}…' : text;
      throw LlmException(switch (response.statusCode) {
        401 || 403 => 'API Key 无效或没有权限（HTTP ${response.statusCode}）',
        402 => '账户余额不足（HTTP 402）',
        404 => '服务地址或模型名称不对（HTTP 404）',
        429 => '请求太频繁或额度已用完，请稍后再试（HTTP 429）',
        >= 500 => 'AI 服务暂时不可用，请稍后再试（HTTP ${response.statusCode}）',
        _ => 'HTTP ${response.statusCode}: $brief',
      });
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?>) throw LlmException('响应不是 JSON 对象');
    return decoded;
  } on TimeoutException {
    throw LlmException('请求超时');
  } on SocketException catch (e) {
    throw LlmException('网络不可用：${e.message}');
  } on HandshakeException catch (e) {
    throw LlmException('TLS 握手失败：${e.message}');
  } on FormatException {
    throw LlmException('AI 服务返回了无效的 JSON');
  } finally {
    unregister?.call();
    client.close(force: true);
  }
};
