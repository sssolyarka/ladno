import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/store.dart';
import 'tasks.dart';

abstract interface class ReminderBackend {
  Future<void> initialize();
  Future<bool> requestPermission();
  Future<Set<int>> pending();
  Future<void> cancel(int id);
  Future<void> schedule(int id, String taskId, String title, DateTime when);
  void dispose();
}

class NativeReminders implements ReminderBackend {
  final plugin = FlutterLocalNotificationsPlugin();
  final timers = <int, Timer>{};
  final void Function(String)? onOpen;
  NativeReminders({this.onOpen});
  static const details = NotificationDetails(
    android: AndroidNotificationDetails(
      'ladno_tasks_v1',
      'Напоминания о задачах',
      channelDescription: 'Сроки, заданные вами в Ладно',
      importance: Importance.high,
      priority: Priority.high,
      visibility: NotificationVisibility.private,
    ),
    linux: LinuxNotificationDetails(),
    windows: WindowsNotificationDetails(),
  );
  @override
  Future<void> initialize() async {
    final result = await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
        linux: LinuxInitializationSettings(defaultActionName: 'Открыть задачи'),
        windows: WindowsInitializationSettings(
          appName: 'Ладно',
          appUserModelId: 'ru.ladno.ladno',
          guid: 'c1befcf7-791e-4715-9ab6-b3f034c85037',
        ),
      ),
      onDidReceiveNotificationResponse: (r) {
        if (r.payload != null) onOpen?.call(r.payload!);
      },
    );
    if (result == false) throw StateError('Notification initialization failed');
    final launch = await plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      final taskId = launch?.notificationResponse?.payload;
      if (taskId != null) onOpen?.call(taskId);
    }
  }

  @override
  Future<bool> requestPermission() async =>
      !Platform.isAndroid ||
      (await plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false);
  @override
  Future<Set<int>> pending() async => Platform.isLinux
      ? timers.keys.toSet()
      : (await plugin.pendingNotificationRequests()).map((v) => v.id).toSet();
  @override
  Future<void> cancel(int id) async {
    timers.remove(id)?.cancel();
    await plugin.cancel(id: id);
  }

  @override
  Future<void> schedule(
    int id,
    String taskId,
    String title,
    DateTime when,
  ) async {
    if (Platform.isLinux) {
      timers.remove(id)?.cancel();
      timers[id] = Timer(when.difference(DateTime.now()), () {
        timers.remove(id);
        unawaited(
          plugin
              .show(
                id: id,
                title: title,
                body: 'Напоминание о задаче',
                notificationDetails: details,
                payload: taskId,
              )
              .catchError((Object _) {}),
        );
      });
    } else {
      await plugin.zonedSchedule(
        id: id,
        title: title,
        body: 'Напоминание о задаче',
        scheduledDate: tz.TZDateTime.from(when, tz.UTC),
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: taskId,
      );
    }
  }

  @override
  void dispose() {
    for (final timer in timers.values) {
      timer.cancel();
    }
    timers.clear();
  }
}

/// Local opt-in; preferences and scheduler receipts never enter sync/backup.
class ReminderService extends ChangeNotifier {
  final Store store;
  final ReminderBackend backend;
  final DateTime Function() clock;
  bool enabled = false, ready = false, busy = false, closed = false;
  String status = 'Напоминания на этом устройстве выключены';
  Future<void> queue = Future.value();
  ReminderService(
    this.store, {
    ReminderBackend? backend,
    DateTime Function()? clock,
  }) : backend = backend ?? NativeReminders(),
       clock = clock ?? DateTime.now;
  void announce() {
    if (!closed) notifyListeners();
  }

  Future<void> initialize() async {
    enabled = await store.setting('reminders.enabled') == 'true';
    if (enabled) await refresh();
    announce();
  }

  Future<void> setEnabled(bool value) async {
    busy = true;
    announce();
    try {
      if (!ready) {
        await backend.initialize();
        ready = true;
      }
      if (value && !await backend.requestPermission()) {
        status = 'ОС не разрешила уведомления. Разрешите их в настройках приложения.';
        return;
      }
      await store.setSetting('reminders.enabled', value.toString());
      enabled = value;
      await refresh();
    } catch (_) {
      status = 'Не удалось настроить уведомления. Задачи сохранены.';
    } finally {
      busy = false;
      announce();
    }
  }

  Future<void> refresh() {
    final next = queue.then((_) async {
      if (closed) return;
      try {
        await reconcile();
      } catch (_) {
        status = 'Не удалось обновить напоминания. Повторите попытку.';
      }
      announce();
    });
    queue = next.catchError((Object _) {});
    return next;
  }

  Future<void> reconcile() async {
    if (!enabled && !ready) return;
    if (!ready) {
      await backend.initialize();
      ready = true;
    }
    final now = clock().millisecondsSinceEpoch;
    final tasks =
        (await TaskBook(store).tasks())
            .where(
              (t) => !t.closed && t.reminderAt != null && t.reminderAt! > now,
            )
            .toList()
          ..sort((a, b) => a.reminderAt!.compareTo(b.reminderAt!));
    final desired = enabled ? tasks.take(64).toList() : <PlanTask>[];
    final previous = jsonDecode(
      await store.setting('reminders.plan') ?? '{}',
    ) as Map<String, dynamic>;
    final assigned = <int>{};
    final plan = <String, Object?>{};
    final pending = await backend.pending();
    for (final task in desired) {
      final bytes = sha256.convert(utf8.encode(task.id)).bytes;
      var id =
          ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
          0x7fffffff;
      while (!assigned.add(id)) {
        id = (id + 1) & 0x7fffffff;
      }
      plan['$id'] = {
        'task': task.id,
        'title': task.title,
        'at': task.reminderAt,
      };
    }
    // Receipts are written before OS calls, so a crash cannot orphan an ID.
    await store.setSetting(
      'reminders.plan',
      jsonEncode({...previous, ...plan}),
    );
    for (final id in {...pending, ...previous.keys.map(int.parse)}) {
      if (!plan.containsKey('$id') ||
          jsonEncode(previous['$id']) != jsonEncode(plan['$id'])) {
        await backend.cancel(id);
      }
    }
    for (final entry in plan.entries) {
      final id = int.parse(entry.key),
          value = entry.value as Map<String, Object?>;
      if (!pending.contains(id) ||
          jsonEncode(previous[entry.key]) != jsonEncode(value)) {
        await backend.schedule(
          id,
          value['task'] as String,
          value['title'] as String,
          DateTime.fromMillisecondsSinceEpoch(value['at'] as int),
        );
      }
    }
    await store.setSetting('reminders.plan', jsonEncode(plan));
    status = !enabled
        ? 'Напоминания на этом устройстве выключены'
        : 'Запланировано: ${plan.length}${tasks.length > 64 ? ' · ближайшие 64' : ''}';
  }

  @override
  void dispose() {
    closed = true;
    backend.dispose();
    super.dispose();
  }
}
