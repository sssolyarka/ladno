import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'attachment_cache.dart';
import 'operation.dart';
import 'replica.dart';

const _deviceHeader = 'x-ladno-device-id';

class SyncTransportException implements Exception {
  final String code;
  const SyncTransportException(this.code);
  @override
  String toString() => 'SyncTransportException: $code';
}

/// Metadata, not trust: the future pairing UI must establish this binding.
class PeerCertificate {
  final String deviceId, certificatePem, fingerprint;
  factory PeerCertificate(String deviceId, String certificatePem) {
    if (!validUuid(deviceId) || certificatePem.length > 32768) {
      throw const SyncProtocolException('Некорректный сертификат устройства.');
    }
    final match = RegExp(
      r'^\s*-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+)-----END CERTIFICATE-----\s*$',
    ).firstMatch(certificatePem);
    if (match == null) {
      throw const SyncProtocolException('Нужен один PEM-сертификат.');
    }
    try {
      final der = base64Decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
      SecurityContext(withTrustedRoots: false)
          .setTrustedCertificatesBytes(utf8.encode(certificatePem));
      return PeerCertificate._(
        deviceId,
        certificatePem,
        sha256.convert(der).toString(),
      );
    } on Object {
      throw const SyncProtocolException('Сертификат не удалось прочитать.');
    }
  }
  const PeerCertificate._(this.deviceId, this.certificatePem, this.fingerprint);
  bool matches(X509Certificate cert) =>
      sha256.convert(cert.der).toString() == fingerprint;
}

/// No export/toJson. A future OS vault supplies PEM; tests supply temporary keys.
class TlsIdentity {
  final PeerCertificate certificate;
  final String _privateKeyPem;
  TlsIdentity(this.certificate, String privateKeyPem)
    : _privateKeyPem = privateKeyPem {
    createContext();
  }
  SecurityContext createContext() => SecurityContext(withTrustedRoots: false)
    ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
    ..useCertificateChainBytes(utf8.encode(certificate.certificatePem))
    ..usePrivateKeyBytes(utf8.encode(_privateKeyPem));
}

Future<String> _readBounded(
  Stream<List<int>> stream,
  int limit,
  Duration timeout,
) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream.timeout(timeout)) {
    if (bytes.length + chunk.length > limit) {
      throw const SyncTransportException('message_too_large');
    }
    bytes.add(chunk);
  }
  return utf8.decode(bytes.takeBytes());
}

/// Only authenticated routes; no temporary unauthenticated data endpoint.
class TlsSyncServer {
  final Replica replica;
  final TlsIdentity identity;
  final AttachmentCache? attachments;
  final void Function()? onDataChanged;
  final Map<String, PeerCertificate> _trusted = {};
  final SecurityContext _context;
  late final HttpServer _http;
  final _handling = <Future<void>>{};
  var _active = 0;
  var _closed = false;
  int get port => _http.port;
  TlsSyncServer._(
    this.replica,
    this.identity,
    this.attachments,
    this.onDataChanged,
  ) : _context = identity.createContext();

  static Future<TlsSyncServer> start({
    required Replica replica,
    required TlsIdentity identity,
    required List<PeerCertificate> trusted,
    AttachmentCache? attachments,
    void Function()? onDataChanged,
    InternetAddress? address,
    int port = 0,
  }) async {
    if (identity.certificate.deviceId != replica.deviceId) {
      throw const SyncProtocolException(
        'Идентификатор сервера не совпадает с хранилищем.',
      );
    }
    final service = TlsSyncServer._(
      replica,
      identity,
      attachments,
      onDataChanged,
    );
    for (final peer in trusted) {
      service.trust(peer);
    }
    service._http = await HttpServer.bindSecure(
      address ?? InternetAddress.loopbackIPv4,
      port,
      service._context,
      requestClientCertificate: true,
    );
    service._http.idleTimeout = const Duration(seconds: 10);
    service._http.listen(
      (request) {
        final handling = service._handle(request);
        service._handling.add(handling);
        unawaited(
          handling.whenComplete(() => service._handling.remove(handling)),
        );
      },
      onError: (Object _, StackTrace _) {
        /* Refused TLS handshakes; no secret logging. */
      },
    );
    return service;
  }

