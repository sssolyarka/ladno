import 'dart:convert';
import 'dart:io';

import 'backend_connection.dart';
import 'operation.dart';

Future<Map<String, dynamic>> aiRequest(
  BackendConnection connection,
  String route, {
  String? prompt,
  SecurityContext? trustedContext,
}) async {
  final client = HttpClient(context: trustedContext)
    ..connectionTimeout = const Duration(seconds: 15);
  client.findProxy = (_) => 'DIRECT';
  try {
    return await (() async {
      final request = await client.postUrl(
        connection.endpoint.replace(path: route),
      );
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set('authorization', 'Bearer ${connection.token}');
      request.headers.set('x-ladno-device-id', connection.deviceId);
      request.write(
        jsonEncode({'protocol': syncProtocolVersion, 'prompt': ?prompt}),
      );
      final response = await request.close();
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 262144) {
          throw const FormatException('Ответ сервера слишком большой.');
        }
        bytes.addAll(chunk);
      }
      final value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (response.statusCode != 200) {
        throw FormatException(switch (value['error']) {
          'unauthorized' =>
            'Устройство не авторизовано. Подключите сервер заново.',
          'ai_not_configured' => 'На сервере ещё не настроен ключ DeepSeek.',
          'ai_key_rejected' => 'DeepSeek отклонил серверный API-ключ.',
          'ai_balance' => 'На аккаунте DeepSeek недостаточно средств.',
          'ai_rate_limit' || 'ai_provider_limit' =>
            'Слишком много запросов. Попробуйте через минуту.',
          'not_found' => 'Обновите бэкенд: модуль DeepSeek пока недоступен.',
          _ => 'DeepSeek сейчас недоступен. Попробуйте позже.',
        });
      }
      if (value['protocol'] != syncProtocolVersion ||
          value['deviceId'] != connection.serverId) {
        throw const FormatException(
          'Ответ другого сервера. Проверьте подключение.',
        );
      }
      return value;
    })().timeout(const Duration(seconds: 70));
  } finally {
    client.close(force: true);
  }
}
