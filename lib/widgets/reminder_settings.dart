import 'dart:io';

import 'package:flutter/material.dart';

import '../planning/reminders.dart';

class ReminderSettings extends StatelessWidget {
  final ReminderService service;
  const ReminderSettings({super.key, required this.service});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 20),
        Text('Напоминания', style: Theme.of(context).textTheme.titleLarge),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Уведомления на этом устройстве'),
          subtitle: Text(service.status),
          value: service.enabled,
          onChanged: service.busy ? null : service.setEnabled,
        ),
        Text(
          Platform.isLinux
              ? 'На Linux напоминания работают, пока Ладно запущено. После закрытия приложения они не показываются.'
              : 'ОС хранит ближайшие 64 напоминания. На Android время может сдвигаться из-за энергосбережения. После принудительной остановки приложения откройте его снова.',
        ),
        const Text(
          'Разрешения и очередь уведомлений индивидуальны для устройства. Выполнение на другом устройстве отменяет напоминание после следующего обмена.',
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: service.busy ? null : service.refresh,
            child: const Text('Обновить напоминания'),
          ),
        ),
      ],
    ),
  );
}