  void trust(PeerCertificate peer) {
    final existing = _trusted[peer.fingerprint];
    if (existing?.deviceId == peer.deviceId) return;
    if (peer.deviceId == replica.deviceId ||
        existing != null ||
        _trusted.length >= 16 ||
        _trusted.values.any(
          (p) =>
              p.deviceId == peer.deviceId && p.fingerprint != peer.fingerprint,
        )) {
      throw const SyncProtocolException(
        'Конфликт идентификаторов или лимит доверия.',
      );
    }
    _context.setTrustedCertificatesBytes(utf8.encode(peer.certificatePem));
    _trusted[peer.fingerprint] = peer;
    _context.setClientAuthoritiesBytes(
      utf8.encode(_trusted.values.map((p) => p.certificatePem).join('\n')),
    );
  }

  Future<void> revoke(String deviceId) async {
    _trusted.removeWhere((_, p) => p.deviceId == deviceId);
    await replica.forgetReceipts(deviceId);
  }

  PeerCertificate _authorize(HttpRequest request) {
    final cert = request.certificate;
    final peer = cert == null
        ? null
        : _trusted[sha256.convert(cert.der).toString()];
    if (peer == null || request.headers.value(_deviceHeader) != peer.deviceId) {
      throw const SyncTransportException('unauthorized');
    }
    return peer;
  }

  void _stillTrusted(PeerCertificate peer) {
    if (_closed || _trusted[peer.fingerprint]?.deviceId != peer.deviceId) {
      throw const SyncTransportException('unauthorized');
    }
  }

  Future<void> _reply(
    HttpRequest request,
    PeerCertificate peer,
    Map<String, Object?> data,
  ) async {
    _stillTrusted(peer);
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.write(
      jsonEncode({
        'protocol': syncProtocolVersion,
        'deviceId': replica.deviceId,
        ...data,
      }),
    );
    await request.response.close();
  }

  Map<String, dynamic> _control(String body) {
    final value = jsonDecode(body);
    if (value is! Map<String, dynamic> ||
        value['protocol'] != syncProtocolVersion) {
      throw const SyncTransportException('incompatible_protocol');
    }
    return value;
  }

