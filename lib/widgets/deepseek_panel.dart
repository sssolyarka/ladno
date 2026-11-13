import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sync/ai_client.dart';
import '../sync/backend_controller.dart';

class DeepSeekPanel extends StatefulWidget {
  final BackendSyncController sync;
  const DeepSeekPanel({super.key, required this.sync});
  @override
  State<DeepSeekPanel> createState() => _DeepSeekPanelState();
}

class _DeepSeekPanelState extends State<DeepSeekPanel> {
  final prompt = TextEditingController();
  String? answer, status;
  bool busy = false;
  @override
  void dispose() {
    prompt.dispose();
    super.dispose();
  }

  Future<void> request({bool check = false}) async {
    final connection = widget.sync.connection;
    if (connection == null) return;
    setState(() {
      busy = true;
      status = null;
    });
    try {
      final result = await aiRequest(
        connection,
        check ? '/v1/ai/status' : '/v1/ai/chat',
        prompt: check ? null : prompt.text.trim(),
      );
      if (!mounted) return;
      if (!identical(widget.sync.connection, connection)) {
        setState(() {
          answer = null;
          status = 'Подключение изменилось. Повторите запрос.';
        });
        return;
      }
      setState(() {
        if (check) {
          status = result['configured'] == true
              ? 'DeepSeek подключён на сервере.'
              : 'На сервере ещё не настроен ключ DeepSeek.';
        } else {
          final text = result['answer'];
          if (text is! String || text.trim().isEmpty) {
            throw const FormatException('Пустой ответ DeepSeek.');
          }
          answer = text;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => status = e is FormatException
              ? e.message
              : 'Не удалось связаться с сервером. Проверьте интернет и HTTPS.',
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
        Text('DeepSeek', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'В DeepSeek отправляется только текст из поля ниже, когда вы нажимаете «Отправить». Записи и вложения автоматически не передаются. Запросы расходуют баланс вашего аккаунта DeepSeek. Ответ не изменяет заметки и задачи.',
        ),
        if (widget.sync.connection == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Сначала подключите сервер в разделе выше.'),
          )
        else ...[
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: busy ? null : () => request(check: true),
              child: const Text('Проверить подключение DeepSeek'),
            ),
          ),
          TextField(
            controller: prompt,
            enabled: !busy,
            minLines: 3,
            maxLines: 8,
            maxLength: 12000,
            decoration: const InputDecoration(
              labelText: 'Запрос к DeepSeek',
              hintText: 'Например: помоги составить план подготовки к экзамену',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: busy
                  ? null
                  : () {
                      if (prompt.text.trim().isNotEmpty) request();
                    },
              child: Text(busy ? 'Ожидаю ответ…' : 'Отправить'),
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (status != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(status!),
            ),
          if (answer != null) ...[
            const SizedBox(height: 16),
            SelectableText(answer!),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: answer!)),
                icon: const Icon(Icons.copy),
                label: const Text('Скопировать ответ'),
              ),
            ),
          ],
        ],
      ],
    ),
  );
}
