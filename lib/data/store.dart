import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import '../sync/replica.dart';
import '../sync/attachment_cache.dart';
import 'backup_archive.dart';
import '../sync/operation.dart';

const _uuid = Uuid();

class Note {
  final String id;
  String title, body;
  String? folderId;
  bool pinned, deleted;
  bool hasConflict = false;
  int updated, revision;
  _EditVersion? _edit;

  Note snapshot() {
    final copy = Note.fromMap(toMap());
    copy._edit = _edit;
    copy.hasConflict = hasConflict;
    return copy;
  }

  Map<String, Object?> get _fields => {
    'title': title,
    'body': body,
    'folderId': folderId,
    'pinned': pinned,
    'deleted': deleted,
  };
  Note({
    required this.id,
    this.title = '',
    this.body = '',
    this.folderId,
    this.pinned = false,
    this.deleted = false,
    required this.updated,
    this.revision = 1,
  });
  factory Note.fromMap(Map<String, Object?> m) => Note(
    id: m['id'] as String,
    title: m['title'] as String,
    body: m['body'] as String,
    folderId: m['folder_id'] as String?,
    pinned: m['pinned'] == 1,
    deleted: m['deleted'] == 1,
    updated: m['updated'] as int,
    revision: m['revision'] as int,
  );
  Map<String, Object?> toMap() => {
    'id': id,
    'title': title,
    'body': body,
    'folder_id': folderId,
    'pinned': pinned ? 1 : 0,
    'deleted': deleted ? 1 : 0,
    'updated': updated,
    'revision': revision,
  };
}

class _EditVersion {
  final String deviceId;
  List<String> heads;
  Map<String, Object?> fields;
  _EditVersion(this.deviceId, this.heads, this.fields);
}

/// All database writes are atomic. File exports contain no settings or secrets.
class Store {
  final Database db;
  final Directory root;
  late Replica replica;
  late final AttachmentCache attachments;
  Store._(this.db, this.root);

  static Future<void> _seed(DatabaseExecutor tx) async {
    final replica = await Replica.attach(tx, inTransaction: true);
    for (final folder in await tx.query('folders')) {
      await replica.change(folder['id'] as String, 'folder', {
        'name': folder['name'],
        'deleted': false,
      });
    }
    for (final row in await tx.query('notes')) {
      final note = Note.fromMap(row);
      await replica.change(note.id, 'note', note._fields);
    }
  }