  Future<void> _handle(HttpRequest request) async {
    var counted = false;
    try {
      final peer = _authorize(request);
      if (_active >= 4) throw const SyncTransportException('busy');
      _active++;
      counted = true;
      if (request.method != 'POST' ||
          request.uri.hasQuery ||
          request.uri.hasFragment) {
        throw const SyncTransportException('invalid_route');
      }
      final route = request.uri.path;
      final limit = route == '/v1/push'
          ? maxSyncBatchBytes
          : route == '/v1/file/append'
          ? AttachmentCache.chunkBytes * 2
          : 65536;
      if (request.contentLength > limit) {
        throw const SyncTransportException('message_too_large');
      }
      final body = await _readBounded(
        request,
        limit,
        const Duration(seconds: 10),
      ).timeout(const Duration(seconds: 10));
      _stillTrusted(peer);
      if (route == '/v1/push') {
        final receipts = await replica.receive(
          SyncBatch.decode(body),
          fromPeer: peer.deviceId,
        );
        if (receipts.isNotEmpty) onDataChanged?.call();
        await _reply(request, peer, {'ack': receipts});
      } else if (route == '/v1/pull') {
        final value = _control(body);
        if (value.length != 2 ||
            value['ack'] is! List ||
            (value['ack'] as List).any((v) => v is! String)) {
          throw const SyncTransportException('invalid_ack');
        }
        await replica.acknowledge(
          peer.deviceId,
          List<String>.from(value['ack'] as List),
        );
        _stillTrusted(peer);
        await _reply(request, peer, {
          'batch': jsonDecode((await replica.outgoing(peer.deviceId)).encode()),
        });
      } else if (route.startsWith('/v1/file/') && attachments != null) {
        final value = _control(body);
        final descriptor = AttachmentDescriptor.fromJson(value['descriptor']);
        final cache = attachments!;
        if (route == '/v1/file/status') {
          await _reply(request, peer, {
            'complete': await cache.contains(descriptor),
            'offset': await cache.resumeOffset(descriptor, create: false),
          });
        } else if (route == '/v1/file/append' &&
            value['offset'] is int &&
            value['data'] is String) {
          final offset = await cache.append(
            descriptor,
            value['offset'] as int,
            base64Decode(value['data'] as String),
          );
          await _reply(request, peer, {'offset': offset});
        } else if (route == '/v1/file/read' && value['offset'] is int) {
          await _reply(request, peer, {
            'data': base64Encode(
              await cache.readChunk(descriptor, value['offset'] as int),
            ),
          });
        } else if (route == '/v1/file/finish') {
          await cache.finish(descriptor);
          onDataChanged?.call();
          await _reply(request, peer, {'complete': true});
        } else {
          throw const SyncTransportException('invalid_route');
        }
      } else {
        throw const SyncTransportException('invalid_route');
      }
    } catch (error) {
      try {
        final code = error is SyncTransportException
            ? error.code
            : error is SyncProtocolException || error is FormatException
            ? 'invalid_data'
            : 'unavailable';
        request.response.statusCode = code == 'unauthorized'
            ? 403
            : code == 'busy'
            ? 503
            : 400;
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set(HttpHeaders.connectionHeader, 'close');
        request.response.write(jsonEncode({'error': code}));
        await request.response.close();
      } on Object {
        /* A disconnected peer retries after its last durable ACK. */
      }
    } finally {
      if (counted) _active--;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _http.close(force: true);
    await Future.wait(_handling.toList());
  }
}

class TlsSyncClient {
  final TlsIdentity? identity;
  final PeerCertificate? peer;
  final String? _backendToken, _backendDeviceId, _backendServerId;
  final SecurityContext? _backendContext;
  bool get _backend => _backendToken != null;
  String get _localId => _backendDeviceId ?? identity!.certificate.deviceId;
  String get _remoteId => _backendServerId ?? peer!.deviceId;
  final Uri endpoint;
  final Duration timeout;
  final Set<HttpClient> _clients = {};
  var _cancelled = false;
  TlsSyncClient({
    required this.identity,
    required this.peer,
    required this.endpoint,
    this.timeout = const Duration(seconds: 10),
  }) : _backendToken = null,
       _backendDeviceId = null,
       _backendServerId = null,
       _backendContext = null {
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        (endpoint.path.isNotEmpty && endpoint.path != '/') ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        peer!.deviceId == identity!.certificate.deviceId) {
      throw const SyncProtocolException(
        'Нужен HTTPS-адрес другого доверенного устройства.',
      );
    }
  }
  TlsSyncClient.backend({
    required this.endpoint,
    required String token,
    required String deviceId,
    required String serverId,
    SecurityContext? trustedContext,
    this.timeout = const Duration(seconds: 15),
  }) : identity = null,
       peer = null,
       _backendToken = token,
       _backendDeviceId = deviceId,
       _backendServerId = serverId,
       _backendContext = trustedContext {
    if (endpoint.scheme != 'https' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        (endpoint.path.isNotEmpty && endpoint.path != '/') ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        !validUuid(deviceId) ||
        !validUuid(serverId) ||
        deviceId == serverId ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
      throw const SyncProtocolException(
        'Нужны HTTPS-адрес сервера и действующий токен устройства.',
      );
    }
  }
  Future<Map<String, dynamic>> _post(String route, String body) async {
    if (_cancelled) throw const SyncTransportException('cancelled');
    // Empty roots force exact pinning BEFORE any notes are sent, even for a
    // CA-signed server certificate. Never return true without this comparison.
    final client =
        HttpClient(
            context: _backend ? _backendContext : identity!.createContext(),
          )
          ..connectionTimeout = timeout
          ..autoUncompress = false;
    client.findProxy = (_) => 'DIRECT';
    if (!_backend) {
      client.badCertificateCallback = (cert, host, port) =>
          host == endpoint.host && port == endpoint.port && peer!.matches(cert);
    }
    _clients.add(client);
    Future<Map<String, dynamic>> perform() async {
      final request = await client.postUrl(endpoint.replace(path: route));
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      request.headers.set(_deviceHeader, _localId);
      if (_backend) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $_backendToken',
        );
      }
      request.write(body);
      final response = await request.close();
      if (!_backend &&
          (response.certificate == null ||
              !peer!.matches(response.certificate!))) {
        throw const SyncTransportException('unauthorized');
      }
      if (response.statusCode != 200) {
        throw SyncTransportException(
          response.statusCode == 403 ? 'unauthorized' : 'remote_rejected',
        );
      }
      final value = jsonDecode(
        await _readBounded(response, maxSyncBatchBytes + 1024, timeout),
      );
      if (value is! Map<String, dynamic> ||
          value['protocol'] != syncProtocolVersion ||
          value['deviceId'] != _remoteId) {
        throw const SyncTransportException('invalid_response');
      }
      return value;
    }

    try {
      return await perform().timeout(timeout);
    } on HandshakeException {
      throw const SyncTransportException('unauthorized');
    } on TlsException {
      throw const SyncTransportException('unauthorized');
    } on TimeoutException {
      throw const SyncTransportException('timeout');
    } on SocketException {
      throw SyncTransportException(_cancelled ? 'cancelled' : 'unavailable');
    } on HttpException {
      throw SyncTransportException(_cancelled ? 'cancelled' : 'unavailable');
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Future<List<String>> push(SyncBatch batch) async {
    final response = await _post('/v1/push', batch.encode());
    final ack = response['ack'];
    if (ack is! List ||
        ack.length > maxSyncBatchOperations ||
        ack.any((v) => !validOperationId(v)) ||
        ack.length != batch.operations.length ||
        ack
            .toSet()
            .difference(batch.operations.map((op) => op.id).toSet())
            .isNotEmpty ||
        batch.operations
            .map((op) => op.id)
            .toSet()
            .difference(ack.toSet())
            .isNotEmpty) {
      throw const SyncTransportException('invalid_ack');
    }
    return List<String>.from(ack);
  }

  Future<SyncBatch> pull(List<String> ack) async {
    final response = await _post(
      '/v1/pull',
      jsonEncode({'protocol': syncProtocolVersion, 'ack': ack}),
    );
    return SyncBatch.decode(jsonEncode(response['batch']));
  }

  Future<Map<String, dynamic>> _file(
    String action,
    AttachmentDescriptor descriptor, [
    Map<String, Object?> extra = const {},
  ]) => _post(
    '/v1/file/$action',
    jsonEncode({
      'protocol': syncProtocolVersion,
      'descriptor': descriptor.toJson(),
      ...extra,
    }),
  );

  /// Foreground bidirectional exchange; the initiating phone needs no listener.
  Future<SyncResult> synchronize(
    Replica local, {
    AttachmentCache? attachments,
  }) async {
    if (local.deviceId != _localId) {
      throw const SyncProtocolException('Идентификатор клиента не совпадает.');
    }
    for (var page = 0; page < 1000; page++) {
      final batch = await local.outgoing(_remoteId);
      if (batch.operations.isEmpty) break;
      await local.acknowledge(_remoteId, await push(batch));
      if (page == 999) throw const SyncTransportException('session_limit');
    }
    var ack = <String>[];
    for (var page = 0; page < 1000; page++) {
      final batch = await pull(ack);
      if (batch.operations.isEmpty) break;
      ack = await local.receive(batch, fromPeer: _remoteId);
      if (page == 999) throw const SyncTransportException('session_limit');
    }
    final referenced = await local.referencedAttachments();
    if (attachments == null) {
      return SyncResult(referenced.map((d) => d.hash).toList());
    }
    final unavailable = <String>[];
    for (final descriptor in referenced) {
      final status = await _file('status', descriptor);
      final offset = status['offset'];
      if (offset is! int ||
          offset < 0 ||
          offset > descriptor.size ||
          status['complete'] is! bool) {
        throw const SyncTransportException('invalid_response');
      }
      if (await attachments.contains(descriptor)) {
        if (status['complete'] == true) continue;
        var cursor = offset;
        while (cursor < descriptor.size) {
          final bytes = await attachments.readChunk(descriptor, cursor);
          final response = await _file('append', descriptor, {
            'offset': cursor,
            'data': base64Encode(bytes),
          });
          cursor += bytes.length;
          if (response['offset'] != cursor) {
            throw const SyncTransportException('invalid_response');
          }
        }
        await _file('finish', descriptor);
      } else if (status['complete'] == true) {
        var cursor = await attachments.resumeOffset(descriptor);
        while (cursor < descriptor.size) {
          final response = await _file('read', descriptor, {'offset': cursor});
          if (response['data'] is! String) {
            throw const SyncTransportException('invalid_response');
          }
          final bytes = base64Decode(response['data'] as String);
          if (bytes.isEmpty) {
            throw const SyncTransportException('invalid_response');
          }
          cursor = await attachments.append(descriptor, cursor, bytes);
        }
        await attachments.finish(descriptor);
      } else {
        unavailable.add(descriptor.hash);
      }
    }
    return SyncResult(unavailable);
  }

  void cancel() {
    _cancelled = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
  }
}

class SyncResult {
  final List<String> unavailableAttachments;
  SyncResult(List<String> unavailableAttachments)
    : unavailableAttachments = List.unmodifiable(unavailableAttachments);
  bool get textSynchronized => true;
  bool get filesSynchronized => unavailableAttachments.isEmpty;
}
