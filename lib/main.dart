import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as mobile;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/store.dart';
import 'widgets/task_board.dart';
import 'widgets/reminder_settings.dart';
import 'planning/reminders.dart';
import 'widgets/conflict_dialog.dart';
import 'widgets/sync_settings.dart';
import 'widgets/folder_conflicts.dart';
import 'widgets/attachment_panel.dart';
import 'sync/controller.dart';
import 'data/backup_archive.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final desktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
    if (desktop) sqfliteFfiInit();
    final root = await getApplicationSupportDirectory();
    final store = await Store.open(
      desktop ? databaseFactoryFfi : mobile.databaseFactory,
      Directory(p.join(root.path, 'data')),
    );
    runApp(LadnoApp(store: store));
  } catch (_) {
    runApp(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: SelectableText(
                'Не удалось открыть локальную базу.\nДанные не удалены. Проверьте свободное место и права доступа, затем перезапустите приложение.',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LadnoApp extends StatefulWidget {
  final Store store;
  const LadnoApp({super.key, required this.store});
  @override
  State<LadnoApp> createState() => _LadnoAppState();
}

class _LadnoAppState extends State<LadnoApp> {
  ThemeMode mode = ThemeMode.system;
  @override
  void initState() {
    super.initState();
    widget.store.setting('theme').then((v) {
      if (mounted) {
        setState(
          () => mode = ThemeMode.values.firstWhere(
            (m) => m.name == v,
            orElse: () => ThemeMode.system,
          ),
        );
      }
    });
  }

  ThemeData theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff537665),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: dark
          ? const Color(0xff161d1a)
          : const Color(0xfff7f8f4),
      appBarTheme: const AppBarTheme(
        centerTitle: false,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(height: 76),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Ладно',
    debugShowCheckedModeBanner: false,
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    themeMode: mode,
    home: Workspace(
      store: widget.store,
      themeMode: mode,
      onTheme: (value) async {
        await widget.store.setSetting('theme', value.name);
        if (mounted) setState(() => mode = value);
      },
    ),
  );
}

class Workspace extends StatefulWidget {
  final Store store;
  final ThemeMode themeMode;
  final Future<void> Function(ThemeMode) onTheme;
  const Workspace({
    super.key,
    required this.store,
    required this.themeMode,
    required this.onTheme,
  });
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> with WidgetsBindingObserver {
  Store get store => widget.store;
  final title = TextEditingController(),
      body = TextEditingController(),
      search = TextEditingController();
  final searchFocus = FocusNode();
  List<Note> notes = [];
  List<Map<String, Object?>> folders = [];
  Note? selected;
  String section = 'Заметки';
  String? folderId;
  String status = 'Сохранено локально';
  bool preview = false, mobileEditor = false, dirty = false, busy = false;
  Timer? timer, backupTimer;
  Future<void> writes = Future.value();
  double sidebarWidth = 236, listWidth = 326;
  int loadToken = 0, editGeneration = 0, planningRevision = 0;
  late final SyncController sync;
  late final ReminderService reminders;
  bool get trash => section == 'Корзина';
  bool get noteSection => ['Заметки', 'Корзина', 'Поиск'].contains(section);
  static const sections = <(String, IconData)>[
    ('Входящие', Icons.inbox_outlined),
    ('Сегодня', Icons.wb_sunny_outlined),
    ('Предстоящие', Icons.date_range_outlined),
    ('Задачи', Icons.checklist_outlined),
    ('Календарь', Icons.calendar_month_outlined),
    ('Архив задач', Icons.inventory_2_outlined),
    ('Заметки', Icons.edit_note),
    ('Проекты', Icons.folder_copy_outlined),
    ('Привычки', Icons.spa_outlined),
    ('Фокус', Icons.timelapse_outlined),
    ('Корзина', Icons.delete_outline),
    ('Настройки', Icons.tune),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    sync = SyncController(
      store,
      onDataChanged: () => unawaited(refreshRemote()),
    );
    reminders = ReminderService(
      store,
      backend: NativeReminders(
        onOpen: (_) {
          if (mounted) unawaited(navigate('Задачи'));
        },
      ),
    );
    unawaited(reminders.initialize());
    sync.addListener(syncStatusChanged);
    unawaited(sync.initialize());
    unawaited(reload());
    unawaited(runBackup());
    backupTimer = Timer.periodic(
      const Duration(hours: 1),
      (_) => unawaited(runBackup()),
    );
  }

  void syncStatusChanged() {
    if (mounted) setState(() {});
  }

  Future<void> refreshRemote() async {
    unawaited(reminders.refresh());
    if (mounted) setState(() => planningRevision++);
    final generation = editGeneration, id = selected?.id;
    await writes;
    await reload();
    if (!mounted ||
        dirty ||
        generation != editGeneration ||
        id == null ||
        selected?.id != id) {
      return;
    }
    final all = [...await store.notes(), ...await store.notes(trash: true)];
    final fresh = all.where((n) => n.id == id).firstOrNull;
    if (!mounted || dirty || generation != editGeneration || fresh == null) {
      return;
    }
    final movedToAnotherSection = fresh.deleted != trash;
    setState(() {
      selected = fresh;
      title.text = fresh.title;
      body.text = fresh.body;
      if (movedToAnotherSection) {
        section = fresh.deleted ? 'Корзина' : 'Заметки';
        folderId = null;
      }
    });
    if (movedToAnotherSection) await reload();
  }

  Future<void> runBackup() async {
    try {
      await store.dailyBackup();
    } catch (_) {
      if (mounted) {
        message(
          'Не удалось создать автоматическую копию. Проверьте свободное место.',
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(flush());
      // Desktop windows may lose focus while the phone continues syncing.
      // Mobile background work is intentionally not a persistent service.
      if (Platform.isAndroid ||
          Platform.isIOS ||
          state == AppLifecycleState.detached) {
        unawaited(sync.pause());
      }
    }
    if (state == AppLifecycleState.resumed) {
      unawaited(runBackup());
      unawaited(reminders.refresh());
      unawaited(sync.resume());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    backupTimer?.cancel();
    sync.removeListener(syncStatusChanged);
    sync.dispose();
    reminders.dispose();
    // onChanged enqueues each edit immediately; no debounce data is discarded.
    title.dispose();
    body.dispose();
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> reload() async {
    final token = ++loadToken;
    try {
      final list = await store.notes(
        trash: trash,
        query: search.text,
        folderId: folderId,
      );
      final fs = await store.folders();
      if (mounted && token == loadToken) {
        setState(() {
          notes = list;
          folders = fs;
          for (final note in list) {
            if (note.id == selected?.id) {
              selected!.hasConflict = note.hasConflict;
            }
          }
        });
      }
    } catch (_) {
      message('Не удалось прочитать записи. Попробуйте ещё раз.');
    }
  }

  void changed() {
    final n = selected;
    if (n == null) return;
    editGeneration++;
    n.title = title.text;
    n.body = body.text;
    dirty = true;
    setState(() => status = 'Сохранение…');
    // Capture every edit before yielding: changing selection cannot redirect it.
    final snapshot = n.snapshot();
    writes = writes.then((_) async {
      try {
        await store.save(snapshot);
        sync.changed();
        if (mounted &&
            selected?.id == snapshot.id &&
            title.text == snapshot.title &&
            body.text == snapshot.body) {
          setState(() {
            dirty = false;
            status = 'Сохранено локально';
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            dirty = true;
            status = 'Ошибка сохранения — повторите Ctrl+S';
          });
        }
      }
    });
    timer?.cancel();
    timer = Timer(
      const Duration(milliseconds: 400),
      () => unawaited(writes.then((_) => reload())),
    );
  }

  Future<void> flush() async {
    timer?.cancel();
    await writes;
    if (dirty && selected != null) {
      changed();
      await writes;
    }
  }

  Future<bool> safeFlush() async {
    await flush();
    if (dirty) {
      message(
        'Изменения ещё не сохранены. Освободите место и повторите сохранение.',
      );
      return false;
    }
    return true;
  }

  Future<void> pick(Note n) async {
    if (!await safeFlush()) return;
    if (!mounted) return;
    setState(() {
      selected = n;
      title.text = n.title;
      body.text = n.body;
      preview = false;
      mobileEditor = true;
    });
  }

  Future<void> navigate(String value, {String? folder}) async {
    if (!await safeFlush() || !mounted) return;
    setState(() {
      section = value;
      folderId = folder;
      selected = null;
      mobileEditor = false;
      search.clear();
    });
    await reload();
  }

  Future<void> create() async {
    if (busy || !await safeFlush()) return;
    try {
      final n = await store.createNote(folderId: folderId);
      if (!mounted) return;
      setState(() => section = 'Заметки');
      await reload();
      await pick(n);
    } catch (_) {
      message('Не удалось создать заметку. Проверьте свободное место.');
    }
  }

  Future<void> mutate(void Function(Note) change) async {
    if (!await safeFlush() || selected == null) return;
    final n = selected!;
    final before = n.snapshot();
    change(n);
    try {
      await store.save(n);
      sync.changed();
      if (!mounted) return;
      if (n.deleted != trash) {
        setState(() {
          selected = null;
          mobileEditor = false;
        });
      }
      await reload();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => selected = before);
      message('Изменение не сохранено. Повторите действие.');
    }
  }

  Future<String?> askText(String label) async {
    final c = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 100,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            child: const Text('Создать'),
          ),
        ],
      ),
    );
    // Let dialog finish its exit animation before disposing its controller.
    Future<void>.delayed(const Duration(seconds: 1), c.dispose);
    return value;
  }

  Future<void> addFolder() async {
    final name = await askText('Новая папка');
    if (name == null || name.trim().isEmpty) return;
    try {
      await store.addFolder(name);
      sync.changed();
      await reload();
    } catch (_) {
      message('Не удалось создать папку.');
    }
  }

  Future<bool> confirm(String heading, String detail) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(heading),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Продолжить'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> fileAction(String action) async {
    if (busy || !await safeFlush()) return;
    setState(() => busy = true);
    try {
      if (action == 'backup') {
        final data = await store.fullBackup();
        final path = await FilePicker.saveFile(
          dialogTitle: 'Сохранить резервную копию',
          fileName:
              'ladno-${DateTime.now().toIso8601String().substring(0, 10)}.ladno',
          bytes: data,
        );
        if (path != null) {
          if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
            await File.fromUri(path).writeAsBytes(data, flush: true);
          }
          message('Резервная копия сохранена.');
        }
      } else if (action == 'restore') {
        final picked = await FilePicker.pickFile(type: FileType.any);
        if (picked == null) return;
        final input = await readPicked(picked, BackupArchive.maxBytes);
        final data = Store.inspectArchive(input);
        if (!mounted ||
            !await confirm(
              'Заменить текущие записи?',
              'В архиве ${data['notes']!.length} заметок. Текущие заметки и папки будут заменены. Перед заменой сохраним отдельную копию.',
            )) {
          return;
        }
        await store.localBackup(prefix: 'before-restore');
        final oldVault = sync.vault;
        await sync.pause();
        try {
          await store.restoreArchive(input);
          await reminders.refresh();
        } on Object {
          await sync.resume();
          rethrow;
        }
        if (oldVault != null) {
          try {
            await oldVault.destroy();
          } on Object {
            /* remains protected, never reused */
          }
        }
        sync.vault = null;
        sync.enabled = false;
        sync.active = true;
        sync.status = 'Данные восстановлены. Подключите устройства заново.';
        await store.setSetting('sync.enabled', 'false');
        if (!mounted) return;
        setState(() {
          selected = null;
          mobileEditor = false;
          folderId = null;
        });
        await reload();
        message('Данные восстановлены.');
      } else {
        final path = await FilePicker.getDirectoryPath(
          dialogTitle: 'Папка экспорта Markdown',
        );
        if (path == null) return;
        final target = Directory(
          p.join(path, 'ladno-export-${DateTime.now().microsecondsSinceEpoch}'),
        );
        await store.exportMarkdown(target);
        message('Markdown и JSON сохранены в отдельную папку.');
      }
    } on FormatException catch (e) {
      message('Операция отменена: ${e.message}');
    } catch (_) {
      message(
        'Операция не завершена. Проверьте доступ к файлу и свободное место.',
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void format(String left, [String right = '']) {
    final s = body.selection;
    final start = s.isValid ? s.start : body.text.length;
    final end = s.isValid ? s.end : start;
    body.value = TextEditingValue(
      text: body.text.replaceRange(
        start,
        end,
        '$left${body.text.substring(start, end)}$right',
      ),
      selection: TextSelection.collapsed(offset: end + left.length),
    );
    changed();
  }

  Future<void> resolveConflict() async {
    if (!await safeFlush() || selected == null) return;
    final id = selected!.id;
    try {
      final version = await store.replica.read(id);
      if (!mounted || version == null) return;
      if (!version.hasConflict) {
        await reload();
        return;
      }
      final result = await showDialog<Map<String, Object?>>(
        context: context,
        builder: (_) => ConflictDialog(
          version: version,
          folders: {
            for (final f in folders) f['id'] as String: f['name'] as String,
          },
        ),
      );
      if (result == null) return;
      await store.resolveConflict(version, result);
      sync.changed();
      final all = [...await store.notes(), ...await store.notes(trash: true)];
      final fresh = all.where((n) => n.id == id).first;
      if (!mounted) return;
      setState(() {
        selected = fresh;
        title.text = fresh.title;
        body.text = fresh.body;
        section = fresh.deleted ? 'Корзина' : 'Заметки';
        folderId = null;
        status = 'Сохранено локально';
      });
      await reload();
    } catch (_) {
      message('Не удалось сохранить объединение. Версии не удалены.');
    }
  }

  Future<void> history() async {
    if (!await safeFlush() || selected == null) return;
    final revisions = await store.history(selected!.id);
    if (!mounted) return;
    final chosen = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('История редакций'),
        content: SizedBox(
          width: 520,
          height: 360,
          child: revisions.isEmpty
              ? const Center(child: Text('Здесь появятся предыдущие редакции.'))
              : ListView(
                  children: revisions
                      .map(
                        (r) => ListTile(
                          title: Text(
                            (r['title'] as String).isEmpty
                                ? 'Без названия'
                                : r['title'] as String,
                          ),
                          subtitle: Text(
                            '${stamp(r['created'] as int)}\n${r['body']}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: const Icon(Icons.restore),
                          onTap: () => Navigator.pop(ctx, r),
                        ),
                      )
                      .toList(),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
    if (chosen == null ||
        !mounted ||
        !await confirm(
          'Вернуть эту редакцию?',
          'Текущий текст останется в истории редакций.',
        )) {
      return;
    }
    title.text = chosen['title'] as String;
    body.text = chosen['body'] as String;
    changed();
  }

  String stamp(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}.${two(d.month)}.${d.year} · ${two(d.hour)}:${two(d.minute)}';
  }

  Widget sidebar({bool drawer = false}) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 26, 20, 20),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: colors.primary,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      Icons.check_rounded,
                      color: colors.onPrimary,
                      size: 25,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ладно',
                          style: TextStyle(
                            fontSize: 25,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'Место для ваших мыслей',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                onPressed: busy ? null : create,
                icon: const Icon(Icons.add),
                label: const Text('Новая заметка'),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final item in sections)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: ListTile(
                        dense: true,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: Icon(item.$2, size: 21),
                        title: Text(item.$1),
                        selected: section == item.$1 && folderId == null,
                        selectedTileColor: colors.primaryContainer.withValues(
                          alpha: .65,
                        ),
                        onTap: () {
                          if (drawer) Navigator.pop(context);
                          unawaited(navigate(item.$1));
                        },
                      ),
                    ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 16),
                        child: Text(
                          'МОИ ПАПКИ',
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.4,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Создать папку',
                        onPressed: addFolder,
                        icon: const Icon(Icons.add, size: 20),
                      ),
                    ],
                  ),
                  for (final f in folders)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.folder_outlined, size: 20),
                      title: Text(
                        f['name'] as String,
                        overflow: TextOverflow.ellipsis,
                      ),
                      selected: folderId == f['id'],
                      onTap: () {
                        if (drawer) Navigator.pop(context);
                        unawaited(
                          navigate('Заметки', folder: f['id'] as String),
                        );
                      },
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Действия с папкой',
                        onSelected: (_) async {
                          if (!await safeFlush() ||
                              !mounted ||
                              !await confirm(
                                'Удалить папку?',
                                'Заметки останутся в разделе «Заметки».',
                              )) {
                            return;
                          }
                          try {
                            await store.deleteFolder(f['id'] as String);
                            sync.changed();
                            await navigate('Заметки');
                          } catch (_) {
                            message('Не удалось удалить папку.');
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Удалить папку'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(20),
              child: Row(
                children: [
                  Icon(Icons.lock_outline, size: 15),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Локально. Без облака.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get heading => folderId == null
      ? section
      : folders
                .where((f) => f['id'] == folderId)
                .map((f) => f['name'] as String)
                .firstOrNull ??
            'Заметки';
  Widget noteList() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 24, 16, 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                heading,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${notes.length}',
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
            IconButton(
              tooltip: 'Новая заметка (Ctrl+N)',
              onPressed: busy ? null : create,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: TextField(
          controller: search,
          focusNode: searchFocus,
          onChanged: (_) => unawaited(reload()),
          decoration: const InputDecoration(
            hintText: 'Поиск по заметкам',
            prefixIcon: Icon(Icons.search),
            isDense: true,
          ),
        ),
      ),
      const SizedBox(height: 12),
      Expanded(
        child: notes.isEmpty
            ? empty(
                Icons.notes_outlined,
                search.text.isEmpty ? 'Пока тихо и чисто' : 'Ничего не найдено',
                search.text.isEmpty
                    ? (trash
                          ? 'Удалённые заметки можно будет восстановить здесь.'
                          : 'Создайте заметку — идея останется с вами даже без интернета.')
                    : 'Попробуйте другое слово.',
              )
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: notes.length,
                separatorBuilder: (_, index) => const SizedBox(height: 7),
                itemBuilder: (_, i) {
                  final n = notes[i];
                  final active = selected?.id == n.id;
                  final colors = Theme.of(context).colorScheme;
                  return Material(
                    color: active
                        ? colors.primaryContainer.withValues(alpha: .5)
                        : colors.surface,
                    borderRadius: BorderRadius.circular(16),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => unawaited(pick(n)),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    n.title.isEmpty ? 'Без названия' : n.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (n.hasConflict)
                                  const Tooltip(
                                    message: 'Есть разные версии',
                                    child: Icon(Icons.merge_type, size: 18),
                                  ),
                                if (n.pinned)
                                  Icon(
                                    Icons.push_pin,
                                    size: 15,
                                    color: colors.primary,
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              n.body.isEmpty
                                  ? 'Чистый лист для новой мысли'
                                  : n.body.replaceAll('\n', ' '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.onSurfaceVariant,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              stamp(n.updated),
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    ],
  );
  Widget empty(IconData icon, String title, String subtitle) => Center(
    child: SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 44,
              color: Theme.of(context).colorScheme.primary
                  .withValues(alpha: .6),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 330),
              child: Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  height: 1.6,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  Widget editor({bool mobile = false}) {
    final n = selected;
    if (n == null) {
      return empty(
        Icons.edit_note,
        'Мысли обретают форму',
        'Выберите заметку слева или начните новую.\nCtrl+N — создать · Ctrl+F — найти',
      );
    }
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(mobile ? 4 : 20, 12, 12, 8),
            child: Row(
              children: [
                if (mobile)
                  IconButton(
                    tooltip: 'К списку',
                    onPressed: () async {
                      if (await safeFlush() && mounted) {
                        setState(() => mobileEditor = false);
                      }
                    },
                    icon: const Icon(Icons.arrow_back),
                  ),
                Icon(
                  Icons.check_circle_outline,
                  size: 16,
                  color: dirty
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    status,
                    style: const TextStyle(fontSize: 11),
                    maxLines: 2,
                  ),
                ),
                IconButton(
                  tooltip: preview ? 'Редактировать' : 'Предпросмотр Markdown',
                  onPressed: () => setState(() => preview = !preview),
                  icon: Icon(
                    preview ? Icons.edit_outlined : Icons.visibility_outlined,
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Действия с заметкой',
                  onSelected: (v) {
                    if (v == 'pin') {
                      unawaited(mutate((n) => n.pinned = !n.pinned));
                    }
                    if (v == 'trash') {
                      unawaited(mutate((n) => n.deleted = !n.deleted));
                    }
                    if (v == 'history') unawaited(history());
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'pin',
                      child: Text(n.pinned ? 'Открепить' : 'Закрепить'),
                    ),
                    const PopupMenuItem(
                      value: 'history',
                      child: Text('История редакций'),
                    ),
                    PopupMenuItem(
                      value: 'trash',
                      child: Text(trash ? 'Восстановить' : 'В корзину'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(sync.status, style: const TextStyle(fontSize: 11)),
            ),
          ),
          const Divider(height: 1),
          if (n.hasConflict)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Есть изменения с разных устройств. Обе версии сохранены.',
                    ),
                  ),
                  TextButton(
                    onPressed: () => unawaited(resolveConflict()),
                    child: const Text('Сравнить'),
                  ),
                ],
              ),
            ),
          if (trash)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Заметка в корзине. Восстановите её для редактирования.',
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: DropdownButtonFormField<String>(
              key: ValueKey('${n.id}-${n.folderId}'),
              initialValue: n.folderId ?? '',
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Папка',
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('Без папки')),
                if (n.folderId != null &&
                    !folders.any((f) => f['id'] == n.folderId))
                  DropdownMenuItem(
                    value: n.folderId,
                    child: const Text('Папка недоступна'),
                  ),
                for (final f in folders)
                  DropdownMenuItem(
                    value: f['id'] as String,
                    child: Text(f['name'] as String),
                  ),
              ],
              onChanged: trash
                  ? null
                  : (v) => unawaited(
                      mutate((n) => n.folderId = v == '' ? null : v),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: TextField(
              controller: title,
              maxLength: 1000,
              onChanged: (_) => changed(),
              readOnly: trash,
              style: const TextStyle(fontSize: 27, fontWeight: FontWeight.w700),
              decoration: const InputDecoration(
                hintText: 'Название заметки',
                counterText: '',
                filled: false,
                border: InputBorder.none,
              ),
            ),
          ),
          if (!preview && !trash)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final item in <(String, String, String)>[
                    ('Заголовок', '## ', ''),
                    ('Жирный', '**', '**'),
                    ('Курсив', '*', '*'),
                    ('Список', '\n- ', ''),
                    ('По порядку', '\n1. ', ''),
                    ('Чек-лист', '\n- [ ] ', ''),
                    ('Ссылка', '[', '](https://)'),
                  ])
                    TextButton(
                      onPressed: () => format(item.$2, item.$3),
                      child: Text(item.$1),
                    ),
                ],
              ),
            ),
          Expanded(
            child: preview
                ? Markdown(
                    data: body.text,
                    selectable: true,
                    padding: const EdgeInsets.all(24),
                    // Never load remote images implicitly. Offline notes remain private.
                    imageBuilder: (uri, title, alt) => Container(
                      padding: const EdgeInsets.all(12),
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      child: Text(
                        'Изображение: ${alt ?? uri.toString()}\nВнешние изображения не загружаются автоматически. Добавьте файл во вложения.',
                      ),
                    ),
                    onTapLink: (text, href, title) {
                      if (href != null) {
                        Clipboard.setData(ClipboardData(text: href));
                        message('Адрес ссылки скопирован.');
                      }
                    },
                  )
                : Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: TextField(
                      controller: body,
                      maxLength: 1000000,
                      onChanged: (_) => changed(),
                      readOnly: trash,
                      expands: true,
                      maxLines: null,
                      minLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(fontSize: 16, height: 1.7),
                      decoration: const InputDecoration(
                        hintText: 'Запишите то, что важно…\n\nМожно использовать Markdown.',
                        counterText: '',
                        filled: false,
                        border: InputBorder.none,
                      ),
                    ),
                  ),
          ),
          AttachmentPanel(
            key: ValueKey('attachments-${n.id}'),
            store: store,
            noteId: n.id,
            readOnly: trash,
            beforeChange: safeFlush,
            onChanged: () {
              sync.changed();
              unawaited(reload());
            },
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 6, 24, 14),
            child: Row(
              children: [
                Text(
                  '${body.text.length} символов',
                  style: const TextStyle(fontSize: 11),
                ),
                const Spacer(),
                const Text('Markdown', style: TextStyle(fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget settings() => ListView(
    padding: const EdgeInsets.all(28),
    children: [
      const Text(
        'Настройки',
        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const Text('Ваши данные хранятся на этом устройстве.'),
      const SizedBox(height: 28),
      const Text(
        'Оформление',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<ThemeMode>(
        key: ValueKey(widget.themeMode),
        initialValue: widget.themeMode,
        items: const [
          DropdownMenuItem(
            value: ThemeMode.system,
            child: Text('Как в системе'),
          ),
          DropdownMenuItem(value: ThemeMode.light, child: Text('Светлая тема')),
          DropdownMenuItem(value: ThemeMode.dark, child: Text('Тёмная тема')),
        ],
        onChanged: (v) {
          if (v != null) unawaited(widget.onTheme(v));
        },
      ),
      const SizedBox(height: 28),
      const Text(
        'Резервные копии и экспорт',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.save_alt),
        title: const Text('Полная резервная копия'),
        subtitle: const Text(
          'Заметки, папки, корзина и история. Без настроек и секретов.',
        ),
        onTap: busy ? null : () => unawaited(fileAction('backup')),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.restore_page_outlined),
        title: const Text('Восстановить из файла'),
        subtitle: const Text('С проверкой архива и копией текущих данных.'),
        onTap: busy ? null : () => unawaited(fileAction('restore')),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.folder_zip_outlined),
        title: const Text('Экспорт Markdown и JSON'),
        subtitle: const Text(
          'В выбранной папке будет создан отдельный каталог.',
        ),
        onTap: busy ? null : () => unawaited(fileAction('export')),
      ),
      if (busy) const LinearProgressIndicator(),
      const SizedBox(height: 16),
      SelectableText(
        'Папка данных:\n${store.root.path}\n\nНа ПК: ежедневная копия при работе приложения, последние 7 файлов в backups. Копии на том же диске не защищают от его поломки.',
      ),
      const SizedBox(height: 28),
      const Text(
        'Подключение устройств',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text(
        'Связывайте только свои устройства. Сверяйте код на обоих экранах.',
      ),
      const SizedBox(height: 12),
      SyncSettings(sync: sync),
      ReminderSettings(service: reminders),
      FolderConflicts(
        store: store,
        onChanged: () {
          sync.changed();
          unawaited(reload());
        },
      ),
      const SizedBox(height: 28),
      const Text(
        'DeepSeek · Не подключено',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      const Text(
        'ИИ не отправляет данные и не выполняет запросы. Подготовлена только граница будущего модуля.',
      ),
      const SizedBox(height: 28),
      const Text(
        'Ладно · этап 3 — в разработке',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      const Text(
        'Ctrl+N — заметка · Ctrl+F — поиск · Ctrl+S — сохранить.\nПривычки и фокус появятся на следующем этапе.',
      ),
    ],
  );
  Widget content() =>
      [
        'Входящие',
        'Сегодня',
        'Предстоящие',
        'Задачи',
        'Проекты',
        'Календарь',
        'Архив задач',
      ].contains(section)
      ? TaskBoard(
          key: ValueKey(section),
          store: store,
          section: section,
          revision: planningRevision,
          onChanged: () {
            sync.changed();
            unawaited(reminders.refresh());
            if (mounted) setState(() => planningRevision++);
          },
        )
      : section == 'Настройки'
      ? settings()
      : empty(
          sections.where((s) => s.$1 == section).firstOrNull?.$2 ??
              Icons.event_note_outlined,
          section,
          section == 'Сегодня' ||
                  section == 'Предстоящие' ||
                  section == 'Проекты'
              ? 'Этот раздел появится на этапе 3: задачи, проекты и календарь. Заметки уже доступны в соседнем разделе.'
              : 'Этот раздел появится на этапе 4: привычки, таймер фокуса и статистика.',
        );
  Widget grip(bool first) => MouseRegion(
    cursor: SystemMouseCursors.resizeColumn,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) => setState(() {
        if (first) {
          sidebarWidth = (sidebarWidth + d.delta.dx).clamp(220, 300);
        } else {
          listWidth = (listWidth + d.delta.dx).clamp(260, 420);
        }
      }),
      child: const SizedBox(width: 6, child: VerticalDivider(width: 1)),
    ),
  );
  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
          unawaited(create()),
      const SingleActivator(LogicalKeyboardKey.keyS, control: true): () =>
          unawaited(flush()),
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): () async {
        await navigate('Поиск');
        if (!mounted) return;
        searchFocus.requestFocus();
      },
    },
    child: Focus(
      autofocus: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 1050;
          if (wide) {
            final effectiveList = listWidth.clamp(
              260.0,
              (constraints.maxWidth - sidebarWidth - 400).clamp(260.0, 420.0),
            );
            return Scaffold(
              body: Row(
                children: [
                  SizedBox(width: sidebarWidth, child: sidebar()),
                  grip(true),
                  if (noteSection) ...[
                    SizedBox(width: effectiveList, child: noteList()),
                    grip(false),
                    Expanded(child: editor()),
                  ] else
                    Expanded(child: content()),
                ],
              ),
            );
          }
          final index = switch (section) {
            'Сегодня' => 0,
            'Проекты' => 2,
            'Поиск' => 3,
            _ => 1,
          };
          return PopScope(
            canPop: !mobileEditor,
            onPopInvokedWithResult: (didPop, result) async {
              if (!didPop && await safeFlush() && mounted) {
                setState(() => mobileEditor = false);
              }
            },
            child: Scaffold(
              appBar: mobileEditor
                  ? null
                  : AppBar(
                      title: const Text('Ладно'),
                      actions: [
                        IconButton(
                          tooltip: 'Настройки',
                          onPressed: () => unawaited(navigate('Настройки')),
                          icon: const Icon(Icons.tune),
                        ),
                      ],
                    ),
              drawer: Drawer(child: sidebar(drawer: true)),
              body: SafeArea(
                child: noteSection
                    ? (mobileEditor ? editor(mobile: true) : noteList())
                    : content(),
              ),
              floatingActionButton: mobileEditor || !noteSection
                  ? null
                  : FloatingActionButton(
                      tooltip: 'Новая заметка',
                      onPressed: busy ? null : create,
                      child: const Icon(Icons.add),
                    ),
              bottomNavigationBar: mobileEditor
                  ? null
                  : NavigationBar(
                      selectedIndex: index,
                      onDestinationSelected: (i) async {
                        await navigate(
                          ['Сегодня', 'Заметки', 'Проекты', 'Поиск'][i],
                        );
                        if (i == 3) searchFocus.requestFocus();
                      },
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.wb_sunny_outlined),
                          label: 'Сегодня',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.notes),
                          label: 'Заметки',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.folder_outlined),
                          label: 'Проекты',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.search),
                          label: 'Поиск',
                        ),
                      ],
                    ),
            ),
          );
        },
      ),
    ),
  );
}
