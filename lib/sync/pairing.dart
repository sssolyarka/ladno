import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'tls_transport.dart';

String randomToken() =>
    base64UrlEncode(List.generate(32, (_) => Random.secure().nextInt(256)));
Uri checkedEndpoint(Object? value) {
  final uri = value is String ? Uri.tryParse(value) : null;
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      !{'', '/'}.contains(uri.path) ||
      uri.port < 1) {
    throw const FormatException('Некорректный адрес подключения.');
  }
  return uri;
}

class PairedDevice {
  final PeerCertificate certificate;
  final String name;
  final Uri endpoint;
  PairedDevice(this.certificate, String name, this.endpoint)
    : name = name.trim() {
    checkedEndpoint(endpoint.toString());
    if (this.name.isEmpty || this.name.length > 100) {
      throw const FormatException('Некорректное имя устройства.');
    }
  }
  Map<String, Object?> toJson() => {
    'id': certificate.deviceId,
    'pem': certificate.certificatePem,
    'name': name,
    'endpoint': endpoint.toString(),
  };
  factory PairedDevice.fromJson(dynamic value) {
    if (value is! Map ||
        value['id'] is! String ||
        value['pem'] is! String ||
        value['name'] is! String) {
      throw const FormatException('Некорректное устройство.');
    }
    return PairedDevice(
      PeerCertificate(value['id'] as String, value['pem'] as String),
      value['name'] as String,
      checkedEndpoint(value['endpoint']),
    );
  }
}

class PairInvitation {
  final PairedDevice device;
  final Uri pairingEndpoint;
  final String token;
  PairInvitation(this.device, this.pairingEndpoint, this.token) {
    checkedEndpoint(pairingEndpoint.toString());
    if (!RegExp(r'^[A-Za-z0-9_-]{43}=$').hasMatch(token)) {
      throw const FormatException('Некорректный временный код.');
    }
  }
  String encode() =>
      'ladno-pair:${base64UrlEncode(utf8.encode(jsonEncode({'version': 1, 'device': device.toJson(), 'pairing': pairingEndpoint.toString(), 'token': token})))}';
  factory PairInvitation.decode(String text) {
    if (text.length > 16384 || !text.startsWith('ladno-pair:')) {
      throw const FormatException('Это не код подключения Ладно.');
    }
    try {
      final value = jsonDecode(
        utf8.decode(base64Url.decode(text.substring(11))),
      );
      if (value is! Map || value['version'] != 1 || value['token'] is! String) {
        throw const FormatException('Несовместимый код подключения.');
      }
      return PairInvitation(
        PairedDevice.fromJson(value['device']),
        checkedEndpoint(value['pairing']),
        value['token'] as String,
      );
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Код подключения повреждён.');
    }
  }
}

String verificationCode(
  PairInvitation invitation,
  PairedDevice client,
  String ticket,
) {
  final fingerprints = [
    invitation.device.certificate.fingerprint,
    client.certificate.fingerprint,
  ]..sort();
  final hash = sha256
      .convert(
        utf8.encode(jsonEncode([invitation.token, ticket, ...fingerprints])),
      )
      .bytes;
  return (ByteData.sublistView(Uint8List.fromList(hash)).getUint32(0) % 1000000)
      .toString()
      .padLeft(6, '0');
}

Future<Map<String, dynamic>> readPairJson(Stream<List<int>> stream) async {
  final data = BytesBuilder(copy: false);
  await for (final bytes in stream.timeout(const Duration(seconds: 5))) {
    if (data.length + bytes.length > 32768) {
      throw const FormatException('Сообщение подключения слишком большое.');
    }
    data.add(bytes);
  }
  final value = jsonDecode(utf8.decode(data.takeBytes()));
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Некорректное сообщение подключения.');
  }
  return value;
}

class PendingPair {
  final PairedDevice device;
  final String ticket, code;
  bool localApproved = false, remoteApproved = false, completed = false;
  PendingPair(this.device, this.ticket, this.code);
}

/// Separate, short-lived TLS service. It never has access to notes or files.
class PairingServer {
  final TlsIdentity identity;
  final PairedDevice self;
  final Future<void> Function(PairedDevice) onPaired;
  final void Function() onChanged;
  final String token = randomToken();
  final Stopwatch _age = Stopwatch()..start();
  final Duration lifetime;
  late HttpServer _http;
  PendingPair? pending;
  bool _closed = false, _saving = false;
  int _active = 0;
  PairingServer._(
    this.identity,
    this.self,
    this.onPaired,
    this.onChanged,
    this.lifetime,
  );
  int get port => _http.port;
  bool get expired => _closed || _age.elapsed > lifetime;
  PairInvitation invitation(String host) => PairInvitation(
    PairedDevice(
      self.certificate,
      self.name,
      self.endpoint.replace(host: host),
    ),
    Uri(scheme: 'https', host: host, port: port),
    token,
  );
  static Future<PairingServer> start({
    required TlsIdentity identity,
    required PairedDevice self,
    required Future<void> Function(PairedDevice) onPaired,
    void Function()? onChanged,
    InternetAddress? address,
    Duration lifetime = const Duration(minutes: 2),
  }) async {
    final server = PairingServer._(
      identity,
      self,
      onPaired,
      onChanged ?? () {},
      lifetime,
    );
    server._http = await HttpServer.bindSecure(
      address ?? InternetAddress.anyIPv4,
      0,
      identity.createContext(),
    );
    server._http.idleTimeout = const Duration(seconds: 5);
    server._http.listen(
      (r) => unawaited(server._handle(r)),
      onError: (Object _) {},
    );
    return server;
  }