  /// Rebuild the visible projection in the operation's transaction. Missing or
  /// deleted folders stay as placeholders for foreign keys, hidden by folders().
  static Future<void> _project(DatabaseExecutor tx) async {
    final replica = await Replica.attach(tx, inTransaction: true);
    final objects = <ReplicaObject>[];
    for (final id in await replica.objectIds()) {
      final value = await replica.read(id);
      if (value != null) objects.add(value);
    }
    for (final object in objects.where((o) => o.kind == 'folder')) {
      await tx.insert('folders', {
        'id': object.id,
        'name': object.fields['name'] ?? '',
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
      await tx.update(
        'folders',
        {'name': object.fields['name'] ?? ''},
        where: 'id = ?',
        whereArgs: [object.id],
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final object in objects.where((o) => o.kind == 'note')) {
      final f = object.fields;
      final folder = f['folderId'] as String?;
      if (folder != null) {
        await tx.insert('folders', {
          'id': folder,
          'name': '',
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      final rows = await tx.query(
        'notes',
        where: 'id = ?',
        whereArgs: [object.id],
      );
      final old = rows.isEmpty ? null : rows.single;
      final value = Note(
        id: object.id,
        title: f['title'] as String? ?? '',
        body: f['body'] as String? ?? '',
        folderId: folder,
        pinned: f['pinned'] == true,
        deleted: f['deleted'] == true,
        updated: now,
        revision: old == null ? 1 : (old['revision'] as int) + 1,
      ).toMap();
      if (old != null &&
          [
            'title',
            'body',
            'folder_id',
            'pinned',
            'deleted',
          ].every((key) => old[key] == value[key])) {
        continue;
      }
      if (old != null &&
          (old['title'] != value['title'] || old['body'] != value['body'])) {
        await tx.insert('revisions', {
          'id': _uuid.v4(),
          'note_id': object.id,
          'title': old['title'],
          'body': old['body'],
          'created': now,
        });
        await tx.rawDelete(
          'DELETE FROM revisions WHERE note_id = ? AND id NOT IN (SELECT id FROM revisions WHERE note_id = ? ORDER BY created DESC, rowid DESC LIMIT 30)',
          [object.id, object.id],
        );
      }
      if (old == null) {
        await tx.insert('notes', value);
      } else {
        await tx.update(
          'notes',
          value,
          where: 'id = ?',
          whereArgs: [object.id],
        );
      }
    }
  }

  static Future<Store> open(DatabaseFactory factory, Directory root) async {
    await root.create(recursive: true);
    final path = p.join(root.path, 'ladno.sqlite');
    // Copy only while closed, before any future schema upgrade.
    if (await File(path).exists()) {
      final probe = await factory.openDatabase(
        path,
        options: OpenDatabaseOptions(readOnly: true),
      );
      final version = await probe.getVersion();
      await probe.close();
      if (version > 2) {
        throw const FormatException(
          'База создана более новой версией приложения.',
        );
      }
      if (version < 2) {
        final source = File(path);
        final backup = File('$path.before-v2');
        await source.copy(backup.path);
        if (sha256.convert(await source.readAsBytes()) !=
            sha256.convert(await backup.readAsBytes())) {
          throw const FormatException(
            'Не удалось проверить копию перед обновлением базы.',
          );
        }
        final copied = await factory.openDatabase(
          backup.path,
          options: OpenDatabaseOptions(readOnly: true),
        );
        try {
          final check = await copied.rawQuery('PRAGMA integrity_check');
          if (check.length != 1 || check.single.values.single != 'ok') {
            throw const FormatException(
              'Копия базы повреждена. Обновление остановлено.',
            );
          }
        } finally {
          await copied.close();
        }
      }
    }
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.rawQuery('PRAGMA journal_mode = DELETE');
          await db.execute('PRAGMA synchronous = FULL');
        },
        onCreate: (db, version) async {
          await db.execute(
            'CREATE TABLE folders(id TEXT PRIMARY KEY, name TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE notes(id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL, folder_id TEXT REFERENCES folders(id) ON DELETE SET NULL, pinned INTEGER NOT NULL, deleted INTEGER NOT NULL, updated INTEGER NOT NULL, revision INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE revisions(id TEXT PRIMARY KEY, note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE, title TEXT NOT NULL, body TEXT NOT NULL, created INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE INDEX revision_note ON revisions(note_id,created)',
          );
          await db.execute(
            'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
          await Replica.createSchema(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          await Replica.createSchema(db);
          await _seed(db);
        },
      ),
    );
    final store = Store._(db, root);
    store.attachments = AttachmentCache(
      Directory(p.join(root.path, 'attachments')),
    );
    store.replica = await Replica.attach(db, onChanged: _project);
    return store;
  }

  Future<List<Note>> notes({
    bool trash = false,
    String query = '',
    String? folderId,
  }) => db.transaction((tx) async {
    final rows = await tx.query(
      'notes',
      where: 'deleted = ?',
      whereArgs: [trash ? 1 : 0],
      orderBy: 'pinned DESC, updated DESC, id',
    );
    final local = await Replica.attach(tx);
    final q = query.toLowerCase();
    final result = <Note>[];
    for (final row in rows) {
      final n = Note.fromMap(row);
      final object = await local.read(n.id);
      n.hasConflict = object?.hasConflict ?? false;
      n._edit = _EditVersion(
        replica.deviceId,
        object?.heads.toList() ?? [],
        n._fields,
      );
      if ((folderId == null || n.folderId == folderId) &&
          (q.isEmpty ||
              n.title.toLowerCase().contains(q) ||
              n.body.toLowerCase().contains(q))) {
        result.add(n);
      }
    }
    return result;
  });

  Future<Note> createNote({String? folderId}) async {
    final n = Note(
      id: _uuid.v4(),
      folderId: folderId,
      updated: DateTime.now().millisecondsSinceEpoch,
    );
    final op = await replica.change(n.id, 'note', n._fields);
    n._edit = _EditVersion(replica.deviceId, [op.id], n._fields);
    return n;
  }

  Future<void> save(Note note) async {
    if (note.title.length > 1000 || note.body.length > 1000000) {
      throw const FormatException(
        'Слишком длинная заметка: заголовок до 1000, текст до 1000000 символов.',
      );
    }
    final edit = note._edit;
    if (edit == null || edit.deviceId != replica.deviceId) {
      throw const FormatException(
        'Откройте заметку заново перед редактированием.',
      );
    }
    final fields = note._fields;
    final patch = <String, Object?>{
      for (final e in fields.entries)
        if (edit.fields[e.key] != e.value) e.key: e.value,
    };
    if (patch.isNotEmpty) {
      final op = await replica.change(
        note.id,
        'note',
        patch,
        parents: edit.heads.toList(),
      );
      edit.heads = [op.id];
      edit.fields = fields;
    }
    final row = (await db.query(
      'notes',
      where: 'id = ?',
      whereArgs: [note.id],
    )).single;
    note.revision = row['revision'] as int;
    note.updated = row['updated'] as int;
  }

  Future<List<AttachmentDescriptor>> noteAttachments(String id) async {
    final object = await replica.read(id);
    return (object?.fields['attachments'] as List? ?? [])
        .map(AttachmentDescriptor.fromJson)
        .toList();
  }

  Future<void> addAttachment(String id, File file, {String? name}) async {
    final version = await replica.read(id);
    if (version == null) throw const FormatException('Заметка не найдена.');
    final descriptor = await attachments.importFile(file, name: name);
    final list = (version.fields['attachments'] as List? ?? [])
        .map(AttachmentDescriptor.fromJson)
        .toList();
    list.removeWhere((d) => d.hash == descriptor.hash);
    list.add(descriptor);
    await replica.change(id, 'note', {
      'attachments': list.map((d) => d.toJson()).toList(),
    }, parents: version.heads);
  }

  Future<void> removeAttachment(String id, String hash) async {
    final version = await replica.read(id);
    if (version == null) return;
    final list = (version.fields['attachments'] as List? ?? [])
        .map(AttachmentDescriptor.fromJson)
        .where((d) => d.hash != hash);
    await replica.change(id, 'note', {
      'attachments': list.map((d) => d.toJson()).toList(),
    }, parents: version.heads);
  }

  Future<Uint8List> fullBackup() async =>
      BackupArchive.create(await backup(), attachments);
  static Map<String, List<Map<String, Object?>>> inspectArchive(
    Uint8List bytes,
  ) => validateBackup(BackupArchive.inspect(bytes).snapshot);
  Future<void> restoreArchive(Uint8List bytes) async {
    final archive = BackupArchive.inspect(bytes);
    validateBackup(archive.snapshot);
    // Immutable content-addressed files may be staged before the transaction;
    // a failed database restore leaves harmless, unreferenced cache entries.
    await archive.install(attachments);
    await restore(archive.snapshot);
  }

  Future<void> resolveConflict(
    ReplicaObject version,
    Map<String, Object?> fields,
  ) async {
    if (version.kind != 'note') throw const FormatException('Это не заметка.');
    await replica.change(version.id, 'note', fields, parents: version.heads);
  }

  Future<List<Map<String, Object?>>> folders() async {
    final rows = await db.query('folders', orderBy: 'name COLLATE NOCASE');
    final active = <Map<String, Object?>>[];
    for (final row in rows) {
      final object = await replica.read(row['id'] as String);
      if (object != null && object.fields['deleted'] != true) active.add(row);
    }
    return active;
  }

  Future<void> addFolder(String name) async {
    if (name.trim().isEmpty) return;
    await replica.change(_uuid.v4(), 'folder', {
      'name': name.trim(),
      'deleted': false,
    });
  }

  Future<void> deleteFolder(String id) => db.transaction((tx) async {
    final local = await Replica.attach(tx);
    await local.change(id, 'folder', {'deleted': true});
    for (final note in await tx.query(
      'notes',
      where: 'folder_id = ?',
      whereArgs: [id],
    )) {
      await local.change(note['id'] as String, 'note', {'folderId': null});
    }
    await _project(tx);
  });
  Future<List<Map<String, Object?>>> history(String id) => db.query(
    'revisions',
    where: 'note_id = ?',
    whereArgs: [id],
    orderBy: 'created DESC, rowid DESC',
  );
  Future<void> setSetting(String key, String value) async => db.insert(
    'settings',
    {'key': key, 'value': value},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
  Future<String?> setting(String key) async {
    final r = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  Future<String> backup() => db.transaction((tx) async {
    final payload = jsonEncode({
      'folders': await tx.query('folders'),
      'notes': await tx.query('notes'),
      'revisions': await tx.query('revisions'),
      'operations': (await tx.query(
        'replica_ops',
        orderBy: 'logical,origin,sequence',
      )).map((r) => jsonDecode(r['document'] as String)).toList(),
    });
    final output = jsonEncode({
      'format': 'ladno-backup',
      'version': 2,
      'sha256': sha256.convert(utf8.encode(payload)).toString(),
      'payload': payload,
    });
    if (utf8.encode(output).length > 50 * 1024 * 1024) {
      throw const FormatException(
        'Копия больше поддерживаемых 50 МБ. Требуется расширение формата; сохраните Markdown-экспорт.',
      );
    }
    return output;
  });

  /// Strict allow-list: never import SQL, paths, settings, device trust or keys.
  static Map<String, List<Map<String, Object?>>> validateBackup(String input) {
    if (utf8.encode(input).length > 50 * 1024 * 1024) {
      throw const FormatException('Архив больше 50 МБ.');
    }
    final envelope = jsonDecode(input);
    if (envelope is! Map ||
        envelope['format'] != 'ladno-backup' ||
        !{1, 2}.contains(envelope['version']) ||
        envelope['payload'] is! String) {
      throw const FormatException('Неподдерживаемый формат резервной копии.');
    }
    final payload = envelope['payload'] as String;
    if (sha256.convert(utf8.encode(payload)).toString() != envelope['sha256']) {
      throw const FormatException(
        'Контрольная сумма не совпадает. Файл повреждён.',
      );
    }
    final data = jsonDecode(payload);
    if (data is! Map) throw const FormatException('Некорректное содержимое.');
    const fields = {
      'folders': {'id', 'name'},
      'notes': {
        'id',
        'title',
        'body',
        'folder_id',
        'pinned',
        'deleted',
        'updated',
        'revision',
      },
      'revisions': {'id', 'note_id', 'title', 'body', 'created'},
    };
    final result = <String, List<Map<String, Object?>>>{};
    for (final table in fields.keys) {
      if (data[table] is! List || (data[table] as List).length > 100000) {
        throw const FormatException('Некорректная таблица.');
      }
      final ids = <String>{};
      result[table] = [];
      for (final value in data[table] as List) {
        if (value is! Map ||
            value.keys.toSet().difference(fields[table]!).isNotEmpty ||
            value.length != fields[table]!.length) {
          throw const FormatException('Некорректные поля.');
        }
        final row = Map<String, Object?>.from(value);
        if (row['id'] is! String ||
            !Uuid.isValidUUID(fromString: row['id'] as String) ||
            !ids.add(row['id'] as String)) {
          throw const FormatException(
            'Некорректный или повторный идентификатор.',
          );
        }
        for (final field in fields[table]!) {
          final v = row[field];
          if (['pinned', 'deleted'].contains(field)) {
            if (v != 0 && v != 1) {
              throw const FormatException('Некорректный флаг.');
            }
          } else if (['updated', 'revision', 'created'].contains(field)) {
            if (v is! int || v < 0) {
              throw const FormatException('Некорректная версия или дата.');
            }
          } else if (field == 'folder_id') {
            if (v != null && v is! String) {
              throw const FormatException('Некорректная папка.');
            }
          } else if (v is! String || v.length > 2 * 1024 * 1024) {
            throw const FormatException('Некорректное текстовое поле.');
          }
          if ((field == 'title' && (v as String).length > 1000) ||
              (field == 'body' && (v as String).length > 1000000)) {
            throw const FormatException(
              'Текст превышает ограничения редактора.',
            );
          }
        }
        result[table]!.add(row);
      }
    }
    if (envelope['version'] == 2) {
      final values = data['operations'];
      if (values is! List || values.length > 100000) {
        throw const FormatException('Некорректный журнал резервной копии.');
      }
      final ids = <String>{};
      result['operations'] = [];
      try {
        for (final value in values) {
          final op = SyncOperation.fromJson(value);
          if (!ids.add(op.id)) throw const FormatException('Повтор операции.');
          result['operations']!.add(op.toJson());
        }
      } on SyncProtocolException {
        throw const FormatException('Повреждён журнал резервной копии.');
      }
    }
    final folders = result['folders']!.map((r) => r['id']).toSet();
    final notes = result['notes']!.map((r) => r['id']).toSet();
    for (final n in result['notes']!) {
      if (n['folder_id'] != null && !folders.contains(n['folder_id'])) {
        throw const FormatException('Отсутствует папка заметки.');
      }
    }
    final counts = <Object?, int>{};
    for (final r in result['revisions']!) {
      if (!notes.contains(r['note_id'])) {
        throw const FormatException('Отсутствует заметка редакции.');
      }
      counts[r['note_id']] = (counts[r['note_id']] ?? 0) + 1;
      if (counts[r['note_id']]! > 30) {
        throw const FormatException('Превышен лимит истории.');
      }
    }
    return result;
  }

  Future<void> restore(String input) async {
    final data = validateBackup(input);
    await db.transaction((tx) async {
      for (final table in [
        'replica_receipts',
        'replica_fields',
        'replica_heads',
        'replica_ops',
        'replica_meta',
        'revisions',
        'notes',
        'folders',
      ]) {
        await tx.delete(table);
      }
      // A restored/copy installation must never reuse an origin's counters.
      await tx.insert('replica_meta', {'key': 'device', 'value': _uuid.v4()});
      await tx.insert('replica_meta', {'key': 'sequence', 'value': '0'});
      await tx.insert('replica_meta', {'key': 'logical', 'value': '0'});
      for (final table in ['folders', 'notes', 'revisions']) {
        for (final row in data[table]!) {
          await tx.insert(table, row);
        }
      }
      if (data['operations'] == null) {
        await _seed(tx);
      } else {
        final local = await Replica.attach(tx, inTransaction: true);
        var page = <SyncOperation>[];
        var bytes = 128;
        for (final row in data['operations']!) {
          final op = SyncOperation.fromJson(row);
          final size = utf8.encode(op.encode()).length + 1;
          if (page.length >= maxSyncBatchOperations ||
              bytes + size > maxSyncBatchBytes) {
            await local.receive(SyncBatch(page));
            page = [];
            bytes = 128;
          }
          page.add(op);
          bytes += size;
        }
        if (page.isNotEmpty) await local.receive(SyncBatch(page));
        // The journal is authoritative. Never present unjournaled rows as
        // synchronized; preserve existing snapshot history without synthesizing
        // an extra revision when its projection already matches.
        final journalNotes = <String>{};
        for (final id in await local.objectIds()) {
          final object = (await local.read(id))!;
          if (object.kind == 'note') journalNotes.add(id);
        }
        if (journalNotes.length != data['notes']!.length) {
          throw const FormatException(
            'Список заметок не совпадает с журналом.',
          );
        }
        for (final note in data['notes']!) {
          if (!journalNotes.contains(note['id'])) {
            throw const FormatException('Заметка отсутствует в журнале.');
          }
        }
        await _project(tx);
      }
    });
    replica = await Replica.attach(db, onChanged: _project);
  }

  Future<File> localBackup({String prefix = 'auto'}) async {
    final dir = await Directory(p.join(root.path, 'backups'))
        .create(recursive: true);
    final file = File(
      p.join(
        dir.path,
        '$prefix-${DateTime.now().microsecondsSinceEpoch}.ladno',
      ),
    );
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(await fullBackup(), flush: true);
    await temp.rename(file.path);
    if (prefix == 'auto') {
      final files =
          (await dir
                .list()
                .where(
                  (f) =>
                      f is File &&
                      p.basename(f.path).startsWith('auto-') &&
                      f.path.endsWith('.ladno'),
                )
                .toList())
            ..sort((a, b) => b.path.compareTo(a.path));
      for (final old in files.skip(7)) {
        await old.delete();
      }
    }
    return file;
  }

  Future<void> dailyBackup() async {
    if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) return;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (await setting('lastBackup') != today) {
      await localBackup();
      await setSetting('lastBackup', today);
    }
  }

  Future<void> exportMarkdown(Directory target) async {
    await target.create(recursive: true);
    for (final note in await notes()) {
      // UUID filenames prevent traversal and collisions; title remains in content.
      final links = <String>[];
      for (final descriptor in await noteAttachments(note.id)) {
        final file = await attachments.verifiedFile(descriptor);
        if (file == null) {
          throw const FormatException(
            'Сначала дождитесь загрузки всех вложений.',
          );
        }
        final directory = await Directory(p.join(target.path, 'files'))
            .create(recursive: true);
        await file.copy(p.join(directory.path, descriptor.hash));
        links.add(
          '[${descriptor.name.replaceAll('[', '').replaceAll(']', '')}](files/${descriptor.hash})',
        );
      }
      await File(p.join(target.path, '${note.id}.md')).writeAsString(
        '# ${note.title.replaceAll('\n', ' ')}\n\n${note.body}\n\n${links.join('\n')}',
        flush: true,
      );
    }
    await File(p.join(target.path, 'ladno-export.json'))
        .writeAsString(await backup(), flush: true);
    await File(p.join(target.path, 'ladno-full.ladno'))
        .writeAsBytes(await fullBackup(), flush: true);
  }

  Future<void> close() => db.close();
}
