import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

const _uuid = Uuid();

class Note {
  final String id;
  String title, body;
  String? folderId;
  bool pinned, deleted;
  int updated, revision;
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

/// All database writes are atomic. File exports contain no settings or secrets.
class Store {
  final Database db;
  final Directory root;
  Store._(this.db, this.root);
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
      if (version > 1) {
        throw const FormatException(
          'База создана более новой версией приложения.',
        );
      }
      if (version < 1) await File(path).copy('$path.before-migration');
    }
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
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
        },
      ),
    );
    return Store._(db, root);
  }

  Future<List<Note>> notes({
    bool trash = false,
    String query = '',
    String? folderId,
  }) async {
    final rows = await db.query(
      'notes',
      where: 'deleted = ?',
      whereArgs: [trash ? 1 : 0],
      orderBy: 'pinned DESC, updated DESC, id',
    );
    final q = query.toLowerCase();
    return rows
        .map(Note.fromMap)
        .where(
          (n) =>
              (folderId == null || n.folderId == folderId) &&
              (q.isEmpty ||
                  n.title.toLowerCase().contains(q) ||
                  n.body.toLowerCase().contains(q)),
        )
        .toList();
  }

  Future<Note> createNote({String? folderId}) async {
    final n = Note(
      id: _uuid.v4(),
      folderId: folderId,
      updated: DateTime.now().millisecondsSinceEpoch,
    );
    await db.insert('notes', n.toMap());
    return n;
  }

  Future<void> save(Note note) async {
    if (note.title.length > 1000 || note.body.length > 1000000) {
      throw const FormatException(
        'Слишком длинная заметка: заголовок до 1000, текст до 1000000 символов.',
      );
    }
    var nextRevision = note.revision + 1;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((tx) async {
      final old = (await tx.query(
        'notes',
        where: 'id = ?',
        whereArgs: [note.id],
      )).single;
      nextRevision = (old['revision'] as int) + 1;
      if (old['title'] != note.title || old['body'] != note.body) {
        await tx.insert('revisions', {
          'id': _uuid.v4(),
          'note_id': note.id,
          'title': old['title'],
          'body': old['body'],
          'created': now,
        });
        await tx.rawDelete(
          'DELETE FROM revisions WHERE note_id = ? AND id NOT IN (SELECT id FROM revisions WHERE note_id = ? ORDER BY created DESC, rowid DESC LIMIT 30)',
          [note.id, note.id],
        );
      }
      await tx.update(
        'notes',
        {...note.toMap(), 'revision': nextRevision, 'updated': now},
        where: 'id = ?',
        whereArgs: [note.id],
      );
    });
    note.revision = nextRevision;
    note.updated = now;
  }

  Future<List<Map<String, Object?>>> folders() =>
      db.query('folders', orderBy: 'name COLLATE NOCASE');
  Future<void> addFolder(String name) async {
    if (name.trim().isEmpty) return;
    await db.insert('folders', {'id': _uuid.v4(), 'name': name.trim()});
  }

  Future<void> deleteFolder(String id) => db.transaction((tx) async {
    await tx.update(
      'notes',
      {'folder_id': null},
      where: 'folder_id = ?',
      whereArgs: [id],
    );
    await tx.delete('folders', where: 'id = ?', whereArgs: [id]);
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
    });
    final output = jsonEncode({
      'format': 'ladno-backup',
      'version': 1,
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
        envelope['version'] != 1 ||
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
      for (final table in ['revisions', 'notes', 'folders']) {
        await tx.delete(table);
      }
      for (final table in ['folders', 'notes', 'revisions']) {
        for (final row in data[table]!) {
          await tx.insert(table, row);
        }
      }
    });
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
    await temp.writeAsString(await backup(), flush: true);
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
      await File(p.join(target.path, '${note.id}.md')).writeAsString(
        '# ${note.title.replaceAll('\n', ' ')}\n\n${note.body}',
        flush: true,
      );
    }
    await File(p.join(target.path, 'ladno-export.json'))
        .writeAsString(await backup(), flush: true);
  }

  Future<void> close() => db.close();
}
