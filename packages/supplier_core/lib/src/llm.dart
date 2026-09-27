import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

class LlmException implements Exception {
  LlmException(this.message);
  final String message;
  @override
  String toString() => 'LlmException: $message';
}

/// Sends one chat-completions request body and returns the decoded response.
typedef Transport =
    Future<Map<String, Object?>> Function(Map<String, Object?> body);

class LlmClient {
  LlmClient(this.config, {Transport? transport})
    : _send = transport ?? _http(config);
  final LlmConfig config;
  final Transport _send;

  /// Returns the assistant message (content and/or tool_calls).
  Future<Map<String, Object?>> complete(
    List<Map<String, Object?>> messages, {
    List<Map<String, Object?>>? tools,
    bool json = false,
    int maxTokens = 8000,
  }) async {
    final response = await _send({
      'model': config.model,
      'messages': messages,
      'max_tokens': maxTokens,
      'tools': ?tools,
      if (json) 'response_format': {'type': 'json_object'},
    });
    final choices = response['choices'];
    if (choices is! List || choices.isEmpty) {
      throw LlmException('响应缺少 choices');
    }
    final message = (choices.first as Map)['message'];
    if (message is! Map<String, Object?>) throw LlmException('响应缺少 message');
    return message;
  }

  /// JSON-mode call. DeepSeek documents occasional empty JSON content, so an
  /// empty or unparsable reply is retried once before giving up.
  Future<Map<String, Object?>> json(String system, String user) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final message = await complete([
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ], json: true);
      final content = message['content'];
      if (content is String && content.trim().isNotEmpty) {
        try {
          final decoded = jsonDecode(content);
          if (decoded is Map<String, Object?>) return decoded;
        } on FormatException {
          // retry below
        }
      }
    }
    throw LlmException('模型未返回有效的 JSON');
  }
}

Transport _http(LlmConfig config) => (body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    final request = await client
        .postUrl(Uri.parse('${config.baseUrl}/chat/completions'))
        .timeout(config.timeout);
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${config.apiKey}')
      ..contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(config.timeout);
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(config.timeout);
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
  } finally {
    client.close(force: true);
  }
};
