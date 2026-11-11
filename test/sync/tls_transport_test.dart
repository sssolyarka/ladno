import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:ladno/sync/attachment_cache.dart';
import 'package:ladno/sync/operation.dart';
import 'package:ladno/sync/replica.dart';
import 'package:ladno/sync/tls_transport.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  late Replica a, b;
  late TlsIdentity ai, bi;
  late TlsSyncServer server;
  late AttachmentCache ac, bc;
  final keys = <String, String>{};
  Future<TlsIdentity> identity(String id) async {
    final base = '${root.path}/${const Uuid().v4()}';
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:P-256',
      '-nodes',
      '-subj',
      '/CN=$id',
      '-days',
      '2',
      '-addext',
      'basicConstraints=critical,CA:FALSE',
      '-addext',
      'extendedKeyUsage=serverAuth,clientAuth',
      '-keyout',
      '$base.key',
      '-out',
      '$base.crt',
    ]);
    if (result.exitCode != 0) {
      fail('Для сетевых тестов нужен openssl с поддержкой сертификатов EC.');
    }
    final pem = await File('$base.crt').readAsString();
    final key = await File('$base.key').readAsString();
    final cert = PeerCertificate(id, pem);
    keys[cert.fingerprint] = key;
    return TlsIdentity(cert, key);
  }

  SecurityContext context(TlsIdentity who) =>
      SecurityContext(withTrustedRoots: false)
        ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3
        ..useCertificateChainBytes(utf8.encode(who.certificate.certificatePem))
        ..usePrivateKeyBytes(utf8.encode(keys[who.certificate.fingerprint]!));
  TlsSyncClient client({TlsIdentity? who, PeerCertificate? peer, int? port}) =>
      TlsSyncClient(
        identity: who ?? ai,
        peer: peer ?? bi.certificate,
        endpoint: Uri.parse('https://127.0.0.1:${port ?? server.port}'),
        timeout: const Duration(seconds: 3),
      );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ladno-mtls-');
    a = await Replica.open(databaseFactoryFfi, Directory('${root.path}/a'));
    b = await Replica.open(databaseFactoryFfi, Directory('${root.path}/b'));
    ac = AttachmentCache(Directory('${root.path}/ac'));
    bc = AttachmentCache(Directory('${root.path}/bc'));
    ai = await identity(a.deviceId);
    bi = await identity(b.deviceId);
    server = await TlsSyncServer.start(
      replica: b,
      identity: bi,
      trusted: [ai.certificate],
      attachments: bc,
    );
  });
  tearDown(() async {
    await server.close();
    await a.close();
    await b.close();
    await root.delete(recursive: true);
    keys.clear();
  });

  test('Реальный TLS: одна сессия передаёт заметки в обе стороны', () async {
    final one = const Uuid().v4(), two = const Uuid().v4();
    await a.change(one, 'note', {'body': 'С компьютера'});
    await b.change(two, 'note', {'body': 'С телефона'});
    final connection = client();
    await connection.synchronize(a);
    expect((await b.read(one))!.fields['body'], 'С компьютера');
    expect((await a.read(two))!.fields['body'], 'С телефона');
    expect((await a.outgoing(b.deviceId)).operations, isEmpty);
    expect((await b.outgoing(a.deviceId)).operations, isEmpty);
    await connection.synchronize(a);
    expect(await a.operationCount(), 2);
    expect(await b.operationCount(), 2);
  });
  test('Неверный сертификат сервера блокирует передачу до записи', () async {
    final impostor = await identity(b.deviceId);
    await a.change(const Uuid().v4(), 'note', {
      'body': 'Не отправлять подмене',
    });
    await expectLater(
      client(peer: impostor.certificate).synchronize(a),
      throwsA(isA<SyncTransportException>()),
    );
    expect(await b.operationCount(), 0);
    expect((await a.outgoing(b.deviceId)).operations, hasLength(1));
  });
  test('Сертификат недоверенного клиента отклоняется', () async {
    final outsider = await identity(const Uuid().v4());
    final op = await a.change(const Uuid().v4(), 'note', {'body': 'Текст'});
    await expectLater(
      client(who: outsider).push(SyncBatch([op])),
      throwsA(isA<SyncTransportException>()),
    );
    expect(await b.operationCount(), 0);
  });
  test(
    'Отзыв доверия запрещает следующий обмен без удаления локальных данных',
    () async {
      final first = const Uuid().v4();
      await a.change(first, 'note', {'body': 'Разрешённый текст'});
      final connection = client();
      await connection.synchronize(a);
      await server.revoke(a.deviceId);
      await a.change(const Uuid().v4(), 'note', {'body': 'После отзыва'});
      await expectLater(
        connection.synchronize(a),
        throwsA(isA<SyncTransportException>()),
      );
      expect(await b.operationCount(), 1);
      expect((await b.read(first))!.fields['body'], 'Разрешённый текст');
    },
  );
  test('HTTPS без сертификата клиента не получает доступ к данным', () async {
    final raw = HttpClient(
      context: SecurityContext(withTrustedRoots: false)
        ..minimumTlsProtocolVersion = TlsProtocolVersion.tls1_3,
    );
    raw.badCertificateCallback = (cert, host, port) =>
        bi.certificate.matches(cert);
    try {
      final request = await raw.postUrl(
        Uri.parse('https://127.0.0.1:${server.port}/v1/pull'),
      );
      request.headers.contentType = ContentType.json;
      request.headers.set('x-ladno-device-id', a.deviceId);
      request.write(jsonEncode({'protocol': 1, 'ack': []}));
      final response = await request.close();
      expect(response.statusCode, 403);
      expect(
        await response.transform(utf8.decoder).join(),
        isNot(contains('operations')),
      );
    } finally {
      raw.close(force: true);
    }
    expect(await b.operationCount(), 0);
  });
  test('Прерывание после commit до ACK повторяется без дублей', () async {
    await server.close();
    Future<void>? stopped;
    server = await TlsSyncServer.start(
      replica: b,
      identity: bi,
      trusted: [ai.certificate],
      onDataChanged: () {
        stopped = server.close();
      },
    );
    await a.change(const Uuid().v4(), 'note', {
      'body': 'Уже записано, ACK потерян',
    });
    await expectLater(
      client().synchronize(a),
      throwsA(isA<SyncTransportException>()),
    );
    await stopped;
    expect(await b.operationCount(), 1);
    expect((await a.outgoing(b.deviceId)).operations, hasLength(1));
    server = await TlsSyncServer.start(
      replica: b,
      identity: bi,
      trusted: [ai.certificate],
    );
    await client().synchronize(a);
    expect(await b.operationCount(), 1);
    expect((await a.outgoing(b.deviceId)).operations, isEmpty);
  });
  test(
    'Вложения передаются в обе стороны без обратного listener у клиента',
    () async {
      final localFile = File('${root.path}/local.bin'),
          remoteFile = File('${root.path}/remote.bin');
      await localFile.writeAsBytes([1, 2, 3]);
      await remoteFile.writeAsBytes(
        List.generate(AttachmentCache.chunkBytes + 17, (i) => i % 251),
      );
      final local = await ac.importFile(localFile),
          remote = await bc.importFile(remoteFile);
      await a.change(const Uuid().v4(), 'note', {
        'body': 'Локальное',
        'attachments': [local.toJson()],
      });
      await b.change(const Uuid().v4(), 'note', {
        'body': 'Удалённое',
        'attachments': [remote.toJson()],
      });
      // Simulate an earlier interrupted download already flushed to disk.
      await ac.append(
        remote,
        0,
        (await bc.readChunk(remote, 0)).sublist(0, 100),
      );
      await client().synchronize(a, attachments: ac);
      expect(await bc.contains(local), isTrue);
      expect(await ac.contains(remote), isTrue);
      expect(await a.objectIds(), hasLength(2));
      expect(await b.objectIds(), hasLength(2));
    },
  );
  test('Несовместимый протокол не записывает операции и не раскрывает текст в ошибке', () async {
    final raw = HttpClient(context: context(ai));
    raw.badCertificateCallback = (cert, host, port) =>
        bi.certificate.matches(cert);
    try {
      final request = await raw.postUrl(
        Uri.parse('https://127.0.0.1:${server.port}/v1/push'),
      );
      request.headers.contentType = ContentType.json;
      request.headers.set('x-ladno-device-id', a.deviceId);
      request.write(
        jsonEncode({
          'protocol': 999,
          'operations': [],
          'privateText': 'НЕ ВЫВОДИТЬ',
        }),
      );
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      expect(response.statusCode, 400);
      expect(text, isNot(contains('НЕ ВЫВОДИТЬ')));
    } finally {
      raw.close(force: true);
    }
    expect(await b.operationCount(), 0);
  });
  test('Обычный HTTP, URL с секретом и подмена device ID запрещены', () async {
    expect(
      () => TlsSyncClient(
        identity: ai,
        peer: bi.certificate,
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
      ),
      throwsA(isA<SyncProtocolException>()),
    );
    expect(
      () => TlsSyncClient(
        identity: ai,
        peer: bi.certificate,
        endpoint: Uri.parse('https://secret@127.0.0.1:${server.port}'),
      ),
      throwsA(isA<SyncProtocolException>()),
    );
    final raw = HttpClient(context: context(ai));
    raw.badCertificateCallback = (cert, host, port) =>
        bi.certificate.matches(cert);
    try {
      final request = await raw.postUrl(
        Uri.parse('https://127.0.0.1:${server.port}/v1/pull'),
      );
      request.headers.set('x-ladno-device-id', b.deviceId);
      request.write(jsonEncode({'protocol': 1, 'ack': []}));
      final response = await request.close();
      expect(response.statusCode, 403);
      await response.drain<void>();
    } finally {
      raw.close(force: true);
    }
  });
  test(
    'Отмена запрещает последующий запрос и не подтверждает очередь',
    () async {
      await a.change(const Uuid().v4(), 'note', {'body': 'Не передано'});
      final connection = client()..cancel();
      await expectLater(
        connection.synchronize(a),
        throwsA(isA<SyncTransportException>()),
      );
      expect(await b.operationCount(), 0);
      expect((await a.outgoing(b.deviceId)).operations, hasLength(1));
    },
  );

  test(
    'Добавление второго доверенного сертификата не отключает первый',
    () async {
      final second = await identity(const Uuid().v4());
      server.trust(second.certificate);
      final id = const Uuid().v4();
      await a.change(id, 'note', {
        'body': 'Первое устройство всё ещё работает',
      });
      await client().synchronize(a);
      expect(
        (await b.read(id))!.fields['body'],
        'Первое устройство всё ещё работает',
      );
      expect(await client(who: second).push(SyncBatch([])), isEmpty);
    },
  );
  test(
    'Нет файлов: текст синхронизирован, отсутствие вложений явно возвращается',
    () async {
      final descriptors = List.generate(
        40,
        (i) => AttachmentDescriptor(
          hash: (i + 1).toRadixString(16).padLeft(64, '0'),
          name: 'Файл $i',
          size: 10,
        ),
      );
      final id = const Uuid().v4();
      await a.change(id, 'note', {
        'body': 'Текст доступен независимо от файлов',
        'attachments': descriptors.map((d) => d.toJson()).toList(),
      });
      final result = await client().synchronize(a, attachments: ac);
      expect(result.textSynchronized, isTrue);
      expect(result.filesSynchronized, isFalse);
      expect(result.unavailableAttachments, hasLength(40));
      expect(
        (await b.read(id))!.fields['body'],
        'Текст доступен независимо от файлов',
      );
      expect(await Directory('${root.path}/bc/partial').exists(), isFalse);
    },
  );
}
