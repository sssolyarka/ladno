import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../sync/controller.dart';
import '../sync/pairing.dart';

class SyncSettings extends StatefulWidget {
  final SyncController sync;
  const SyncSettings({super.key, required this.sync});
  @override
  State<SyncSettings> createState() => _SyncSettingsState();
}

class _SyncSettingsState extends State<SyncSettings> {
  bool busy = false;
  List<String> hosts = [];
  String? host;
  Future<void> action(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось подключиться. Проверьте адрес, срок QR и локальную сеть.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> enable() async {
    await widget.sync.enable();
    hosts = await widget.sync.localAddresses();
    host = hosts.firstOrNull;
  }

  Future<void> join(String text) async {
    final invitation = PairInvitation.decode(text.trim());
    if (!widget.sync.enabled) {
      await enable();
    } else {
      await widget.sync.resume();
    }
    if (widget.sync.server == null) return;
    hosts = await widget.sync.localAddresses();
    host ??= hosts.firstOrNull;
    if (host == null) throw const FormatException('Нет адреса локальной сети.');
    final client = PairingClient(invitation, widget.sync.self(host!));
    final code = await client.request();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _JoinDialog(sync: widget.sync, client: client, code: code),
    );
  }

  Future<void> pasteAddress() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Адрес подключения'),
        content: TextField(
          controller: controller,
          maxLength: 16384,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Вставьте ladno-pair:… с другого устройства',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Подключить'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    if (text != null && mounted) await join(text);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.sync,
    builder: (context, _) {
      final sync = widget.sync;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(sync.status),
          const SizedBox(height: 8),
          const Text(
            'Обмен напрямую в локальной сети. На телефоне держите приложение открытым. Ключи сохраняются в защищённом хранилище ОС.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : () => action(enable),
                icon: const Icon(Icons.devices),
                label: Text(
                  sync.enabled
                      ? 'Проверить подключение'
                      : 'Включить подключение',
                ),
              ),
              if (sync.enabled)
                OutlinedButton(
                  onPressed: busy ? null : () => action(sync.syncNow),
                  child: const Text('Синхронизировать сейчас'),
                ),
              if (sync.enabled)
                TextButton(
                  onPressed: busy ? null : () => action(sync.disable),
                  child: const Text('Выключить обмен'),
                ),
            ],
          ),
          if (sync.server != null) ...[
            const SizedBox(height: 12),
            if (hosts.isNotEmpty)
              DropdownButtonFormField<String>(
                initialValue: host,
                decoration: const InputDecoration(
                  labelText: 'Адрес этого устройства',
                ),
                items: [
                  for (final h in hosts)
                    DropdownMenuItem(value: h, child: Text(h)),
                ],
                onChanged: (v) => setState(() => host = v),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => action(() async {
                          hosts = await sync.localAddresses();
                          host ??= hosts.firstOrNull;
                          if (host == null) {
                            throw const FormatException(
                              'Подключитесь к Wi-Fi.',
                            );
                          }
                          final server = await sync.beginPairing(host!);
                          if (!context.mounted) return;
                          await showDialog<void>(
                            context: context,
                            barrierDismissible: false,
                            builder: (_) => _HostDialog(
                              server: server,
                              host: host!,
                              sync: sync,
                            ),
                          );
                          if (server.pending?.completed != true) {
                            await sync.endPairing();
                          }
                          await sync.syncNow();
                        }),
                  icon: const Icon(Icons.qr_code),
                  label: const Text('Показать QR'),
                ),
                if (Platform.isAndroid)
                  OutlinedButton.icon(
                    onPressed: busy
                        ? null
                        : () => action(() async {
                            final text = await Navigator.push<String>(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const _Scanner(),
                              ),
                            );
                            if (text != null) await join(text);
                          }),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Сканировать QR'),
                  ),
                TextButton(
                  onPressed: busy ? null : () => action(pasteAddress),
                  child: const Text('Ввести адрес подключения'),
                ),
              ],
            ),
            SelectableText(
              'Порт защищённого обмена: ${sync.server!.port}. Если поиск заблокирован, используйте QR или скопированный адрес подключения.',
            ),
          ],
          for (final peer in sync.peers)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(peer.name),
              subtitle: Text(
                '${sync.peerStatus[peer.certificate.deviceId] ?? 'Доверенное устройство'}${sync.syncedAt[peer.certificate.deviceId] == null ? '' : ' · ${sync.syncedAt[peer.certificate.deviceId]!.toLocal().toString().substring(0, 19)}'}',
              ),
              trailing: IconButton(
                tooltip: 'Отозвать доверие',
                icon: const Icon(Icons.link_off),
                onPressed: () => action(() async {
                  final yes = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Отключить устройство?'),
                      content: const Text(
                        'Новые данные больше не будут передаваться. Уже сохранённые заметки останутся на обоих устройствах.',
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
                  if (yes == true) await sync.revoke(peer.certificate.deviceId);
                }),
              ),
            ),
        ],
      );
    },
  );
}

