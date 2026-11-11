import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ladno/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  late Store a, b;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ladno-store-sync-');
    a = await Store.open(databaseFactoryFfi, Directory('${root.path}/a'));
    b = await Store.open(databaseFactoryFfi, Directory('${root.path}/b'));
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await root.delete(recursive: true);
  });
  Future<void> send(Store from, Store to) async {
    while (true) {
      final batch = await from.replica.outgoing(to.replica.deviceId);
      if (batch.operations.isEmpty) break;
      final ack = await to.replica.receive(
        batch,
        fromPeer: from.replica.deviceId,
      );
      await from.replica.acknowledge(to.replica.deviceId, ack);
    }
  }

  test(
    'Изменение заметки и журнал откатываются при ошибке отображения',
    () async {
      final note = await a.createNote();
      final count = await a.replica.operationCount();
      await a.db.execute(
        "CREATE TRIGGER fail_update BEFORE UPDATE ON notes BEGIN SELECT RAISE(ABORT, 'test'); END",
      );
      note.body = 'Не должно сохраниться частично';
      await expectLater(a.save(note), throwsA(anything));
      expect(await a.replica.operationCount(), count);
      expect((await a.notes()).single.body, isEmpty);
      await a.db.execute('DROP TRIGGER fail_update');
      await a.save(note);
      expect((await a.notes()).single.body, note.body);
      expect(await a.replica.operationCount(), count + 1);
    },
  );

  test(
    'Получение чужой заметки сразу обновляет пользовательский список',
    () async {
      await a.addFolder('Работа');
      final folder = (await a.folders()).single['id'] as String;
      final note = await a.createNote(folderId: folder);
      note.title = 'На телефоне';
      note.body = 'Привет';
      await a.save(note);
      await send(a, b);
      expect((await b.notes()).single.body, 'Привет');
      expect((await b.folders()).single['name'], 'Работа');
      await a.deleteFolder(folder);
      await send(a, b);
      expect(await b.folders(), isEmpty);
      expect((await b.notes()).single.folderId, isNull);
    },
  );

  test(
    'Старый редактор сохраняет две версии текста без потери чужого заголовка',
    () async {
      final openA = await a.createNote();
      openA.body = 'Исходный';
      await a.save(openA);
      await send(a, b);
      final openB = (await b.notes()).single;
      openB.body = 'С телефона';
      openB.title = 'Новый заголовок';
      await b.save(openB);
      await send(b, a);
      openA.body = 'С компьютера';
      await a.save(openA);
      final object = (await a.replica.read(openA.id))!;
      expect(object.fields['title'], 'Новый заголовок');
      expect(object.conflicts['body']!.map((v) => v.value).toSet(), {
        'С телефона',
        'С компьютера',
      });
      final count = await a.replica.operationCount();
      openA.body = 'Продолжение компьютера';
      await a.save(openA);
      expect(await a.replica.operationCount(), count + 1);
      expect(
        (await a.replica.read(openA.id))!.conflicts['body']!
            .map((v) => v.value)
            .toSet(),
        {'С телефона', 'Продолжение компьютера'},
      );
    },
  );

  test(
    'Очередь снимков одного редактора не создаёт конфликт сама с собой',
    () async {
      final note = await a.createNote();
      note.body = 'а';
      final first = note.snapshot();
      note.body = 'аб';
      final second = note.snapshot();
      await a.save(first);
      await a.save(second);
      expect((await a.notes()).single.body, 'аб');
      expect((await a.replica.read(note.id))!.hasConflict, isFalse);
    },
  );

  test('Резервная копия сохраняет конфликт, восстановление меняет только локальный origin', () async {
    final one = await a.createNote();
    await send(a, b);
    final two = (await b.notes()).single;
    one.body = 'А';
    two.body = 'Б';
    await a.save(one);
    await b.save(two);
    await send(b, a);
    final originalId = a.replica.deviceId;
    final backup = await a.backup();
    await a.restore(backup);
    expect(a.replica.deviceId, isNot(originalId));
    expect(
      (await a.replica.read(one.id))!.conflicts['body']!
          .map((v) => v.value)
          .toSet(),
      {'А', 'Б'},
    );
    final reloaded = (await a.notes()).single;
    reloaded.body = 'Объединено';
    await a.save(reloaded);
    expect((await a.replica.read(one.id))!.hasConflict, isFalse);
    await expectLater(a.save(one), throwsFormatException);
  });

  test(
    'Объединение со старого экрана не скрывает новую чужую редакцию',
    () async {
      final note = await a.createNote();
      await send(a, b);
      final other = (await b.notes()).single;
      note.body = 'А';
      other.body = 'Б';
      await a.save(note);
      await b.save(other);
      await send(b, a);
      final captured = (await a.replica.read(note.id))!;
      other.body = 'В';
      await b.save(other);
      await send(b, a);
      await a.resolveConflict(captured, {...captured.fields, 'body': 'А + Б'});
      expect(
        (await a.replica.read(note.id))!.conflicts['body']!
            .map((v) => v.value)
            .toSet(),
        {'А + Б', 'В'},
      );
      final latest = (await a.replica.read(note.id))!;
      await a.resolveConflict(latest, {...latest.fields, 'body': 'А + Б + В'});
      expect((await a.notes()).single.hasConflict, isFalse);
    },
  );

  test(
    'Несовпадение списка и журнала откатывает восстановление и идентификатор',
    () async {
      final note = await a.createNote();
      note.body = 'Сохранить';
      await a.save(note);
      final device = a.replica.deviceId;
      final count = await a.replica.operationCount();
      final envelope = jsonDecode(await a.backup()) as Map<String, dynamic>;
      final content =
          jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
      content['notes'] = [];
      content['revisions'] = [];
      final payload = jsonEncode(content);
      envelope['payload'] = payload;
      envelope['sha256'] = sha256.convert(utf8.encode(payload)).toString();
      await expectLater(a.restore(jsonEncode(envelope)), throwsFormatException);
      expect(a.replica.deviceId, device);
      expect(await a.replica.operationCount(), count);
      expect((await a.notes()).single.body, 'Сохранить');
    },
  );

  test('Копия v1 импортируется в новый журнал без переноса настроек', () async {
    final note = await a.createNote();
    note.body = 'Старая копия';
    await a.save(note);
    final envelope = jsonDecode(await a.backup()) as Map<String, dynamic>;
    final content =
        jsonDecode(envelope['payload'] as String) as Map<String, dynamic>;
    content.remove('operations');
    final payload = jsonEncode(content);
    envelope['version'] = 1;
    envelope['payload'] = payload;
    envelope['sha256'] = sha256.convert(utf8.encode(payload)).toString();
    await b.restore(jsonEncode(envelope));
    expect((await b.notes()).single.body, 'Старая копия');
    expect(await b.replica.operationCount(), 1);
  });

  test(
    'Миграция v1 создаёт проверенную копию и не меняет заметку или историю',
    () async {
      final directory = Directory('${root.path}/legacy');
      await directory.create();
      final path = '${directory.path}/ladno.sqlite';
      final db = await databaseFactoryFfi.openDatabase(path);
      final id = const Uuid().v4();
      await db.execute(
        'CREATE TABLE folders(id TEXT PRIMARY KEY, name TEXT NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE notes(id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL, folder_id TEXT, pinned INTEGER NOT NULL, deleted INTEGER NOT NULL, updated INTEGER NOT NULL, revision INTEGER NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE revisions(id TEXT PRIMARY KEY, note_id TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, created INTEGER NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      await db.insert(
        'notes',
        Note(
          id: id,
          title: 'До обновления',
          body: 'Не потерять',
          updated: 123,
          revision: 7,
        ).toMap(),
      );
      await db.setVersion(1);
      await db.close();
      final original = await File(path).readAsBytes();
      final migrated = await Store.open(databaseFactoryFfi, directory);
      try {
        expect(await migrated.db.getVersion(), 2);
        expect((await migrated.notes()).single.body, 'Не потерять');
        expect((await migrated.notes()).single.revision, 7);
        expect(await migrated.replica.operationCount(), 1);
        expect(await File('$path.before-v2').readAsBytes(), original);
        expect(
          (await migrated.db.rawQuery('PRAGMA integrity_check'))
              .single
              .values
              .single,
          'ok',
        );
      } finally {
        await migrated.close();
      }
    },
  );
}
