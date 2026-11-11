import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:ladno/sync/operation.dart';
import 'package:ladno/sync/replica.dart';

const uuid = Uuid();

/// Test transport only: serialization is real, network/authentication is not.
Future<void> send(Replica from, Replica to) async {
  for (var attempt = 0; attempt < 1000; attempt++) {
    final batch = await from.outgoing(to.deviceId);
    if (batch.operations.isEmpty) return;
    final receipts = await to.receive(SyncBatch.decode(batch.encode()));
    await from.acknowledge(to.deviceId, receipts);
  }
  fail('Не удалось опустошить очередь');
}

Future<void> exchange(Replica a, Replica b) async {
  await send(a, b);
  await send(b, a);
  await send(a, b);
}

void main() {
  sqfliteFfiInit();
  late Directory root;
  late Replica a, b;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ladno-replica-');
    a = await Replica.open(databaseFactoryFfi, Directory('${root.path}/a'));
    b = await Replica.open(databaseFactoryFfi, Directory('${root.path}/b'));
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await root.delete(recursive: true);
  });
  Future<String> note() async {
    final id = uuid.v4();
    await a.change(id, 'note', {
      'title': 'Заметка',
      'body': 'Исходный текст',
      'pinned': false,
      'deleted': false,
      'folderId': null,
      'attachments': [],
    });
    await exchange(a, b);
    return id;
  }

  test('Локальный журнал и идентификатор переживают перезапуск', () async {
    final id = uuid.v4();
    final device = a.deviceId;
    final first = await a.change(id, 'note', {'body': 'Привет 👋'});
    await a.close();
    a = await Replica.open(databaseFactoryFfi, Directory('${root.path}/a'));
    expect(a.deviceId, device);
    final second = await a.change(id, 'note', {'body': 'Ćao'});
    expect(second.sequence, first.sequence + 1);
    expect(second.parents, [first.id]);
    expect((await a.read(id))!.fields['body'], 'Ćao');
  });
  test('Повторная доставка и потеря ACK не создают дубли', () async {
    final id = uuid.v4();
    await a.change(id, 'note', {'body': 'Важное'});
    final packet = await a.outgoing(b.deviceId);
    // The receiver commits. The connection breaks before its ACK reaches A.
    await b.receive(SyncBatch.decode(packet.encode()));
    expect((await a.outgoing(b.deviceId)).operations, hasLength(1));
    await b.close();
    b = await Replica.open(databaseFactoryFfi, Directory('${root.path}/b'));
    await exchange(a, b);
    await exchange(a, b);
    expect(await a.operationCount(), 1);
    expect(await b.operationCount(), 1);
    expect((await b.read(id))!.fields['body'], 'Важное');
    expect((await a.outgoing(b.deviceId)).operations, isEmpty);
  });
  test('Офлайн-редакции текста сохраняются обе и сходятся', () async {
    final id = await note();
    await a.change(id, 'note', {'body': 'Редакция ПК'});
    await b.change(id, 'note', {'body': 'Редакция телефона'});
    await exchange(a, b);
    final left = (await a.read(id))!, right = (await b.read(id))!;
    expect(left.fields, right.fields);
    expect(left.heads, right.heads);
    expect(left.conflicts['body']!.map((v) => v.value).toSet(), {
      'Редакция ПК',
      'Редакция телефона',
    });
    expect(right.hasConflict, isTrue);
  });
  test('Явное объединение ссылается на все конкурирующие heads', () async {
    final id = await note();
    await a.change(id, 'note', {'body': 'ПК'});
    await b.change(id, 'note', {'body': 'Телефон'});
    await exchange(a, b);
    final conflict = (await a.read(id))!;
    final resolved = await a.change(id, 'note', {
      'body': 'ПК + Телефон',
    }, parents: conflict.heads);
    expect(resolved.parents, conflict.heads);
    await exchange(a, b);
    expect((await b.read(id))!.hasConflict, isFalse);
    expect((await b.read(id))!.fields['body'], 'ПК + Телефон');
    expect(await b.operationCount(), 4); // The old versions are retained.
  });
  test('Разные поля объединяются без ложного конфликта', () async {
    final id = await note();
    await a.change(id, 'note', {'body': 'Новый текст'});
    await b.change(id, 'note', {'pinned': true});
    await exchange(a, b);
    final value = (await a.read(id))!;
    expect(value.hasConflict, isFalse);
    expect(value.fields['body'], 'Новый текст');
    expect(value.fields['pinned'], isTrue);
    expect((await b.read(id))!.fields, value.fields);
  });
  test('Одинаковый конкурентный текст не показывается как конфликт', () async {
    final id = await note();
    await a.change(id, 'note', {'body': 'Одинаково'});
    await b.change(id, 'note', {'body': 'Одинаково'});
    await exchange(a, b);
    expect((await a.read(id))!.hasConflict, isFalse);
    expect(await a.operationCount(), 3);
  });
  test(
    'Устаревший редактор на одном устройстве не скрывает новую редакцию',
    () async {
      final id = await note();
      final oldHeads = (await a.read(id))!.heads;
      await a.change(id, 'note', {'body': 'Более новая редакция'});
      await a.change(id, 'note', {
        'body': 'Текст из старого редактора',
      }, parents: oldHeads);
      expect((await a.read(id))!.conflicts['body'], hasLength(2));
    },
  );
  test(
    'Удаление против редактирования остаётся в корзине с обеими версиями',
    () async {
      final id = await note();
      await a.change(id, 'note', {'deleted': true});
      await b.change(id, 'note', {'body': 'Изменено без связи'});
      await exchange(a, b);
      final value = (await a.read(id))!;
      expect(value.fields['deleted'], isTrue);
      expect(value.fields['body'], 'Изменено без связи');
      expect(value.conflicts, contains('deletionVsEdit'));
      await a.change(id, 'note', {'deleted': false}, parents: value.heads);
      await exchange(a, b);
      expect((await b.read(id))!.fields['deleted'], isFalse);
      expect((await b.read(id))!.hasConflict, isFalse);
    },
  );
  test('Давно отсутствовавшее устройство не воскрешает удаление', () async {
    final id = await note();
    final c = await Replica.open(
      databaseFactoryFfi,
      Directory('${root.path}/old'),
    );
    try {
      await exchange(a, c);
      await a.change(id, 'note', {'deleted': true});
      await exchange(a, b);
      await c.change(id, 'note', {'body': 'Старая офлайн-редакция'});
      await exchange(b, c);
      await exchange(a, b);
      expect((await c.read(id))!.fields['deleted'], isTrue);
      expect((await a.read(id))!.fields['body'], 'Старая офлайн-редакция');
      expect((await a.read(id))!.hasConflict, isTrue);
    } finally {
      await c.close();
    }
  });
  test(
    'Потомок перед родителем сохраняется и применяется после перезапуска',
    () async {
      final id = uuid.v4();
      final parent = await a.change(id, 'note', {'body': 'Первый'});
      final child = await a.change(id, 'note', {'body': 'Второй'});
      expect(await b.receive(SyncBatch([child])), [child.id]);
      expect(await b.pendingCount(), 1);
      expect(await b.read(id), isNull);
      await b.close();
      b = await Replica.open(databaseFactoryFfi, Directory('${root.path}/b'));
      await b.receive(SyncBatch([parent]));
      expect(await b.pendingCount(), 0);
      expect((await b.read(id))!.fields['body'], 'Второй');
    },
  );
  test(
    'Пакет с изменённым содержимым того же ID откатывается целиком',
    () async {
      final id = uuid.v4();
      final op = await a.change(id, 'note', {'body': 'Оригинал'});
      final changed = SyncOperation.fromJson({
        ...op.toJson(),
        'fields': {'body': 'Подмена'},
      });
      await expectLater(
        b.receive(SyncBatch([op, changed])),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(await b.operationCount(), 0);
      expect(await b.read(id), isNull);
    },
  );
  test('Подтверждения сохраняются после перезапуска и отзыва', () async {
    await note();
    final peer = b.deviceId;
    await a.close();
    a = await Replica.open(databaseFactoryFfi, Directory('${root.path}/a'));
    expect((await a.outgoing(peer)).operations, isEmpty);
    await a.forgetReceipts(peer);
    expect((await a.outgoing(peer)).operations, hasLength(1));
    await exchange(a, b);
    expect(await b.operationCount(), 1);
  });
  test('Неизвестное подтверждение не продвигает очередь частично', () async {
    final op = await a.change(uuid.v4(), 'note', {'body': 'Текст'});
    await expectLater(
      a.acknowledge(b.deviceId, [op.id, '${uuid.v4()}:1']),
      throwsA(isA<SyncProtocolException>()),
    );
    expect((await a.outgoing(b.deviceId)).operations, hasLength(1));
  });
  test('Пагинация доставляет больше одного пакета без пропусков', () async {
    for (var i = 0; i < 70; i++) {
      await a.change(uuid.v4(), 'note', {'body': 'Заметка $i'});
    }
    expect((await a.outgoing(b.deviceId)).operations, hasLength(64));
    await exchange(a, b);
    expect(await b.objectIds(), hasLength(70));
    expect(await b.operationCount(), 70);
  });
  test('Случайный порядок доставки DAG даёт одинаковый результат', () async {
    final id = await note();
    await a.change(id, 'note', {'body': 'A'});
    await b.change(id, 'note', {'body': 'B'});
    await exchange(a, b);
    final ops = (await a.outgoing(uuid.v4())).operations;
    for (var seed = 0; seed < 6; seed++) {
      final c = await Replica.open(
        databaseFactoryFfi,
        Directory('${root.path}/shuffle-$seed'),
      );
      try {
        final shuffled = [...ops]..shuffle(Random(seed));
        for (final op in shuffled) {
          await c.receive(SyncBatch([op]));
        }
        expect((await c.read(id))!.fields, (await a.read(id))!.fields);
        expect((await c.read(id))!.heads, (await a.read(id))!.heads);
        expect(await c.pendingCount(), 0);
      } finally {
        await c.close();
      }
    }
  });
  test(
    'Несовместимая версия и неизвестные поля отклоняются до записи',
    () async {
      final op = await a.change(uuid.v4(), 'note', {'body': 'Текст'});
      expect(
        () => SyncBatch.decode(
          jsonEncode({
            'protocol': 999,
            'operations': [op.toJson()],
          }),
        ),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(
        () => SyncOperation.fromJson({
          ...op.toJson(),
          'fields': {'sql': 'DROP TABLE notes'},
        }),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(
        () => SyncOperation.fromJson({
          ...op.toJson(),
          'fields': {'updated': 99999999999},
        }),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(await b.operationCount(), 0);
    },
  );
  test('Связь с другим объектом и смена типа запрещены', () async {
    final first = await a.change(uuid.v4(), 'note', {'body': 'Один'});
    await expectLater(
      a.change(uuid.v4(), 'note', {'body': 'Другой'}, parents: [first.id]),
      throwsA(isA<SyncProtocolException>()),
    );
    await expectLater(
      a.change(first.objectId, 'folder', {'name': 'Подмена типа'}),
      throwsA(isA<SyncProtocolException>()),
    );
    final second = await a.change(first.objectId, 'note', {'body': 'Два'});
    expect(second.sequence, 2);
  });
  test('Коллизия собственного origin запрещена', () async {
    final forged = SyncOperation(
      origin: b.deviceId,
      sequence: 1,
      logical: 1,
      objectId: uuid.v4(),
      kind: 'note',
      parents: [],
      fields: {'body': 'Копия устройства'},
    );
    await expectLater(
      b.receive(SyncBatch([forged])),
      throwsA(isA<SyncProtocolException>()),
    );
    expect(await b.operationCount(), 0);
  });
  test('Метаданные вложения приходят без ожидания большого файла', () async {
    final attachment = AttachmentDescriptor(
      hash: 'a' * 64,
      name: 'Фотография.png',
      size: 10000000,
    );
    final id = uuid.v4();
    await a.change(id, 'note', {
      'body': 'Текст уже доступен',
      'attachments': [attachment.toJson()],
    });
    await exchange(a, b);
    expect((await b.read(id))!.fields['body'], 'Текст уже доступен');
    expect((await b.read(id))!.fields['attachments'], hasLength(1));
  });
  test(
    'Операции не изменяются через вложенные списки вызывающего кода',
    () async {
      final descriptor = AttachmentDescriptor(
        hash: 'b' * 64,
        name: 'Файл',
        size: 1,
      );
      final input = [descriptor.toJson()];
      final op = await a.change(uuid.v4(), 'note', {'attachments': input});
      input.clear();
      expect(op.fields['attachments'], hasLength(1));
      expect(
        () => (op.fields['attachments'] as List).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => ((op.fields['attachments'] as List).first as Map)['name'] =
            'Подмена',
        throwsUnsupportedError,
      );
    },
  );
  test('Каноническая сериализация не зависит от порядка ключей JSON', () async {
    final descriptor = AttachmentDescriptor(
      hash: 'c' * 64,
      name: 'Файл',
      size: 4,
    );
    final op = await a.change(uuid.v4(), 'note', {
      'attachments': [descriptor.toJson()],
    });
    final equivalent = SyncOperation.fromJson({
      ...op.toJson(),
      'fields': {
        'attachments': [
          {'size': 4, 'name': 'Файл', 'hash': 'c' * 64},
        ],
      },
    });
    expect(op.encode(), equivalent.encode());
    await b.receive(SyncBatch([op, equivalent]));
    expect(await b.operationCount(), 1);
  });
  test('Папки имеют независимые операции и отметки об удалении', () async {
    final folder = uuid.v4();
    await a.change(folder, 'folder', {'name': 'Личное', 'deleted': false});
    await exchange(a, b);
    await b.change(folder, 'folder', {'name': 'Дом'});
    await a.change(folder, 'folder', {'deleted': true});
    await exchange(a, b);
    expect((await a.read(folder))!.fields['deleted'], isTrue);
    expect((await a.read(folder))!.fields['name'], 'Дом');
    expect((await a.read(folder))!.hasConflict, isTrue);
  });
  test('Лимиты и неправильные идентификаторы отклоняются', () async {
    expect(
      () => SyncOperation(
        origin: '../bad',
        sequence: 1,
        logical: 1,
        objectId: uuid.v4(),
        kind: 'note',
        parents: [],
        fields: {'body': 'Текст'},
      ),
      throwsA(isA<SyncProtocolException>()),
    );
    await expectLater(
      a.change(uuid.v4(), 'note', {'body': 'x' * 1000001}),
      throwsA(isA<SyncProtocolException>()),
    );
    expect(await a.operationCount(), 0);
    final op = await a.change(uuid.v4(), 'note', {'body': 'Текст'});
    expect(
      () => SyncBatch(List.filled(65, op)),
      throwsA(isA<SyncProtocolException>()),
    );
  });
  test(
    'Большие тексты разбиваются на пакеты по байтам без пропусков',
    () async {
      for (var i = 0; i < 5; i++) {
        await a.change(uuid.v4(), 'note', {'body': 'я' * 900000});
      }
      final packet = await a.outgoing(b.deviceId);
      expect(packet.operations, hasLength(4));
      expect(
        utf8.encode(packet.encode()).length,
        lessThanOrEqualTo(maxSyncBatchBytes),
      );
      await exchange(a, b);
      expect(await b.objectIds(), hasLength(5));
      expect((await a.outgoing(b.deviceId)).operations, isEmpty);
    },
  );
  test(
    'Лимит параллельных редакций не блокирует их последующее объединение',
    () async {
      final id = uuid.v4();
      for (var i = 0; i < 64; i++) {
        await a.change(id, 'note', {'body': 'Вариант $i'}, parents: []);
      }
      await expectLater(
        a.change(id, 'note', {'body': 'Лишняя ветвь'}, parents: []),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(await a.operationCount(), 64);
      final resolved = await a.change(id, 'note', {
        'body': 'Объединено',
      }, parents: (await a.read(id))!.heads);
      expect(resolved.sequence, 65);
      expect((await a.read(id))!.hasConflict, isFalse);
    },
  );
}
