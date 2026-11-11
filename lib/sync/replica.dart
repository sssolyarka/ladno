import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite_common/sqlite_api.dart';
import 'package:uuid/uuid.dart';

import 'operation.dart';

/// Causal operation journal, standalone or attached to the user transaction.
int? _firstInt(List<Map<String, Object?>> rows) =>
    rows.isEmpty ? null : rows.first.values.first as int?;

class Replica {
  final DatabaseExecutor db;
  final String deviceId;
  final Future<void> Function(DatabaseExecutor)? onChanged;
  final bool manageTransactions;
  Replica._(
    this.db,
    this.deviceId, [
    this.onChanged,
    this.manageTransactions = true,
  ]);

  /// Attach to the user database or its current transaction. Never opens a
  /// second connection, so an operation and its projection commit together.
  static Future<Replica> attach(
    DatabaseExecutor db, {
    Future<void> Function(DatabaseExecutor)? onChanged,
    bool inTransaction = false,
  }) async {
    final rows = await db.query(
      'replica_meta',
      where: 'key = ?',
      whereArgs: ['device'],
    );
    return Replica._(
      db,
      rows.single['value'] as String,
      onChanged,
      !inTransaction,
    );
  }

  Future<T> _write<T>(Future<T> Function(DatabaseExecutor) action) async {
    Future<T> run(DatabaseExecutor tx) async {
      final value = await action(tx);
      await onChanged?.call(tx);
      return value;
    }

    if (manageTransactions && db is Database) {
      return (db as Database).transaction(run);
    }
    return run(db);
  }

  Future<T> _read<T>(Future<T> Function(DatabaseExecutor) action) async {
    if (manageTransactions && db is Database) {
      return (db as Database).transaction(action);
    }
    return action(db);
  }

