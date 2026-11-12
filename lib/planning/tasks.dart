import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../data/store.dart';
import '../sync/replica.dart';
import 'values.dart';

const taskStatuses = {
  'open': 'К выполнению',
  'doing': 'В работе',
  'done': 'Готово',
  'cancelled': 'Отменено',
};
const taskRepeats = {
  'none': 'Без повтора',
  'daily': 'Каждый день',
  'weekly': 'Каждую неделю',
  'monthly': 'Каждый месяц',
};
const taskPriorities = ['Без приоритета', 'Низкий', 'Средний', 'Высокий'];

class PlanTask {
  final ReplicaObject version;
  PlanTask(this.version);
  String get id => version.id;
  Map<String, Object?> get fields => version.fields;
  String get title => fields['title'] as String? ?? '';
  String get body => fields['body'] as String? ?? '';
  String get status => fields['status'] as String? ?? 'open';
  int get priority => fields['priority'] as int? ?? 0;
  bool get deleted => fields['deleted'] == true;
  bool get closed => status == 'done' || status == 'cancelled';
  String? get projectId => fields['projectId'] as String?;
  String? get parentId => fields['parentId'] as String?;
  String? get dueDate => fields['dueDate'] as String?;
  int? get reminderAt => fields['reminderAt'] as int?;
  String get repeat => fields['repeat'] as String? ?? 'none';
  List<String> get tags => (fields['tags'] as List? ?? []).cast<String>();
}

class TaskBook {
  final Store store;
  TaskBook(this.store);
  Future<List<PlanTask>> tasks({bool includeDeleted = false}) async {
    final result = <PlanTask>[];
    // A single read transaction gives a consistent snapshot to views/reminders.
    await store.db.transaction((tx) async {
      final replica = await Replica.attach(tx, inTransaction: true);
      for (final id in await replica.objectIds()) {
        final value = (await replica.read(id))!;
        if (value.kind == 'task' &&
            (includeDeleted || value.fields['deleted'] != true)) {
          result.add(PlanTask(value));
        }
      }
    });
    result.sort((a, b) {
      final closed = (a.closed ? 1 : 0).compareTo(b.closed ? 1 : 0);
      if (closed != 0) return closed;
      final date = (a.dueDate ?? '9999').compareTo(b.dueDate ?? '9999');
      if (date != 0) return date;
      final priority = b.priority.compareTo(a.priority);
      return priority != 0 ? priority : a.id.compareTo(b.id);
    });
    return result;
  }

  Future<List<ReplicaObject>> projects({bool includeDeleted = false}) async {
    final result = <ReplicaObject>[];
    for (final id in await store.replica.objectIds()) {
      final value = (await store.replica.read(id))!;
      if (value.kind == 'project' &&
          (includeDeleted || value.fields['deleted'] != true)) {
        result.add(value);
      }
    }
    result.sort(
      (a, b) => (a.fields['name'] as String? ?? '').compareTo(
        b.fields['name'] as String? ?? '',
      ),
    );
    return result;
  }

  Future<String> createProject(String name) async {
    if (name.trim().isEmpty) {
      throw const FormatException('Введите название проекта.');
    }
    final id = const Uuid().v4();
    await store.replica.change(id, 'project', {
      'name': name.trim(),
      'body': '',
      'status': 'active',
      'deleted': false,
    });
    return id;
  }

  Future<void> saveProject(ReplicaObject version, Map<String, Object?> patch) =>
      store.replica
          .change(version.id, 'project', patch, parents: version.heads)
          .then((_) {});
  Future<String> createTask(Map<String, Object?> fields) async {
    final id = const Uuid().v4();
    final values = <String, Object?>{
      'title': '',
      'body': '',
      'status': 'open',
      'priority': 0,
      'projectId': null,
      'parentId': null,
      'dueDate': null,
      'reminderAt': null,
      'repeat': 'none',
      'anchorDay': 1,
      'tags': <String>[],
      'deleted': false,
      ...fields,
    };
    await store.db.transaction((tx) async {
      final replica = await Replica.attach(tx, inTransaction: true);
      await _validate(replica, id, values);
      await replica.change(id, 'task', values);
    });
    return id;
  }

  Future<void> _validate(
    Replica replica,
    String id,
    Map<String, Object?> f,
  ) async {
    if ((f['title'] as String? ?? '').trim().isEmpty) {
      throw const FormatException('Введите название задачи.');
    }
    if (f['repeat'] != 'none' && f['dueDate'] == null) {
      throw const FormatException('Для повтора укажите срок.');
    }
    final project = f['projectId'] as String?;
    if (project != null) {
      final value = await replica.read(project);
      if (value == null ||
          value.kind != 'project' ||
          value.fields['deleted'] == true) {
        throw const FormatException('Выберите существующий проект.');
      }
    }
    var parent = f['parentId'] as String?;
    final seen = <String>{id};
    while (parent != null) {
      if (!seen.add(parent)) {
        throw const FormatException('Подзадачи не могут образовывать круг.');
      }
      final value = await replica.read(parent);
      if (value == null ||
          value.kind != 'task' ||
          value.fields['deleted'] == true) {
        throw const FormatException('Родительская задача недоступна.');
      }
      parent = value.fields['parentId'] as String?;
    }
  }

  Future<void> save(
    PlanTask task,
    Map<String, Object?> values, {
    bool resolve = false,
  }) async {
    await store.db.transaction((tx) async {
      final replica = await Replica.attach(tx, inTransaction: true);
      await _validate(replica, task.id, {...task.fields, ...values});
      final patch = <String, Object?>{
        for (final e in values.entries)
          if (resolve || jsonEncode(e.value) != jsonEncode(task.fields[e.key]))
            e.key: e.value,
      };
      if (patch.isNotEmpty) {
        await replica.change(
          task.id,
          'task',
          patch,
          parents: task.version.heads,
        );
      }
    });
  }

  /// Successor identity is derived from the occurrence, never from a device or
  /// completion time. Completion and successor are committed atomically.
  Future<String?> complete(PlanTask task) => store.db.transaction((tx) async {
    final replica = await Replica.attach(tx, inTransaction: true);
    final current = await replica.read(task.id);
    if (current == null || current.fields['deleted'] == true) {
      throw const FormatException('Задача удалена.');
    }
    if (current.fields['status'] == 'done') return null;
    await replica.change(task.id, 'task', {
      'status': 'done',
    }, parents: task.version.heads);
    final occurrence = PlanTask(current);
    if (occurrence.repeat == 'none' || occurrence.dueDate == null) return null;
    final date = parseDay(occurrence.dueDate)!;
    final next = nextDay(
      date,
      occurrence.repeat,
      occurrence.fields['anchorDay'] as int? ?? date.day,
    );
    if (next.year > 2199) {
      throw const FormatException(
        'Дата следующего повтора вне допустимого диапазона.',
      );
    }
    final id = const Uuid().v5(task.id, 'next');
    if (await replica.read(id) == null) {
      // UTC day offset is deterministic even when peers have different zones.
      // It also preserves a reminder set one or more days before the due date.
      final shift =
          DateTime.utc(next.year, next.month, next.day).millisecondsSinceEpoch -
          DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch;
      await replica.change(id, 'task', {
        ...occurrence.fields,
        'status': 'open',
        'deleted': false,
        'dueDate': dayKey(next),
        'reminderAt': occurrence.reminderAt == null
            ? null
            : occurrence.reminderAt! + shift,
      }, parents: []);
    }
    return id;
  });
}
