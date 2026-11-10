import 'package:flutter/material.dart';

import '../sync/replica.dart';

/// Edits an explicitly captured causal frontier. New arrivals are never
/// silently included in the resolution's parents.
class ConflictDialog extends StatefulWidget {
  final ReplicaObject version;
  final Map<String, String> folders;
  const ConflictDialog({
    super.key,
    required this.version,
    required this.folders,
  });
  @override
  State<ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<ConflictDialog> {
  late final TextEditingController title, body;
  late final Map<String, Object?> fields;
  @override
  void initState() {
    super.initState();
    fields = Map.of(widget.version.fields);
    title = TextEditingController(text: fields['title'] as String? ?? '');
    body = TextEditingController(text: fields['body'] as String? ?? '');
  }

  @override
  void dispose() {
    title.dispose();
    body.dispose();
    super.dispose();
  }

  Widget textVersions(
    String field,
    String label,
    TextEditingController controller,
  ) {
    final variants = widget.version.conflicts[field] ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (variants.isNotEmpty) ...[
          Text(
            '$label: сохранённые варианты',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          for (var i = 0; i < variants.length; i++)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(
                      variants[i].value as String,
                      maxLines: field == 'body' ? 4 : 3,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () =>
                            controller.text = variants[i].value as String,
                        child: Text('Взять вариант ${i + 1}'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
        TextField(
          controller: controller,
          maxLength: field == 'body' ? 1000000 : 1000,
          minLines: field == 'body' ? 5 : 1,
          maxLines: field == 'body' ? 12 : 2,
          decoration: InputDecoration(
            labelText: '$label после объединения',
            counterText: '',
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  String describe(String field, Object? value) {
    if (field == 'folderId') {
      return value == null
          ? 'Без папки'
          : widget.folders[value] ?? 'Недоступная папка';
    }
    if (field == 'pinned') {
      return value == true ? 'Закреплена' : 'Не закреплена';
    }
    if (field == 'attachments') {
      final list = value as List;
      return list.isEmpty
          ? 'Без вложений'
          : list.map((v) => (v as Map)['name']).join(', ');
    }
    return '$value';
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Объединить версии'),
    content: SizedBox(
      width: 640,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Сохранены изменения с разных устройств. Выберите варианты или соберите общий текст. До сохранения обе версии останутся в журнале.',
            ),
            const SizedBox(height: 16),
            textVersions('title', 'Название', title),
            textVersions('body', 'Текст', body),
            for (final field in ['folderId', 'pinned', 'attachments'])
              if (widget.version.conflicts.containsKey(field)) ...[
                Text(
                  {
                    'folderId': 'Папка',
                    'pinned': 'Закрепление',
                    'attachments': 'Вложения',
                  }[field]!,
                ),
                for (final variant in widget.version.conflicts[field]!)
                  CheckboxListTile(
                    value:
                        identical(fields[field], variant.value) ||
                        fields[field] == variant.value,
                    title: Text(describe(field, variant.value)),
                    controlAffinity: ListTileControlAffinity.leading,
                    onChanged: (_) =>
                        setState(() => fields[field] = variant.value),
                  ),
              ],
            if (widget.version.conflicts.containsKey('deleted') ||
                widget.version.conflicts.containsKey('deletionVsEdit'))
              SwitchListTile(
                title: const Text('Оставить в корзине'),
                subtitle: const Text(
                  'Текст выше сохранится и в корзине. Выключите, чтобы вернуть заметку.',
                ),
                value: fields['deleted'] == true,
                onChanged: (v) => setState(() => fields['deleted'] = v),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          fields['title'] = title.text;
          fields['body'] = body.text;
          Navigator.pop(context, fields);
        },
        child: const Text('Сохранить объединение'),
      ),
    ],
  );
}
