import 'dart:convert';
import 'dart:io';

import 'operation.dart';

const defaultBackendUrl = 'https://makar.frogville.fun';
Uri backendEndpoint(String text) {
  final endpoint = Uri.tryParse(text.trim());
  if (endpoint == null ||
      endpoint.scheme != 'https' ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      (endpoint.path.isNotEmpty && endpoint.path != '/') ||
      endpoint.hasQuery ||
      endpoint.hasFragment) {
    throw const FormatException(
      'Введите HTTPS-адрес сервера без пути и параметров.',
    );
  }
  return endpoint.replace(path: '');
}

class BackendConnection {
  final Uri endpoint;
  final String deviceId, serverId, token;
  BackendConnection(this.endpoint, this.deviceId, this.serverId, this.token) {
    backendEndpoint(endpoint.toString());
    if (!validUuid(deviceId) ||
        !validUuid(serverId) ||
        serverId == deviceId ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw const FormatException('Некорректное подключение сервера.');
    }
  }
  Map<String, Object?> toJson() => {
    'endpoint': endpoint.toString(),
    'deviceId': deviceId,
    'serverId': serverId,
    'token': token,
  };
  factory BackendConnection.decode(String text) {
    final value = jsonDecode(text) as Map<String, dynamic>;
    return BackendConnection(
      backendEndpoint(value['endpoint'] as String),
      value['deviceId'] as String,
      value['serverId'] as String,
      value['token'] as String,
    );
  }
  static Future<BackendConnection> enroll({
    required Uri endpoint,
    required String deviceId,
    required String invite,
    required String name,
    SecurityContext? trustedContext,
  }) async {
    backendEndpoint(endpoint.toString());
    if (!validUuid(deviceId) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(invite) ||
        name.trim().isEmpty ||
        name.length > 100) {
      throw const FormatException(
        'Проверьте код подключения и имя устройства.',
      );
    }
    final client = HttpClient(context: trustedContext)
      ..connectionTimeout = const Duration(seconds: 15);
    client.findProxy = (_) => 'DIRECT';
    try {
      return await (() async {
        final request = await client.postUrl(
          endpoint.replace(path: '/v1/enroll'),
        );
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.write(
          jsonEncode({
            'protocol': syncProtocolVersion,
            'deviceId': deviceId,
            'invite': invite,
            'name': name,
          }),
        );
        final response = await request.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 65536) {
            throw const FormatException('Некорректный ответ сервера.');
          }
          bytes.addAll(chunk);
        }
        final value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        if (response.statusCode != 200) {
          throw FormatException(switch (value['error']) {
            'invalid_invite' => 'Код не найден, уже использован или истёк. Создайте новый код командой invite.',
            'invalid_enrollment' => 'Сервер отклонил имя или идентификатор устройства. Проверьте имя устройства.',
            'incompatible_protocol' => 'Версии приложения и сервера несовместимы. Обновите приложение и бэкенд.',
            'invalid_data' => 'Сервер не смог прочитать данные подключения. Требуется проверка бэкенда и Nginx; срок кода может быть ни при чём.',
            'device_limit' => 'Достигнут лимит устройств на сервере. Обратитесь к владельцу сервера.',
            'busy' => 'Сервер занят. Повторите подключение позже.',
            _ =>
              'Подключение отклонено сервером (HTTP ${response.statusCode}).',
          });
        }
        if (value['protocol'] != syncProtocolVersion) {
          throw const FormatException('Несовместимая версия сервера.');
        }
        return BackendConnection(
          endpoint,
          deviceId,
          value['deviceId'] as String,
          value['token'] as String,
        );
      })().timeout(const Duration(seconds: 20));
    } finally {
      client.close(force: true);
    }
  }
}