  static Future<Replica> open(
    DatabaseFactory factory,
    Directory directory,
  ) async {
    await directory.create(recursive: true);
    final db = await factory.openDatabase(
      p.join(directory.path, 'replica.sqlite'),
      options: OpenDatabaseOptions(
        version: 1,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
          await db.execute('PRAGMA synchronous = FULL');
          await db.rawQuery('PRAGMA journal_mode = DELETE');
        },
        onCreate: (db, version) async {
          await createSchema(db);
        },
      ),
    );
    final id =
        (await db.query(
              'replica_meta',
              where: 'key = ?',
              whereArgs: ['device'],
            )).single['value']
            as String;
    return Replica._(db, id);
  }

  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE replica_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE replica_ops(id TEXT PRIMARY KEY, origin TEXT NOT NULL, sequence INTEGER NOT NULL, logical INTEGER NOT NULL, object_id TEXT NOT NULL, kind TEXT NOT NULL, document TEXT NOT NULL, applied INTEGER NOT NULL DEFAULT 0, UNIQUE(origin,sequence))',
    );
    await db.execute(
      'CREATE INDEX replica_pending ON replica_ops(applied,logical)',
    );
    await db.execute(
      'CREATE TABLE replica_heads(object_id TEXT NOT NULL, op_id TEXT NOT NULL REFERENCES replica_ops(id), PRIMARY KEY(object_id,op_id))',
    );
    await db.execute(
      'CREATE TABLE replica_fields(object_id TEXT NOT NULL, field TEXT NOT NULL, op_id TEXT NOT NULL REFERENCES replica_ops(id), value TEXT NOT NULL, PRIMARY KEY(object_id,field,op_id))',
    );
    await db.execute(
      'CREATE TABLE replica_receipts(peer_id TEXT NOT NULL, op_id TEXT NOT NULL REFERENCES replica_ops(id), PRIMARY KEY(peer_id,op_id))',
    );
    await db.insert('replica_meta', {
      'key': 'device',
      'value': const Uuid().v4(),
    });
    await db.insert('replica_meta', {'key': 'sequence', 'value': '0'});
    await db.insert('replica_meta', {'key': 'logical', 'value': '0'});
  }

  Future<int> _meta(DatabaseExecutor tx, String key) async => int.parse(
    (await tx.query(
          'replica_meta',
          where: 'key = ?',
          whereArgs: [key],
        )).single['value']
        as String,
  );
  Future<void> _setMeta(DatabaseExecutor tx, String key, int value) async {
    await tx.update(
      'replica_meta',
      {'value': '$value'},
      where: 'key = ?',
      whereArgs: [key],
    );
  }

  Future<List<String>> _heads(DatabaseExecutor tx, String objectId) async =>
      (await tx.query(
        'replica_heads',
        where: 'object_id = ?',
        whereArgs: [objectId],
        orderBy: 'op_id',
      )).map((r) => r['op_id'] as String).toList();

  /// [parents] is the exact editor version being edited. Supplying current
  /// heads silently would conceal offline edits or a stale editor conflict.
  Future<SyncOperation> change(
    String objectId,
    String kind,
    Map<String, Object?> fields, {
    List<String>? parents,
  }) => _write((tx) async {
    final base = parents ?? await _heads(tx, objectId);
    final sequence = await _meta(tx, 'sequence') + 1;
    final logical = await _meta(tx, 'logical') + 1;
    final op = SyncOperation(
      origin: deviceId,
      sequence: sequence,
      logical: logical,
      objectId: objectId,
      kind: kind,
      parents: base,
      fields: fields,
    );
    await _validateRelations(tx, op);
    for (final parent in base) {
      final rows = await tx.query(
        'replica_ops',
        where: 'id = ? AND applied = 1',
        whereArgs: [parent],
      );
      if (rows.isEmpty) {
        throw const SyncProtocolException('Не найдена базовая редакция.');
      }
    }
    await _insert(tx, op);
    await _setMeta(tx, 'sequence', sequence);
    await _setMeta(tx, 'logical', logical);
    await _drain(tx);
    return op;
  });

  Future<void> _validateRelations(DatabaseExecutor tx, SyncOperation op) async {
    final object = await tx.query(
      'replica_ops',
      columns: ['kind'],
      where: 'object_id = ?',
      whereArgs: [op.objectId],
      limit: 1,
    );
    if (object.isNotEmpty && object.first['kind'] != op.kind) {
      throw const SyncProtocolException(
        'Тип существующего объекта не совпадает.',
      );
    }
    for (final parent in op.parents) {
      final rows = await tx.query(
        'replica_ops',
        where: 'id = ?',
        whereArgs: [parent],
      );
      if (rows.isEmpty) continue;
      final row = rows.single;
      if (row['object_id'] != op.objectId ||
          row['kind'] != op.kind ||
          (row['logical'] as int) >= op.logical ||
          (row['origin'] == op.origin &&
              (row['sequence'] as int) >= op.sequence)) {
        throw const SyncProtocolException('Нарушена причинная связь редакций.');
      }
    }
  }

  Future<void> _insert(DatabaseExecutor tx, SyncOperation op) async {
    await tx.insert('replica_ops', {
      'id': op.id,
      'origin': op.origin,
      'sequence': op.sequence,
      'logical': op.logical,
      'object_id': op.objectId,
      'kind': op.kind,
      'document': op.encode(),
      'applied': 0,
    });
  }

  /// Returns durable receipts only AFTER the transaction has committed. A
  /// receipt for a pending child acknowledges storage, not materialization;
  /// the missing parent remains independently unacknowledged and is resent.
  Future<List<String>> receive(SyncBatch batch, {String? fromPeer}) => _write((
    tx,
  ) async {
    if (fromPeer != null && (!validUuid(fromPeer) || fromPeer == deviceId)) {
      throw const SyncProtocolException('Некорректный источник пакета.');
    }
    final receipts = <String>[];
    for (final op in batch.operations) {
      final existing = await tx.query(
        'replica_ops',
        where: 'id = ?',
        whereArgs: [op.id],
      );
      if (existing.isNotEmpty) {
        if (existing.single['document'] != op.encode()) {
          throw const SyncProtocolException(
            'Один идентификатор содержит разные изменения.',
          );
        }
      } else {
        // Receiving a forged local-origin operation must never reuse our
        // sequence space (e.g. a copied installation with the same device ID).
        if (op.origin == deviceId) {
          throw const SyncProtocolException(
            'Коллизия идентификатора устройства.',
          );
        }
        await _validateRelations(tx, op);
        await _insert(tx, op);
      }
      if (op.logical > await _meta(tx, 'logical')) {
        await _setMeta(tx, 'logical', op.logical);
      }
      receipts.add(op.id);
    }
    await _drain(tx);
    final pending =
        _firstInt(
          await tx.rawQuery(
            'SELECT COUNT(*) FROM replica_ops WHERE applied = 0',
          ),
        ) ??
        0;
    if (pending > 10000) {
      throw const SyncProtocolException('Слишком много неполных редакций.');
    }
    if (fromPeer != null) {
      // An authenticated source already owns the operations it just sent.
      // Commit this knowledge with the operations, including pending children.
      for (final id in receipts) {
        await tx.insert('replica_receipts', {
          'peer_id': fromPeer,
          'op_id': id,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    return receipts;
  });

  Future<void> _drain(DatabaseExecutor tx) async {
    var progressed = true;
    while (progressed) {
      progressed = false;
      final pending = await tx.query(
        'replica_ops',
        where: 'applied = 0',
        orderBy: 'logical,origin,sequence',
      );
      for (final row in pending) {
        final op = SyncOperation.fromJson(
          jsonDecode(row['document'] as String),
        );
        await _validateRelations(tx, op);
        var ready = true;
        for (final parent in op.parents) {
          final rows = await tx.query(
            'replica_ops',
            columns: ['applied'],
            where: 'id = ?',
            whereArgs: [parent],
          );
          if (rows.isEmpty || rows.single['applied'] != 1) {
            ready = false;
            break;
          }
        }
        if (!ready) continue;
        await _apply(tx, op);
        await tx.update(
          'replica_ops',
          {'applied': 1},
          where: 'id = ?',
          whereArgs: [op.id],
        );
        progressed = true;
      }
    }
  }

  Future<Set<String>> _ancestors(
    DatabaseExecutor tx,
    Iterable<String> parents,
  ) async {
    final seen = <String>{};
    final todo = parents.toList();
    while (todo.isNotEmpty) {
      final id = todo.removeLast();
      if (!seen.add(id)) continue;
      final row = (await tx.query(
        'replica_ops',
        columns: ['document'],
        where: 'id = ?',
        whereArgs: [id],
      )).single;
      todo.addAll(
        SyncOperation.fromJson(jsonDecode(row['document'] as String)).parents,
      );
    }
    return seen;
  }

  Future<void> _apply(DatabaseExecutor tx, SyncOperation op) async {
    final ancestors = await _ancestors(tx, op.parents);
    for (final head in await _heads(tx, op.objectId)) {
      if (ancestors.contains(head)) {
        await tx.delete(
          'replica_heads',
          where: 'object_id = ? AND op_id = ?',
          whereArgs: [op.objectId, head],
        );
      }
    }
    await tx.insert('replica_heads', {
      'object_id': op.objectId,
      'op_id': op.id,
    });
    if ((await _heads(tx, op.objectId)).length > 64) {
      throw const SyncProtocolException(
        'Сначала объедините параллельные редакции объекта.',
      );
    }
    for (final entry in op.fields.entries) {
      final current = await tx.query(
        'replica_fields',
        where: 'object_id = ? AND field = ?',
        whereArgs: [op.objectId, entry.key],
      );
      for (final field in current) {
        if (ancestors.contains(field['op_id'])) {
          await tx.delete(
            'replica_fields',
            where: 'object_id = ? AND field = ? AND op_id = ?',
            whereArgs: [op.objectId, entry.key, field['op_id']],
          );
        }
      }
      await tx.insert('replica_fields', {
        'object_id': op.objectId,
        'field': entry.key,
        'op_id': op.id,
        'value': jsonEncode(entry.value),
      });
    }
  }

  Future<ReplicaObject?> read(String objectId) => _read((tx) async {
    final rows = await tx.rawQuery(
      'SELECT f.field,f.value,f.op_id,o.logical,o.origin,o.sequence,o.kind FROM replica_fields f JOIN replica_ops o ON o.id=f.op_id WHERE f.object_id = ? ORDER BY o.logical,o.origin,o.sequence',
      [objectId],
    );
    if (rows.isEmpty) return null;
    final fields = <String, Object?>{};
    final versions = <String, List<FieldVersion>>{};
    for (final row in rows) {
      final name = row['field'] as String;
      final value = jsonDecode(row['value'] as String);
      fields[name] = value;
      versions
          .putIfAbsent(name, () => [])
          .add(FieldVersion(row['op_id'] as String, value));
    }
    // Deletion wins the display only; concurrent text is retained and visible
    // through conflicts. A causal restore removes the true deletion version.
    final deletions =
        versions['deleted']?.where((v) => v.value == true).toList() ?? [];
    if (deletions.isNotEmpty) fields['deleted'] = true;
    final conflicts = <String, List<FieldVersion>>{};
    for (final entry in versions.entries) {
      if (entry.value.map((v) => jsonEncode(v.value)).toSet().length > 1) {
        conflicts[entry.key] = entry.value;
      }
    }
    final heads = await _heads(tx, objectId);
    for (final deletion in deletions) {
      for (final head in heads) {
        if (head == deletion.operationId) continue;
        if (!(await _ancestors(tx, [head])).contains(deletion.operationId)) {
          conflicts['deletionVsEdit'] = versions.values
              .expand((v) => v)
              .toList();
        }
      }
    }
    return ReplicaObject(
      id: objectId,
      kind: rows.first['kind'] as String,
      fields: fields,
      heads: heads,
      conflicts: conflicts,
    );
  });

  Future<List<String>> objectIds() async => (await db.rawQuery(
    'SELECT DISTINCT object_id FROM replica_heads ORDER BY object_id',
  )).map((r) => r['object_id'] as String).toList();

  /// Retain files referenced by losing conflict variants as well.
  Future<List<AttachmentDescriptor>> referencedAttachments() async {
    final rows = await db.query(
      'replica_ops',
      columns: ['document'],
      where: 'applied = 1',
    );
    final descriptors = <String, AttachmentDescriptor>{};
    for (final row in rows) {
      for (final value
          in (SyncOperation.fromJson(jsonDecode(row['document'] as String))
                      .fields['attachments']
                  as List? ??
              [])) {
        final descriptor = AttachmentDescriptor.fromJson(value);
        final existing = descriptors[descriptor.hash];
        if (existing != null && existing.size != descriptor.size) {
          throw const SyncProtocolException('Противоречивые размеры вложения.');
        }
        descriptors[descriptor.hash] = descriptor;
      }
    }
    return descriptors.values.toList()
      ..sort((a, b) => a.hash.compareTo(b.hash));
  }

  Future<SyncBatch> outgoing(String peerId) async {
    if (!validUuid(peerId) || peerId == deviceId) {
      throw const SyncProtocolException('Некорректное устройство.');
    }
    final rows = await db.rawQuery(
      'SELECT o.document FROM replica_ops o WHERE o.applied = 1 AND NOT EXISTS (SELECT 1 FROM replica_receipts r WHERE r.peer_id = ? AND r.op_id = o.id) ORDER BY o.logical,o.origin,o.sequence LIMIT ?',
      [peerId, maxSyncBatchOperations],
    );
    final ops = <SyncOperation>[];
    var bytes = 128;
    for (final row in rows) {
      final document = row['document'] as String;
      bytes += utf8.encode(document).length + 1;
      if (bytes > maxSyncBatchBytes) break;
      ops.add(SyncOperation.fromJson(jsonDecode(document)));
    }
    return SyncBatch(ops);
  }

  Future<void> acknowledge(String peerId, List<String> ids) =>
      _read((tx) async {
        if (!validUuid(peerId) ||
            peerId == deviceId ||
            ids.length > maxSyncBatchOperations ||
            ids.any((id) => !validOperationId(id))) {
          throw const SyncProtocolException('Некорректное подтверждение.');
        }
        for (final id in ids) {
          final known = await tx.query(
            'replica_ops',
            columns: ['id'],
            where: 'id = ? AND applied = 1',
            whereArgs: [id],
          );
          if (known.isEmpty) {
            throw const SyncProtocolException(
              'Подтверждение неизвестной операции.',
            );
          }
          await tx.insert('replica_receipts', {
            'peer_id': peerId,
            'op_id': id,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      });

  /// Revocation clears delivery state, never historical operations/tombstones.
  /// Authentication/trust itself belongs in the future secure transport.
  Future<void> forgetReceipts(String peerId) async {
    await db.delete(
      'replica_receipts',
      where: 'peer_id = ?',
      whereArgs: [peerId],
    );
  }

  Future<int> operationCount() async =>
      _firstInt(await db.rawQuery('SELECT COUNT(*) FROM replica_ops')) ?? 0;
  Future<int> pendingCount() async =>
      _firstInt(
        await db.rawQuery('SELECT COUNT(*) FROM replica_ops WHERE applied = 0'),
      ) ??
      0;
  Future<void> close() => (db as Database).close();
}

class FieldVersion {
  final String operationId;
  final Object? value;
  const FieldVersion(this.operationId, this.value);
}

class ReplicaObject {
  final String id, kind;
  final Map<String, Object?> fields;
  final List<String> heads;
  final Map<String, List<FieldVersion>> conflicts;
  ReplicaObject({
    required this.id,
    required this.kind,
    required Map<String, Object?> fields,
    required List<String> heads,
    required Map<String, List<FieldVersion>> conflicts,
  }) : fields = Map.unmodifiable(fields),
       heads = List.unmodifiable(heads),
       conflicts = Map<String, List<FieldVersion>>.unmodifiable({
         for (final e in conflicts.entries)
           e.key: List<FieldVersion>.unmodifiable(e.value),
       });
  bool get hasConflict => conflicts.isNotEmpty;
}
