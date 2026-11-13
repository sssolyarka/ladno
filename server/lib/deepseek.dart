import 'dart:async';
import 'dart:convert';
import 'dart:io';

class DeepSeekFailure implements Exception {
  final int status;
  final String code;
  const DeepSeekFailure(this.status, this.code);
}

/// One in-flight request and ten requests per minute across this workspace.
/// Credentials, prompts and upstream error bodies are never logged or persisted.
class DeepSeek {
  final String _key;
  final HttpClient Function() _client;
  final Uri _endpoint;
  final List<DateTime> _recent = [];
  bool _busy = false;
  DeepSeek(String key, {HttpClient Function()? client, Uri? endpoint})
    : _key = key,
      _client = client ?? HttpClient.new,
      _endpoint =
          endpoint ?? Uri.parse('https://api.deepseek.com/chat/completions');

  Future<String> ask(String prompt) async {
    final now = DateTime.now();
    _recent.removeWhere(
      (at) => now.difference(at) >= const Duration(minutes: 1),
    );
    if (_busy || _recent.length >= 10) {
      throw const DeepSeekFailure(429, 'ai_rate_limit');
    }
    _busy = true;
    _recent.add(now);
    final client = _client()..connectionTimeout = const Duration(seconds: 15);
    try {
      return await (() async {
        final request = await client.postUrl(_endpoint);
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.headers.set('authorization', 'Bearer $_key');
        request.write(
          jsonEncode({
            'model': 'deepseek-flash',
            'thinking': {'type': 'disabled'},
            'max_tokens': 2048,
            'stream': false,
            'messages': [
              {
                'role': 'system',
                'content': 'Ты помощник в приложении Ладно. Отвечай по-русски кратко и ясно. Помогай с заметками и планами. У тебя нет доступа к данным приложения или инструментам. Не утверждай, что изменил записи.',
              },
              {'role': 'user', 'content': prompt},
            ],
          }),
        );
        final response = await request.close();
        if (response.statusCode != 200) {
          throw DeepSeekFailure(502, switch (response.statusCode) {
            401 || 403 => 'ai_key_rejected',
            402 => 'ai_balance',
            429 => 'ai_provider_limit',
            _ => 'ai_unavailable',
          });
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 262144) {
            throw const DeepSeekFailure(502, 'ai_invalid_response');
          }
          bytes.addAll(chunk);
        }
        final value = jsonDecode(utf8.decode(bytes));
        final answer = value['choices'][0]['message']['content'];
        if (answer is! String ||
            answer.trim().isEmpty ||
            answer.length > 64000) {
          throw const DeepSeekFailure(502, 'ai_invalid_response');
        }
        return answer;
      })().timeout(const Duration(seconds: 60));
    } on DeepSeekFailure {
      rethrow;
    } catch (_) {
      throw const DeepSeekFailure(502, 'ai_unavailable');
    } finally {
      _busy = false;
      client.close(force: true);
    }
  }
}
