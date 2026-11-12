import 'dart:async';

import 'package:flutter/material.dart';

import '../data/store.dart';
import '../planning/tasks.dart';
import '../planning/values.dart';
import '../sync/replica.dart';

class TaskBoard extends StatefulWidget {
  final Store store;
  final String section;
  final int revision;
  final VoidCallback onChanged;
  const TaskBoard({
    super.key,
    required this.store,
    required this.section,
    required this.revision,
    required this.onChanged,
  });
  @override
  State<TaskBoard> createState() => _TaskBoardState();
}

class _TaskBoardState extends State<TaskBoard> {
  TaskBook get book => TaskBook(widget.store);
  List<PlanTask> tasks = [];
  List<ReplicaObject> projects = [];
  String query = '';
  String? projectId;
  bool showClosed = false, loading = true;
  String? error;
  DateTime selectedDay = DateTime.now();
  int generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant TaskBoard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision ||
        oldWidget.section != widget.section) {
      unawaited(load());
    }
  }

  Future<void> load() async {
    final token = ++generation;
    try {
      final nextTasks = await book.tasks(includeDeleted: true);
      final nextProjects = await book.projects(includeDeleted: true);
      if (mounted && token == generation) {
        setState(() {
          tasks = nextTasks;
          projects = nextProjects;
          loading = false;
          error = null;
        });
      }
    } catch (_) {
      if (mounted && token == generation) {
        setState(() {
          loading = false;
          error = 'Не удалось прочитать задачи. Повторите загрузку.';
        });
      }
    }
  }

  Future<void> changed() async {
    widget.onChanged();
    await load();
  }

  void failure(Object e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e is FormatException
                ? e.message
                : 'Не удалось сохранить. Данные на экране не подтверждены.',
          ),
        ),
      );
    }
  }

  Future<void> edit([PlanTask? task, String? parent]) async {
    final id = await showDialog<String>(
      context: context,
      builder: (ctx) => TaskEditor(
        book: book,
        task: task,
        projects: projects,
        tasks: tasks,
        initialProject: projectId,
        initialParent: parent,
        initialDate: widget.section == 'Сегодня'
            ? dayKey(DateTime.now())
            : widget.section == 'Календарь'
            ? dayKey(selectedDay)
            : null,
      ),
    );
    if (id != null) await changed();
  }

  Future<void> project([ReplicaObject? value]) async {
    final name = TextEditingController(
      text: value?.fields['name'] as String? ?? '',
    );
    String? problem;
    var saving = false;
    var archived = value?.fields['status'] == 'done';
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(value == null ? 'Новый проект' : 'Изменить проект'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    autofocus: true,
                    maxLength: 1000,
                    decoration: InputDecoration(
                      labelText: 'Название проекта',
                      errorText: problem,
                    ),
                  ),
                  if (value != null)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Проект завершён'),
                      value: archived,
                      onChanged: saving
                          ? null
                          : (v) => update(() => archived = v),
                    ),
                  if (value?.hasConflict == true) ...[
                    const Text(
                      'Есть разные варианты. Выберите название или введите объединённое.',
                    ),
                    for (final variant
                        in value!.conflicts['name'] ?? <FieldVersion>[])
                      TextButton(
                        onPressed: () => name.text = variant.value as String,
                        child: Text(variant.value as String),
                      ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(ctx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (name.text.trim().isEmpty) {
                        update(() => problem = 'Введите название');
                        return;
                      }
                      update(() => saving = true);
                      try {
                        if (value == null) {
                          await book.createProject(name.text);
                        } else {
                          await book.saveProject(value, {
                            'name': name.text.trim(),
                            'status': archived ? 'done' : 'active',
                            'deleted': false,
                          });
                        }
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (_) {
                        if (ctx.mounted) {
                          update(() {
                            saving = false;
                            problem = 'Не удалось сохранить проект';
                          });
                        }
                      }
                    },
              child: Text(saving ? 'Сохраняю…' : 'Сохранить'),
            ),
          ],
        ),
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), name.dispose);
    if (saved == true) await changed();
  }

  String projectName(String? id) =>
      projects
          .where((p) => p.id == id)
          .map(
            (p) =>
                '${p.fields['name']}${p.fields['deleted'] == true ? ' (удалён)' : ''}',
          )
          .firstOrNull ??
      'Без проекта';
  List<PlanTask> get visible {
    final today = dayKey(DateTime.now());
    return tasks.where((t) {
      if (widget.section == 'Архив задач' ? !t.deleted : t.deleted) {
        return false;
      }
      if (!showClosed && t.closed && widget.section != 'Архив задач') {
        return false;
      }
      if (projectId != null && t.projectId != projectId) return false;
      if (widget.section == 'Входящие' &&
          (t.projectId != null || t.dueDate != null)) {
        return false;
      }
      if (widget.section == 'Сегодня' &&
          (t.dueDate == null || t.dueDate!.compareTo(today) > 0)) {
        return false;
      }
      if (widget.section == 'Предстоящие' &&
          (t.dueDate == null || t.dueDate!.compareTo(today) <= 0)) {
        return false;
      }
      if (widget.section == 'Календарь' && t.dueDate != dayKey(selectedDay)) {
        return false;
      }
      final haystack = '${t.title} ${t.body} ${t.tags.join(' ')}'.toLowerCase();
      return haystack.contains(query.toLowerCase());
    }).toList();
  }

  Widget row(PlanTask t) {
    final today = dayKey(DateTime.now());
    final parent = tasks.where((p) => p.id == t.parentId).firstOrNull;
    final subtitle = <String>[
      if (t.dueDate != null)
        '${t.dueDate}${!t.closed && t.dueDate!.compareTo(today) < 0 ? ' · просрочено' : ''}',
      if (t.projectId != null) projectName(t.projectId),
      if (parent != null) 'Подзадача: ${parent.title}',
      if (t.priority > 0) taskPriorities[t.priority],
      if (t.repeat != 'none') taskRepeats[t.repeat]!,
      if (t.tags.isNotEmpty) t.tags.map((v) => '#$v').join(' '),
      if (t.version.hasConflict)
        'Есть разные варианты — откройте для объединения',
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        leading: Checkbox(
          semanticLabel: 'Завершить ${t.title}',
          value: t.status == 'done',
          onChanged: t.deleted
              ? null
              : (v) async {
                  try {
                    if (v == true) {
                      await book.complete(t);
                    } else {
                      await book.save(t, {'status': 'open'});
                    }
                    await changed();
                  } catch (e) {
                    failure(e);
                  }
                },
        ),
        title: Text(
          t.title,
          style: TextStyle(
            decoration: t.closed ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: subtitle.isEmpty ? null : Text(subtitle),
        onTap: () => edit(t),
        trailing: PopupMenuButton<String>(
          tooltip: 'Действия задачи',
          onSelected: (v) async {
            if (v == 'edit') {
              await edit(t);
              return;
            }
            if (v == 'child') {
              await edit(null, t.id);
              return;
            }
            try {
              await book.save(t, {'deleted': !t.deleted});
              await changed();
            } catch (e) {
              failure(e);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'edit', child: Text('Изменить')),
            if (!t.deleted)
              const PopupMenuItem(
                value: 'child',
                child: Text('Добавить подзадачу'),
              ),
            PopupMenuItem(
              value: 'delete',
              child: Text(t.deleted ? 'Восстановить' : 'В архив'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = visible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Text(
                widget.section,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Wrap(
                spacing: 8,
                children: [
                  if (widget.section == 'Проекты')
                    OutlinedButton.icon(
                      onPressed: () => project(),
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('Проект'),
                    ),
                  FilledButton.icon(
                    onPressed: () => edit(),
                    icon: const Icon(Icons.add),
                    label: const Text('Задача'),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : error != null
              ? Center(
                  child: TextButton(onPressed: load, child: Text(error!)),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  children: [
                    if (widget.section == 'Проекты') ...[
                      for (final p in projects.where(
                        (p) => p.fields['deleted'] != true,
                      ))
                        Card(
                          child: ListTile(
                            selected: projectId == p.id,
                            title: Text(
                              '${p.fields['name']}${p.fields['status'] == 'done' ? ' · завершён' : ''}',
                            ),
                            subtitle: Text(
                              '${tasks.where((t) => !t.deleted && !t.closed && t.projectId == p.id).length} открытых задач${p.hasConflict ? ' · есть конфликт' : ''}',
                            ),
                            onTap: () => setState(
                              () => projectId = projectId == p.id ? null : p.id,
                            ),
                            trailing: IconButton(
                              tooltip: 'Изменить проект',
                              onPressed: () => project(p),
                              icon: const Icon(Icons.edit_outlined),
                            ),
                          ),
                        ),
                      if (projects
                          .where((p) => p.fields['deleted'] != true)
                          .isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            'Создайте проект, чтобы собрать связанные задачи.',
                          ),
                        ),
                      const SizedBox(height: 12),
                    ],
                    if (widget.section == 'Календарь')
                      Center(
                        child: SizedBox(
                          width: 400,
                          child: CalendarDatePicker(
                            initialDate: selectedDay,
                            firstDate: DateTime(2000),
                            lastDate: DateTime(2199, 12, 31),
                            onDateChanged: (v) =>
                                setState(() => selectedDay = v),
                          ),
                        ),
                      ),
                    TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Поиск задач и тегов',
                      ),
                      onChanged: (v) => setState(() => query = v),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 12,
                      children: [
                        FilterChip(
                          label: const Text('Завершённые'),
                          selected: showClosed,
                          onSelected: (v) => setState(() => showClosed = v),
                        ),
                        if (projectId != null)
                          InputChip(
                            label: Text(projectName(projectId)),
                            onDeleted: () => setState(() => projectId = null),
                          ),
                        Text('${list.length} задач'),
                      ],
                    ),
                    if (list.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: Center(child: Text('Здесь пока нет задач')),
                      ),
                    for (final t in list) row(t),
                  ],
                ),
        ),
      ],
    );
  }
}

class TaskEditor extends StatefulWidget {
  final TaskBook book;
  final PlanTask? task;
  final List<ReplicaObject> projects;
  final List<PlanTask> tasks;
  final String? initialProject, initialParent, initialDate;
  const TaskEditor({
    super.key,
    required this.book,
    this.task,
    required this.projects,
    required this.tasks,
    this.initialProject,
    this.initialParent,
    this.initialDate,
  });
  @override
  State<TaskEditor> createState() => _TaskEditorState();
}

class _TaskEditorState extends State<TaskEditor> {
  late final TextEditingController title, body, tags;
  late String status, repeat;
  late int priority, anchorDay;
  String? projectId, parentId, dueDate, error;
  int? reminderAt;
  bool deleted = false, saving = false;
  @override
  void initState() {
    super.initState();
    final t = widget.task;
    title = TextEditingController(text: t?.title ?? '');
    body = TextEditingController(text: t?.body ?? '');
    tags = TextEditingController(text: t?.tags.join(', ') ?? '');
    status = t?.status ?? 'open';
    repeat = t?.repeat ?? 'none';
    priority = t?.priority ?? 0;
    projectId = t?.projectId ?? widget.initialProject;
    parentId = t?.parentId ?? widget.initialParent;
    dueDate = t?.dueDate ?? widget.initialDate;
    anchorDay = t?.fields['anchorDay'] as int? ?? (parseDay(dueDate)?.day ?? 1);
    reminderAt = t?.reminderAt;
    deleted = t?.deleted ?? false;
  }

  @override
  void dispose() {
    title.dispose();
    body.dispose();
    tags.dispose();
    super.dispose();
  }

  Future<void> date() async {
    final value = await showDatePicker(
      context: context,
      initialDate: parseDay(dueDate) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2199, 12, 31),
    );
    if (value != null && mounted) {
      setState(() {
        dueDate = dayKey(value);
        anchorDay = value.day;
      });
    }
  }

  Future<void> reminder() async {
    final day = await showDatePicker(
      context: context,
      initialDate: reminderAt != null
          ? DateTime.fromMillisecondsSinceEpoch(reminderAt!)
          : parseDay(dueDate) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2199, 12, 31),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: reminderAt != null
          ? TimeOfDay.fromDateTime(
              DateTime.fromMillisecondsSinceEpoch(reminderAt!),
            )
          : const TimeOfDay(hour: 9, minute: 0),
    );
    if (time != null && mounted) {
      setState(
        () => reminderAt = DateTime(
          day.year,
          day.month,
          day.day,
          time.hour,
          time.minute,
        ).millisecondsSinceEpoch,
      );
    }
  }

  void variant(String key, Object? value) {
    setState(() {
      switch (key) {
        case 'title':
          title.text = value as String;
        case 'body':
          body.text = value as String;
        case 'tags':
          tags.text = (value as List).join(', ');
        case 'status':
          status = value as String;
        case 'priority':
          priority = value as int;
        case 'dueDate':
          dueDate = value as String?;
        case 'reminderAt':
          reminderAt = value as int?;
        case 'projectId':
          projectId = value as String?;
        case 'parentId':
          parentId = value as String?;
        case 'repeat':
          repeat = value as String;
        case 'anchorDay':
          anchorDay = value as int;
        case 'deleted':
          deleted = value as bool;
      }
    });
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final fields = <String, Object?>{
        'title': title.text.trim(),
        'body': body.text,
        'tags':
            tags.text
                .split(',')
                .map((v) => v.trim())
                .where((v) => v.isNotEmpty)
                .toSet()
                .toList()
              ..sort(),
        'status': status,
        'priority': priority,
        'projectId': projectId,
        'parentId': parentId,
        'dueDate': dueDate,
        'reminderAt': reminderAt,
        'repeat': repeat,
        'anchorDay': anchorDay,
        'deleted': deleted,
      };
      final t = widget.task;
      if (t == null) {
        final id = await widget.book.createTask(fields);
        if (mounted) Navigator.pop(context, id);
      } else {
        // Completion must use the atomic successor path, not a generic edit.
        if (status == 'done' && t.status != 'done') {
          await widget.book.save(t, {
            ...fields,
            'status': t.status,
          }, resolve: t.version.hasConflict);
          final current = (await widget.book.tasks(includeDeleted: true))
              .firstWhere((v) => v.id == t.id);
          await widget.book.complete(current);
        } else {
          await widget.book.save(t, fields, resolve: t.version.hasConflict);
        }
        if (mounted) Navigator.pop(context, t.id);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = e is FormatException ? e.message : 'Не удалось сохранить задачу. Проверьте поля и свободное место.';
        });
      }
    }
  }

  Widget dropdown<T>(
    String label,
    T value,
    Map<T, String> options,
    void Function(T) change,
  ) => DropdownButtonFormField<T>(
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: options.entries
        .map(
          (e) => DropdownMenuItem(
            value: e.key,
            child: Text(e.value, overflow: TextOverflow.ellipsis),
          ),
        )
        .toList(),
    onChanged: saving
        ? null
        : (v) {
            if (v != null) setState(() => change(v));
          },
  );
  @override
  Widget build(BuildContext context) {
    final t = widget.task;
    final projectOptions = <String, String>{
      '': 'Без проекта',
      for (final p in widget.projects)
        p.id:
            '${p.fields['name']}${p.fields['deleted'] == true ? ' (удалён)' : ''}',
    };
    if (projectId != null && !projectOptions.containsKey(projectId)) {
      projectOptions[projectId!] = 'Недоступный проект';
    }
    final parentOptions = <String, String>{
      '': 'Без родительской задачи',
      for (final p in widget.tasks.where((p) => p.id != t?.id && !p.deleted))
        p.id: p.title,
    };
    if (parentId != null && !parentOptions.containsKey(parentId)) {
      parentOptions[parentId!] = 'Недоступная задача';
    }
    return AlertDialog(
      title: Text(t == null ? 'Новая задача' : 'Изменить задачу'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (t?.version.hasConflict == true) ...[
                const Text(
                  'Есть разные варианты. Выберите значения или объедините вручную. Поздние изменения останутся отдельным конфликтом.',
                ),
                for (final entry in t!.version.conflicts.entries.where(
                  (e) => e.key != 'deletionVsEdit',
                )) ...[
                  Text(
                    entry.key,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  for (final v in entry.value)
                    TextButton(
                      onPressed: saving
                          ? null
                          : () => variant(entry.key, v.value),
                      child: Text(
                        '${v.value}',
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ],
              TextField(
                controller: title,
                autofocus: t == null,
                maxLength: 1000,
                decoration: const InputDecoration(labelText: 'Название задачи'),
              ),
              TextField(
                controller: body,
                minLines: 2,
                maxLines: 6,
                maxLength: 1000000,
                decoration: const InputDecoration(labelText: 'Описание'),
              ),
              const SizedBox(height: 12),
              dropdown('Статус', status, taskStatuses, (v) => status = v),
              const SizedBox(height: 12),
              dropdown('Приоритет', priority, {
                for (var i = 0; i < 4; i++) i: taskPriorities[i],
              }, (v) => priority = v),
              const SizedBox(height: 12),
              dropdown(
                'Проект',
                projectId ?? '',
                projectOptions,
                (v) => projectId = v.isEmpty ? null : v,
              ),
              const SizedBox(height: 12),
              dropdown(
                'Подзадача',
                parentId ?? '',
                parentOptions,
                (v) => parentId = v.isEmpty ? null : v,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tags,
                decoration: const InputDecoration(
                  labelText: 'Теги через запятую',
                  hintText: 'дом, учёба',
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: saving ? null : date,
                    icon: const Icon(Icons.event_outlined),
                    label: Text(dueDate ?? 'Указать срок'),
                  ),
                  if (dueDate != null)
                    IconButton(
                      tooltip: 'Убрать срок и повтор',
                      onPressed: saving
                          ? null
                          : () => setState(() {
                              dueDate = null;
                              repeat = 'none';
                            }),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              dropdown('Повтор', repeat, taskRepeats, (v) => repeat = v),
              if (repeat != 'none')
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Следующая задача появляется после завершения. Пропущенные дни автоматически не накапливаются.',
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: saving ? null : reminder,
                    icon: const Icon(Icons.notifications_none),
                    label: Text(
                      reminderAt == null
                          ? 'Напомнить'
                          : DateTime.fromMillisecondsSinceEpoch(reminderAt!)
                                .toString()
                                .substring(0, 16),
                    ),
                  ),
                  if (reminderAt != null)
                    IconButton(
                      tooltip: 'Убрать напоминание',
                      onPressed: saving
                          ? null
                          : () => setState(() => reminderAt = null),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
              if (t != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('В архиве'),
                  value: deleted,
                  onChanged: saving ? null : (v) => setState(() => deleted = v),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(saving ? 'Сохраняю…' : 'Сохранить'),
        ),
      ],
    );
  }
}
