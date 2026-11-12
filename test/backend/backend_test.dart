// Integration fixture imports the independent backend package source.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ladno/data/store.dart';
import 'package:ladno/planning/tasks.dart';
import 'package:ladno/sync/backend_connection.dart';
import 'package:ladno/sync/tls_transport.dart';

import '../../server/lib/backend.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  late Store a, b;
  late Backend server;
  late SecurityContext trust, tls;
  late Uri endpoint;
  Future<void> start() async {
    server = await Backend.open(Directory('${root.path}/server'));
    await server.listen(port: 0, tls: tls);
    endpoint = Uri.parse('https://localhost:${server.port}');
  }

  Future<BackendConnection> join(
    Store store, {
    String? invite,
    SecurityContext? context,
  }) async => BackendConnection.enroll(
    endpoint: endpoint,
    deviceId: store.replica.deviceId,
    invite: invite ?? await server.invite(),
    name: 'Тест',
    trustedContext: context ?? trust,
  );
  TlsSyncClient client(BackendConnection c) => TlsSyncClient.backend(
    endpoint: endpoint,
    token: c.token,
    deviceId: c.deviceId,
    serverId: c.serverId,
    trustedContext: trust,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ladno-backend-');
    final generated = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-subj',
      '/CN=localhost',
      '-addext',
      'subjectAltName=DNS:localhost',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
      '-days',
      '1',
      '-keyout',
      '${root.path}/key.pem',
      '-out',
      '${root.path}/cert.pem',
    ]);
    if (generated.exitCode != 0) throw StateError('openssl required');
    tls = SecurityContext()
      ..useCertificateChain('${root.path}/cert.pem')
      ..usePrivateKey('${root.path}/key.pem');
    trust = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates('${root.path}/cert.pem');
    a = await Store.open(databaseFactoryFfi, Directory('${root.path}/a'));
    b = await Store.open(databaseFactoryFfi, Directory('${root.path}/b'));
    await start();
  });
  tearDown(() async {
    await server.close();
    await a.close();
    await b.close();
    await root.delete(recursive: true);
  });
  Future<Map<String, dynamic>> post(
    String path,
    Map<String, Object?> body, {
    BackendConnection? who,
  }) async {
    final http = HttpClient(context: trust);
    try {
      final request = await http.postUrl(endpoint.replace(path: path));
      request.headers.contentType = ContentType.json;
      if (who != null) {
        request.headers.set('authorization', 'Bearer ${who.token}');
        request.headers.set('x-ladno-device-id', who.deviceId);
      }
      request.write(jsonEncode(body));
      final response = await request.close();
      final value = jsonDecode(
        await utf8.decoder.bind(response).join(),
      ) as Map<String, dynamic>;
      value['httpStatus'] = response.statusCode;
      return value;
    } finally {
      http.close(force: true);
    }
  }

  test('HTTPS: два клиента обмениваются заметками, задачами, конфликтами и файлами', () async {
    final ca = await join(a), cb = await join(b);
    final note = await a.createNote();
    note.title = 'С компьютера';
    await a.save(note);
    final file = File('${root.path}/test.txt');
    await file.writeAsString('Вложение');
    await a.addAttachment(note.id, file);
    await TaskBook(a)
        .createTask({'title': 'На телефон', 'dueDate': '2026-11-12'});
    await client(ca).synchronize(a.replica, attachments: a.attachments);
    await client(cb).synchronize(b.replica, attachments: b.attachments);
    expect((await b.notes()).single.title, 'С компьютера');
    expect((await TaskBook(b).tasks()).single.title, 'На телефон');
    final descriptors = await b.noteAttachments(note.id);
    expect(await b.attachments.contains(descriptors.single), isTrue);
    final na = (await a.notes()).single, nb = (await b.notes()).single;
    na.body = 'ПК';
    nb.body = 'Телефон';
    await a.save(na);
    await b.save(nb);
    await client(ca).synchronize(a.replica, attachments: a.attachments);
    await client(cb).synchronize(b.replica, attachments: b.attachments);
    await client(ca).synchronize(a.replica, attachments: a.attachments);
    expect((await a.notes()).single.hasConflict, isTrue);
    expect((await b.notes()).single.hasConflict, isTrue);
  });
  test(
    'Одноразовый код нельзя повторить, просроченный код отклоняется',
    () async {
      final invite = await server.invite();
      await join(a, invite: invite);
      await expectLater(join(b, invite: invite), throwsFormatException);
      await expectLater(
        join(
          b,
          invite: await server.invite(lifetime: const Duration(seconds: -1)),
        ),
        throwsFormatException,
      );
    },
  );
  test('Отзыв устройства блокирует запись, новый код меняет токен', () async {
    final c = await join(a);
    await server.revoke(a.replica.deviceId);
    await expectLater(
      client(c).synchronize(a.replica),
      throwsA(isA<SyncTransportException>()),
    );
    final fresh = await join(a);
    expect(fresh.token, isNot(c.token));
    await client(fresh).synchronize(a.replica);
    await expectLater(
      client(c).synchronize(a.replica),
      throwsA(isA<SyncTransportException>()),
    );
  });
  test('Перезапуск сохраняет сервер, токен и журнал', () async {
    final c = await join(a);
    final note = await a.createNote();
    note.title = 'Сохранить';
    await a.save(note);
    await client(c).synchronize(a.replica);
    final id = server.replica.deviceId;
    await server.close();
    await start();
    expect(server.replica.deviceId, id);
    final cb = await join(b);
    await client(cb).synchronize(b.replica);
    expect((await b.notes()).single.title, 'Сохранить');
    await client(c).synchronize(a.replica);
  });
  test('Неавторизованный запрос и подмена ID отклоняются', () async {
    expect(
      (await post('/v1/pull', {
        'protocol': 1,
        'ack': <String>[],
      }))['httpStatus'],
      403,
    );
    final c = await join(a);
    final forged = BackendConnection(
      endpoint,
      b.replica.deviceId,
      c.serverId,
      c.token,
    );
    expect(
      (await post('/v1/pull', {
        'protocol': 1,
        'ack': <String>[],
      }, who: forged))['httpStatus'],
      403,
    );
  });
  test('Недоверенный сертификат не принимается при регистрации', () async {
    await expectLater(
      BackendConnection.enroll(
        endpoint: endpoint,
        deviceId: a.replica.deviceId,
        invite: await server.invite(),
        name: 'Тест',
      ),
      throwsA(isA<HandshakeException>()),
    );
    expect(await server.devices(), isEmpty);
  });
  test(
    'В БД нет открытых токенов, не связанный с журналом файл запрещён',
    () async {
      final c = await join(a);
      final rows = await server.db.query('backend_devices');
      expect(rows.single['token_hash'], isNot(c.token));
      final response = await post('/v1/file/status', {
        'protocol': 1,
        'descriptor': {'hash': '0' * 64, 'name': 'unknown', 'size': 1},
      }, who: c);
      expect(response['httpStatus'], 403);
    },
  );
}
