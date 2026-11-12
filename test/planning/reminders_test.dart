import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ladno/data/store.dart';
import 'package:ladno/planning/tasks.dart';
import 'package:ladno/planning/reminders.dart';

class FakeReminders implements ReminderBackend {
  final scheduled = <int, (String, String, DateTime)>{};
  final cancelled = <int>[];
  bool allowed = true, fail = false;
  int calls = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> requestPermission() async => allowed;
  @override
  Future<Set<int>> pending() async => scheduled.keys.toSet();
  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
  }

  @override
  Future<void> schedule(
    int id,
    String taskId,
    String title,
    DateTime when,
  ) async {
    if (fail) throw StateError('test');
    calls++;
    scheduled[id] = (taskId, title, when);
  }

  @override
  void dispose() {}
}

void main() {
  sqfliteFfiInit();
  late Directory root;
  late Store store;
  late TaskBook book;
  late FakeReminders backend;
  late ReminderService service;
  final now = DateTime(2026, 11, 12, 9);
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ladno-reminder-');
    store = await Store.open(databaseFactoryFfi, root);
    book = TaskBook(store);
    backend = FakeReminders();
    service = ReminderService(store, backend: backend, clock: () => now);
  });
  tearDown(() async {
    await service.queue;
    service.dispose();
    await store.close();
    await root.delete(recursive: true);
  });
  Future<String> task(String title, int minutes) => book.createTask({
    'title': title,
    'reminderAt': now.add(Duration(minutes: minutes)).millisecondsSinceEpoch,
  });
  test(
    'Без согласия нет расписания, отказ разрешения не включает настройку',
    () async {
      await task('Задача', 10);
      await service.initialize();
      expect(backend.scheduled, isEmpty);
      backend.allowed = false;
      await service.setEnabled(true);
      expect(service.enabled, isFalse);
      expect(backend.scheduled, isEmpty);
    },
  );
  test(
    'Напоминание переживает повтор расчёта, выполнение отменяет его',
    () async {
      await task('Позвонить', 10);
      await service.setEnabled(true);
      expect(backend.scheduled.length, 1);
      expect(backend.calls, 1);
      await service.refresh();
      expect(backend.calls, 1);
      await book.complete((await book.tasks()).single);
      await service.refresh();
      expect(backend.scheduled, isEmpty);
      expect(backend.cancelled.length, 1);
    },
  );
  test('Изменение срока пересоздаёт уведомление с тем же ID', () async {
    await task('Купить', 10);
    await service.setEnabled(true);
    final id = backend.scheduled.keys.single;
    await book.save((await book.tasks()).single, {
      'reminderAt': now.add(const Duration(hours: 2)).millisecondsSinceEpoch,
    });
    await service.refresh();
    expect(backend.scheduled.keys.single, id);
    expect(backend.scheduled[id]!.$3, now.add(const Duration(hours: 2)));
    expect(backend.calls, 2);
  });
  test(
    'Отключение отменяет очередь; просроченные не всплывают заново',
    () async {
      await task('Прошло', -10);
      await task('Будущее', 10);
      await service.setEnabled(true);
      expect(backend.scheduled.length, 1);
      await service.setEnabled(false);
      expect(backend.scheduled, isEmpty);
      expect(service.enabled, isFalse);
    },
  );
  test('После сбоя планирования повтор восстанавливает очередь', () async {
    await task('Повторить', 10);
    backend.fail = true;
    await service.setEnabled(true);
    expect(backend.scheduled, isEmpty);
    expect(service.status, contains('Не удалось'));
    backend.fail = false;
    await service.refresh();
    expect(backend.scheduled.length, 1);
  });
  test('После восстановления копии прежние напоминания снимаются', () async {
    final empty = await store.fullBackup();
    await task('Старое', 10);
    await service.setEnabled(true);
    expect(backend.scheduled.length, 1);
    await store.restoreArchive(empty);
    await service.refresh();
    expect(backend.scheduled, isEmpty);
  });
}