  Future<void> approve() async {
    if (expired || pending == null) {
      throw const FormatException('Подключение истекло.');
    }
    pending!.localApproved = true;
    await _finish();
    onChanged();
  }

  Future<void> _finish() async {
    final pair = pending;
    if (expired ||
        pair == null ||
        !pair.localApproved ||
        !pair.remoteApproved ||
        pair.completed ||
        _saving) {
      return;
    }
    _saving = true;
    try {
      await onPaired(pair.device);
      pair.completed = true;
    } finally {
      _saving = false;
    }
  }

  Future<void> _handle(HttpRequest request) async {
    var counted = false;
    try {
      if (expired ||
          _active >= 4 ||
          request.method != 'POST' ||
          request.uri.hasQuery ||
          request.contentLength > 32768) {
        throw const FormatException('Отказ подключения.');
      }
      _active++;
      counted = true;
      final input = await readPairJson(request)
          .timeout(const Duration(seconds: 5));
      if (expired || input['token'] != token) {
        throw const FormatException('Код истёк или неверен.');
      }
      Map<String, Object?> result;
      if (request.uri.path == '/request') {
        final peer = PairedDevice.fromJson(input['device']);
        if (peer.certificate.deviceId == self.certificate.deviceId) {
          throw const FormatException('Это то же устройство.');
        }
        if (pending != null &&
            (pending!.device.certificate.fingerprint !=
                    peer.certificate.fingerprint ||
                pending!.device.certificate.deviceId !=
                    peer.certificate.deviceId)) {
          throw const FormatException('Уже есть запрос.');
        }
        if (pending == null) {
          final ticket = randomToken();
          pending = PendingPair(
            peer,
            ticket,
            verificationCode(invitation(self.endpoint.host), peer, ticket),
          );
          onChanged();
        }
        result = {'ticket': pending!.ticket, 'code': pending!.code};
      } else {
        if (pending == null || input['ticket'] != pending!.ticket) {
          throw const FormatException('Неизвестный запрос.');
        }
        if (request.uri.path == '/confirm') {
          pending!.remoteApproved = true;
          await _finish();
          onChanged();
        } else if (request.uri.path != '/status') {
          throw const FormatException('Неизвестный маршрут.');
        }
        result = {'complete': pending!.completed};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.write(jsonEncode({'version': 1, ...result}));
    } on Object {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.write('{"error":"pairing_refused"}');
    } finally {
      if (counted) _active--;
      try {
        await request.response.close();
      } on Object {
        /* disconnected */
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    await _http.close(force: true);
  }
}

class PairingClient {
  final PairInvitation invitation;
  final PairedDevice self;
  String? ticket;
  PairingClient(this.invitation, this.self);
  Future<Map<String, dynamic>> _post(String route) async {
    final endpoint = invitation.pairingEndpoint;
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false)
        ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3,
    );
    client.findProxy = (_) => 'DIRECT';
    client.badCertificateCallback = (cert, host, port) =>
        host == endpoint.host &&
        port == endpoint.port &&
        invitation.device.certificate.matches(cert);
    try {
      final req = await client
          .postUrl(endpoint.resolve(route))
          .timeout(const Duration(seconds: 5));
      req.followRedirects = false;
      req.headers.contentType = ContentType.json;
      req.write(
        jsonEncode({
          'token': invitation.token,
          if (ticket != null) 'ticket': ticket,
          if (route == '/request') 'device': self.toJson(),
        }),
      );
      final res = await req.close().timeout(const Duration(seconds: 5));
      if (res.statusCode != 200 ||
          res.certificate == null ||
          !invitation.device.certificate.matches(res.certificate!)) {
        throw const FormatException('Подключение отклонено.');
      }
      final result = await readPairJson(res)
          .timeout(const Duration(seconds: 5));
      if (result['version'] != 1) {
        throw const FormatException('Несовместимая версия подключения.');
      }
      return result;
    } finally {
      client.close(force: true);
    }
  }

  Future<String> request() async {
    final value = await _post('/request');
    if (value['ticket'] is! String ||
        (value['ticket'] as String).length != 44) {
      throw const FormatException('Повреждён ответ подключения.');
    }
    ticket = value['ticket'] as String;
    final code = verificationCode(invitation, self, ticket!);
    if (value['code'] != code) {
      throw const FormatException('Коды не совпадают.');
    }
    return code;
  }

  Future<bool> confirm() async => (await _post('/confirm'))['complete'] == true;
  Future<bool> status() async => (await _post('/status'))['complete'] == true;
}
