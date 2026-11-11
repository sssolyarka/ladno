import 'package:flutter/material.dart';

import '../data/store.dart';
import '../sync/replica.dart';

class FolderConflicts extends StatefulWidget {
  final Store store;
  final void Function() onChanged;
  const FolderConflicts({
    super.key,
    required this.store,
    required this.onChanged,
  });
  @override
  State<FolderConflicts> createState() => _FolderConflictsState();
}

class _FolderConflictsState extends State<FolderConflicts> {
  Future<List<ReplicaObject>> load() async {
    final result = <ReplicaObject>[];
    for (final id in await widget.store.replica.objectIds()) {
      final value = await widget.store.replica.read(id);
      if (value != null && value.kind == 'folder' && value.hasConflict) {
        result.add(value);
      }
    }
    return result;
  }

  Future<void> resolve(ReplicaObject version) async {
    final name = TextEditingController(
      text: version.fields['name'] as String? ?? '',
    );
    var deleted = version.fields['deleted'] == true;
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: const Text('Объединить папку'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Выберите название. Заметки сохранятся при любом выборе.',
                  ),
                  for (final variant
                      in version.conflicts['name'] ?? <FieldVersion>[])
                    ListTile(
                      title: Text(variant.value as String),
                      trailing: const Icon(Icons.north_west),
                      onTap: () => name.text = variant.value as String,
                    ),
                  TextField(
                    controller: name,
                    maxLength: 1000,
                    decoration: const InputDecoration(
                      labelText: 'Название после объединения',
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('Папка удалена'),
                    subtitle: const Text(
                      'Выключите, чтобы вернуть папку в список.',
                    ),
                    value: deleted,
                    onChanged: (v) => setDialog(() => deleted = v),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, {
                'name': name.text.trim(),
                'deleted': deleted,
              }),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), name.dispose);
    if (result == null) return;
    try {
      await widget.store.replica.change(
        version.id,
        'folder',
        result,
        parents: version.heads,
      );
      widget.onChanged();
      if (mounted) setState(() {});
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось сохранить. Все варианты папки сохранены.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<ReplicaObject>>(
    future: load(),
    builder: (context, snapshot) {
      final conflicts = snapshot.data ?? [];
      if (conflicts.isEmpty) return const SizedBox.shrink();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          Text(
            'Конфликты папок: ${conflicts.length}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          for (final value in conflicts)
            ListTile(
              title: Text(value.fields['name'] as String? ?? 'Без названия'),
              trailing: const Icon(Icons.merge_type),
              onTap: () => resolve(value),
            ),
        ],
      );
    },
  );
}
