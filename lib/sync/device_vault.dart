import 'dart:convert';
import 'dart:isolate';

import 'package:basic_utils/basic_utils.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'pairing.dart';
import 'tls_transport.dart';

abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class OsSecretStore implements SecretStore {
  final FlutterSecureStorage storage;
  const OsSecretStore([this.storage = const FlutterSecureStorage()]);
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

/// Pure library generation, no OpenSSL executable or shared developer key.
Map<String, String> generateIdentity(String id) {
  final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
  final private = pair.privateKey as RSAPrivateKey;
  final public = pair.publicKey as RSAPublicKey;
  final csr = X509Utils.generateRsaCsrPem({'CN': id}, private, public);
  final certificate = X509Utils.generateSelfSignedCertificate(
    private,
    csr,
    7300,
    extKeyUsage: [ExtendedKeyUsage.SERVER_AUTH, ExtendedKeyUsage.CLIENT_AUTH],
    notBefore: DateTime.now().toUtc().subtract(const Duration(days: 365)),
  );
  return {
    'pem': certificate,
    'key': CryptoUtils.encodeRSAPrivateKeyToPemPkcs1(private),
  };
}

class DeviceVault {
  final SecretStore storage;
  final String deviceId;
  final Map<String, dynamic> _data;
  Future<void> _tail = Future.value();
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  late final TlsIdentity identity;
  DeviceVault._(this.storage, this.deviceId, this._data) {
    identity = TlsIdentity(
      PeerCertificate(deviceId, _data['pem'] as String),
      _data['key'] as String,
    );
  }
  static Future<DeviceVault> open(
    String deviceId, {
    SecretStore storage = const OsSecretStore(),
  }) async {
    final key = 'ladno.sync.$deviceId';
    final existing = await storage.read(key);
    Map<String, dynamic> data;
    if (existing == null) {
      final material = await Isolate.run(() => generateIdentity(deviceId));
      TlsIdentity(
        PeerCertificate(deviceId, material['pem']!),
        material['key']!,
      );
      data = {...material, 'version': 1, 'peers': <dynamic>[]};
      final text = jsonEncode(data);
      await storage.write(key, text);
      if (await storage.read(key) != text) {
        throw const FormatException(
          'Ключ не удалось сохранить в хранилище ОС.',
        );
      }
    } else {
      if (existing.length > 1024 * 1024) {
        throw const FormatException('Повреждено защищённое хранилище.');
      }
      final value = jsonDecode(existing);
      if (value is! Map<String, dynamic> ||
          value['version'] != 1 ||
          value['peers'] is! List) {
        throw const FormatException('Несовместимое защищённое хранилище.');
      }
      data = value;
    }
    final vault = DeviceVault._(storage, deviceId, data);
    vault.peers; // Validate before starting any listener.
    return vault;
  }

  List<PairedDevice> get peers =>
      (_data['peers'] as List).map(PairedDevice.fromJson).toList();
  Future<void> _replace(List<PairedDevice> peers) async {
    final next = {..._data, 'peers': peers.map((p) => p.toJson()).toList()};
    final text = jsonEncode(next);
    await storage.write('ladno.sync.$deviceId', text);
    if (await storage.read('ladno.sync.$deviceId') != text) {
      throw const FormatException('Не удалось сохранить доверие.');
    }
    _data['peers'] = next['peers'];
  }

  Future<void> add(PairedDevice peer) => _serial(() async {
    final current = peers;
    if (peer.certificate.deviceId == deviceId ||
        current.length >= 16 ||
        current.any(
          (p) =>
              p.certificate.deviceId == peer.certificate.deviceId ||
              p.certificate.fingerprint == peer.certificate.fingerprint,
        )) {
      throw const FormatException(
        'Устройство уже подключено или достигнут лимит.',
      );
    }
    await _replace([...current, peer]);
  });

  Future<void> revoke(String id) =>
      _replace(peers.where((p) => p.certificate.deviceId != id).toList());
  Future<void> destroy() => storage.delete('ladno.sync.$deviceId');
}