class _HostDialog extends StatefulWidget {
  final PairingServer server;
  final String host;
  final SyncController sync;
  const _HostDialog({
    required this.server,
    required this.host,
    required this.sync,
  });
  @override
  State<_HostDialog> createState() => _HostDialogState();
}

class _HostDialogState extends State<_HostDialog> {
  Timer? timer;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final server = widget.server, pair = server.pending;
    return AlertDialog(
      title: const Text('Подключить устройство'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!server.expired && pair == null) ...[
                const Text(
                  'Сканируйте QR на другом устройстве. Действует 2 минуты.',
                ),
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.all(8),
                  child: QrImageView(
                    data: server.invitation(widget.host).encode(),
                    size: 240,
                  ),
                ),
                TextButton(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: server.invitation(widget.host).encode(),
                      ),
                    );
                  },
                  child: const Text('Скопировать адрес подключения'),
                ),
              ],
              if (pair != null) ...[
                Text(pair.device.name),
                SelectableText(
                  pair.code,
                  style: const TextStyle(
                    fontSize: 36,
                    letterSpacing: 6,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Text(
                  'Сравните код на обоих экранах. Подтвердите только при полном совпадении.',
                ),
                if (pair.localApproved)
                  Text(
                    pair.completed
                        ? 'Устройство подключено'
                        : 'Ожидаем подтверждения второго устройства…',
                  ),
              ],
              if (server.expired)
                const Text('Код истёк. Закройте окно и создайте новый QR.'),
              if (error != null) Text(error!),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(pair?.completed == true ? 'Готово' : 'Отмена'),
        ),
        if (pair != null && !pair.localApproved && !server.expired)
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() => busy = true);
                    try {
                      await server.approve();
                    } on Object {
                      error = 'Не удалось сохранить доверие. Повторите подключение.';
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: const Text('Коды совпадают'),
          ),
      ],
    );
  }
}

class _JoinDialog extends StatefulWidget {
  final SyncController sync;
  final PairingClient client;
  final String code;
  const _JoinDialog({
    required this.sync,
    required this.client,
    required this.code,
  });
  @override
  State<_JoinDialog> createState() => _JoinDialogState();
}

class _JoinDialogState extends State<_JoinDialog> {
  Timer? timer;
  bool confirmed = false, busy = false;
  String? error;
  int retries = 0;
  Future<void> check() async {
    if (busy || !mounted) return;
    busy = true;
    try {
      final complete = confirmed
          ? await widget.client.status()
          : await widget.client.confirm();
      confirmed = true;
      if (complete && mounted) {
        timer?.cancel();
        await widget.sync.addPeer(widget.client.invitation.device);
        unawaited(widget.sync.syncNow());
        if (mounted) Navigator.pop(context);
        return;
      }
      if (++retries > 120) {
        timer?.cancel();
        error = 'Время подключения истекло. Начните заново.';
      }
    } on Object {
      timer?.cancel();
      error = 'Подключение прервано. Проверьте сеть и создайте новый QR.';
    } finally {
      busy = false;
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Проверьте код'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.client.invitation.device.name),
        SelectableText(
          widget.code,
          style: const TextStyle(
            fontSize: 36,
            letterSpacing: 6,
            fontWeight: FontWeight.bold,
          ),
        ),
        const Text('Код должен совпасть на двух устройствах.'),
        if (confirmed) const Text('Ожидаем подтверждения…'),
        if (error != null) Text(error!),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      if (!confirmed && error == null)
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  await check();
                  if (mounted && confirmed && error == null) {
                    timer = Timer.periodic(
                      const Duration(seconds: 1),
                      (_) => unawaited(check()),
                    );
                  }
                },
          child: const Text('Коды совпадают'),
        ),
    ],
  );
}

class _Scanner extends StatefulWidget {
  const _Scanner();
  @override
  State<_Scanner> createState() => _ScannerState();
}

class _ScannerState extends State<_Scanner> {
  bool done = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Сканируйте QR Ладно')),
    body: MobileScanner(
      onDetect: (capture) {
        for (final barcode in capture.barcodes) {
          final text = barcode.rawValue;
          if (!done && text != null && text.startsWith('ladno-pair:')) {
            done = true;
            Navigator.pop(context, text);
            break;
          }
        }
      },
    ),
  );
}
