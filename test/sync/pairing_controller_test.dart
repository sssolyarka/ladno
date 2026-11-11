import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ladno/data/store.dart';
import 'package:ladno/sync/controller.dart';
import 'package:ladno/sync/device_vault.dart';
import 'package:ladno/sync/pairing.dart';

class MemorySecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  sqfliteFfiInit();
  late Directory root;
  late Store a, b;
  late SyncController ac, bc;
  late MemorySecrets sa, sb;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ladno-paired-');
    a = await Store.open(databaseFactoryFfi, Directory('${root.path}/a'));
    b = await Store.open(databaseFactoryFfi, Directory('${root.path}/b'));
    sa = MemorySecrets();
    sb = MemorySecrets();
    ac = SyncController(
      a,
      onDataChanged: () {},
      secrets: sa,
      useDiscovery: false,
      bindAddress: InternetAddress.loopbackIPv4,
      preferredPort: 0,
    );
    bc = SyncController(
      b,
      onDataChanged: () {},
      secrets: sb,
      useDiscovery: false,
      bindAddress: InternetAddress.loopbackIPv4,
      preferredPort: 0,
    );
    await DeviceVault.open(a.replica.deviceId, storage: sa);
    await ac.enable();
    await bc.enable();
    expect(ac.server, isNotNull);
    expect(bc.server, isNotNull);
  });
  tearDown(() async {
    await ac.close();
    await bc.close();
    await a.close();
    await b.close();
    await root.delete(recursive: true);
  });
  Future<void> pair() async {
    final host = await bc.beginPairing('127.0.0.1');
    final invite = PairInvitation.decode(host.invitation('127.0.0.1').encode());
    final client = PairingClient(invite, ac.self('127.0.0.1'));
    final code = await client.request();
    expect(code, host.pending!.code);
    expect(ac.peers, isEmpty);
    expect(bc.peers, isEmpty);
    expect(await client.confirm(), isFalse);
    expect(bc.peers, isEmpty);
    await host.approve();
    expect(await client.status(), isTrue);
    await ac.addPeer(invite.device);
  }

  test('QR + два подтверждения + реальная передача заметок и файлов', () async {
    final note = await a.createNote();
    note.body = 'С компьютера';
    await a.save(note);
    final file = File('${root.path}/photo.png');
    await file.writeAsBytes(List.generate(900000, (i) => i % 251));
    await a.addAttachment(note.id, file);
    await pair();
    await ac.syncNow();
    expect((await b.notes()).single.body, 'С компьютера');
    final descriptor = (await b.noteAttachments(note.id)).single;
    expect(await b.attachments.contains(descriptor), isTrue);
    expect(ac.peerStatus[b.replica.deviceId], 'Синхронизировано');
    expect((await a.replica.outgoing(b.replica.deviceId)).operations, isEmpty);
  });
  test('Локальное подтверждение без второго не сохраняет доверие', () async {
    final host = await bc.beginPairing('127.0.0.1');
    final client = PairingClient(
      host.invitation('127.0.0.1'),
      ac.self('127.0.0.1'),
    );
    await client.request();
    await host.approve();
    expect(bc.peers, isEmpty);
    expect(await client.status(), isFalse);
    await bc.endPairing();
    await expectLater(client.confirm(), throwsA(anything));
    expect(bc.peers, isEmpty);
  });
  test('Подмена сертификата в приглашении блокирует запрос', () async {
    final host = await bc.beginPairing('127.0.0.1');
    final original = host.invitation('127.0.0.1');
    final fake = PairInvitation(
      ac.self('127.0.0.1'),
      original.pairingEndpoint,
      original.token,
    );
    final client = PairingClient(fake, ac.self('127.0.0.1'));
    await expectLater(client.request(), throwsA(anything));
    expect(host.pending, isNull);
  });
  test('Перезапуск сохраняет ключ и доверие, отзыв запрещает обмен', () async {
    await pair();
    final fingerprint = ac.vault!.identity.certificate.fingerprint;
    final reopened = await DeviceVault.open(a.replica.deviceId, storage: sa);
    expect(reopened.identity.certificate.fingerprint, fingerprint);
    expect(reopened.peers.single.certificate.deviceId, b.replica.deviceId);
    await bc.revoke(a.replica.deviceId);
    final note = await a.createNote();
    note.body = 'После отзыва';
    await a.save(note);
    await ac.syncNow();
    expect(await b.notes(), isEmpty);
    expect(ac.peerStatus[b.replica.deviceId], 'Другое устройство недоступно');
    expect(
      (await DeviceVault.open(b.replica.deviceId, storage: sb)).peers,
      isEmpty,
    );
  });
  test('Истёкшее приглашение не принимает запрос', () async {
    final server = await PairingServer.start(
      identity: bc.vault!.identity,
      self: bc.self('127.0.0.1'),
      address: InternetAddress.loopbackIPv4,
      lifetime: Duration.zero,
      onPaired: bc.addPeer,
    );
    try {
      final client = PairingClient(
        server.invitation('127.0.0.1'),
        ac.self('127.0.0.1'),
      );
      await expectLater(client.request(), throwsA(anything));
      expect(bc.peers, isEmpty);
    } finally {
      await server.close();
    }
  });
}
