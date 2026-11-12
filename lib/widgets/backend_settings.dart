import 'package:flutter/material.dart';

import '../sync/backend_controller.dart';
import '../sync/backend_connection.dart';

class BackendSettings extends StatefulWidget {
  final BackendSyncController sync;
  const BackendSettings({super.key, required this.sync});
  @override
  State<BackendSettings> createState() => _BackendSettingsState();
}

class _BackendSettingsState extends State<BackendSettings> {
  late final TextEditingController url;
  final invite = TextEditingController(),
      name = TextEditingController(text: 'Моё устройство');
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    url = TextEditingController(
      text: widget.sync.connection?.endpoint.toString() ?? defaultBackendUrl,
    );
  }

  @override
  void dispose() {
    url.dispose();
    invite.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> action(Future<void> Function() work) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await work();
      if (mounted) setState(invite.clear);
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException ? e.message : 'Подключение не удалось. Проверьте HTTPS-сертификат, адрес и код подключения.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.sync,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Синхронизация с сервером',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        const Text(
          'Один сервер для Android и компьютеров. Записи остаются доступны без интернета; после подключения локальные изменения загрузятся на сервер. Сервер хранит содержимое записей, поэтому доступ к VPS должен быть только у владельца.',
        ),
        const SizedBox(height: 16),
        if (widget.sync.connection == null) ...[
          TextField(
            controller: url,
            enabled: !busy,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Адрес сервера',
              hintText: defaultBackendUrl,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: name,
            enabled: !busy,
            maxLength: 100,
            decoration: const InputDecoration(labelText: 'Имя устройства'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: invite,
            enabled: !busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Одноразовый код подключения',
              helperText: 'Выдаётся на сервере и действует 10 минут.',
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => action(
                      () =>
                          widget.sync.connect(url.text, invite.text, name.text),
                    ),
              icon: const Icon(Icons.cloud_outlined),
              label: Text(busy ? 'Подключаю…' : 'Подключить сервер'),
            ),
          ),
        ] else ...[
          SelectableText(widget.sync.connection!.endpoint.toString()),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Автоматический обмен'),
            subtitle: Text(widget.sync.status),
            value: widget.sync.enabled,
            onChanged: busy
                ? null
                : (v) => action(v ? widget.sync.enable : widget.sync.disable),
          ),
          if (widget.sync.syncedAt != null)
            Text(
              'Последний обмен: ${widget.sync.syncedAt!.toLocal().toString().substring(0, 19)}',
            ),
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: busy ? null : () => action(widget.sync.syncNow),
                icon: const Icon(Icons.sync),
                label: const Text('Синхронизировать сейчас'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        final yes = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Отключить сервер?'),
                            content: const Text(
                              'Записи на устройстве и сервере сохранятся. Для подключения заново понадобится новый код с сервера.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('Отмена'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Отключить'),
                              ),
                            ],
                          ),
                        );
                        if (yes == true) await action(widget.sync.disconnect);
                      },
                child: const Text('Отключить сервер'),
              ),
            ],
          ),
        ],
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 12),
        const Text(
          'Токен хранится в защищённом хранилище ОС и не входит в резервные копии. На телефоне обмен идёт при открытом приложении. Для отзыва потерянного устройства используйте управление на VPS.',
        ),
      ],
    ),
  );
}
