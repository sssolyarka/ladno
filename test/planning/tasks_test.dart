import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ladno/data/store.dart';
import 'package:ladno/planning/tasks.dart';
import 'package:ladno/planning/values.dart';
import 'package:ladno/sync/operation.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  late Store a, b;
  late TaskBook x, y;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ladno-tasks-');
    a = await Store.open(databaseFactoryFfi, Directory('${root.path}/a'));
    b = await Store.open(databaseFactoryFfi, Directory('${root.path}/b'));
    x = TaskBook(a);
    y = TaskBook(b);
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await root.delete(recursive: true);
  });
  Future<void> send(Store from, Store to) async {
    while (true) {
      final batch = await from.replica.outgoing(to.replica.deviceId);
      if (batch.operations.isEmpty) return;
      final ack = await to.replica.receive(
        batch,
        fromPeer: from.replica.deviceId,
      );
      await from.replica.acknowledge(to.replica.deviceId, ack);
    }
  }

  test('Задачи, проекты, подзадачи и теги переживают полный архив', () async {
    final project = await x.createProject('Учёба');
    final parent = await x.createTask({
      'title': 'Курсовая',
      'projectId': project,
      'priority': 3,
      'tags': ['учёба'],
    });
    await x.createTask({
      'title': 'Введение',
      'parentId': parent,
      'dueDate': '2026-11-12',
    });
    await b.restoreArchive(await a.fullBackup());
    expect((await y.projects()).single.fields['name'], 'Учёба');
    final tasks = await y.tasks();
    expect(tasks.length, 2);
    expect(tasks.where((t) => t.parentId == parent).single.title, 'Введение');
    expect(tasks.where((t) => t.id == parent).single.tags, ['учёба']);
  });
  test('Одновременное завершение повтора создаёт одного преемника, повтор идемпотентен', () async {
    final id = await x.createTask({
      'title': 'Зарядка',
      'dueDate': '2026-11-12',
      'repeat': 'daily',
      'anchorDay': 12,
    });
    await send(a, b);
    final first = (await x.tasks()).single, second = (await y.tasks()).single;
    final nextA = await x.complete(first), nextB = await y.complete(second);
    expect(nextA, nextB);
    await x.complete(first);
    await send(a, b);
    await send(b, a);
    for (final book in [x, y]) {
      final tasks = await book.tasks();
      expect(tasks.length, 2);
      expect(tasks.where((t) => t.id == id).single.status, 'done');
      final next = tasks.where((t) => t.id == nextA).single;
      expect(next.dueDate, '2026-11-13');
      expect(next.version.hasConflict, isFalse);
    }
  });
  test('Позднее завершение не перезаписывает удалённые правки', () async {
    await x.createTask({
      'title': 'Отчёт',
      'dueDate': '2026-11-12',
      'repeat': 'weekly',
      'anchorDay': 12,
    });
    await send(a, b);
    final stale = (await x.tasks()).single;
    await y.save((await y.tasks()).single, {'title': 'Итоговый отчёт'});
    await send(b, a);
    await x.complete(stale);
    final current = (await x.tasks()).firstWhere((t) => t.id == stale.id);
    expect(current.title, 'Итоговый отчёт');
    expect(current.status, 'done');
    expect(
      (await x.tasks()).firstWhere((t) => t.id != stale.id).title,
      'Итоговый отчёт',
    );
  });
  test('Сбой создания преемника откатывает и завершение', () async {
    await x.createTask({
      'title': 'Повтор',
      'dueDate': '2026-11-12',
      'repeat': 'daily',
      'anchorDay': 12,
    });
    final task = (await x.tasks()).single;
    final count = await a.replica.operationCount();
    await a.db.execute(
      "CREATE TRIGGER fail_successor BEFORE INSERT ON replica_ops WHEN NEW.object_id != '${task.id}' BEGIN SELECT RAISE(ABORT, 'test'); END",
    );
    await expectLater(x.complete(task), throwsA(anything));
    expect((await x.tasks()).single.status, 'open');
    expect(await a.replica.operationCount(), count);
  });
  test('Напоминание следующего повтора сохраняет отступ до срока', () async {
    final reminder = DateTime.utc(2026, 11, 11, 20).millisecondsSinceEpoch;
    await x.createTask({
      'title': 'Проверка',
      'dueDate': '2026-11-12',
      'repeat': 'weekly',
      'anchorDay': 12,
      'reminderAt': reminder,
    });
    final id = await x.complete((await x.tasks()).single);
    final next = (await x.tasks()).firstWhere((t) => t.id == id);
    expect(next.dueDate, '2026-11-19');
    expect(
      next.reminderAt,
      DateTime.utc(2026, 11, 18, 20).millisecondsSinceEpoch,
    );
  });
  test('Месячный повтор возвращается к исходному дню после февраля', () {
    final feb = nextDay(DateTime(2027, 1, 31), 'monthly', 31);
    expect(dayKey(feb), '2027-02-28');
    expect(dayKey(nextDay(feb, 'monthly', 31)), '2027-03-31');
    expect(dayKey(nextDay(DateTime(2028, 1, 31), 'monthly', 31)), '2028-02-29');
  });
  test(
    'Подзадачи не образуют круг, удаление родителя не теряет детей',
    () async {
      final parent = await x.createTask({'title': 'Родитель'});
      await x.createTask({'title': 'Дочь', 'parentId': parent});
      final tasks = await x.tasks();
      final p = tasks.firstWhere((t) => t.id == parent),
          child = tasks.firstWhere((t) => t.parentId == parent);
      await expectLater(
        x.save(p, {'parentId': child.id}),
        throwsFormatException,
      );
      await x.save(p, {'deleted': true});
      expect((await x.tasks()).single.id, child.id);
    },
  );
  test(
    'Независимые поля объединяются, одновременные заголовки сохраняют конфликт',
    () async {
      await x.createTask({'title': 'До'});
      await send(a, b);
      final left = (await x.tasks()).single, right = (await y.tasks()).single;
      await x.save(left, {'title': 'С ПК', 'priority': 3});
      await y.save(right, {
        'title': 'С телефона',
        'tags': ['дом'],
      });
      await send(a, b);
      await send(b, a);
      final merged = (await x.tasks()).single;
      expect(merged.priority, 3);
      expect(merged.tags, ['дом']);
      expect(merged.version.conflicts['title']!.length, 2);
      await x.save(merged, {'title': 'Объединено'}, resolve: true);
      await send(a, b);
      expect((await y.tasks()).single.version.hasConflict, isFalse);
    },
  );
  test('Невозможные даты и неизвестные поля отклоняются до записи', () async {
    for (final values in [
      <String, Object?>{'dueDate': '2026-02-30'},
      {'status': 'fake'},
      {'priority': 4},
      {
        'tags': ['x', 'x'],
      },
      {'repeat': 'hourly', 'dueDate': '2026-11-12'},
    ]) {
      await expectLater(
        x.createTask({'title': 'Проверка', ...values}),
        throwsA(isA<SyncProtocolException>()),
      );
    }
    expect(await x.tasks(), isEmpty);
  });
}
