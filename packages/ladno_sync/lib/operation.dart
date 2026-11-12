import 'dart:convert';

import 'package:uuid/uuid.dart';

import 'values.dart';

const syncProtocolVersion = 1;
const maxSyncOperationBytes = 4 * 1024 * 1024;
const maxSyncBatchBytes = 8 * 1024 * 1024;
const maxSyncBatchOperations = 64;

class SyncProtocolException implements Exception {
  final String message;
  const SyncProtocolException(this.message);
  @override
  String toString() => 'SyncProtocolException: $message';
}

bool validUuid(Object? value) =>
    value is String && Uuid.isValidUUID(fromString: value);

bool validOperationId(Object? value) {
  if (value is! String || value.length > 64) return false;
  final parts = value.split(':');
  final sequence = parts.length == 2 ? int.tryParse(parts[1]) : null;
  return parts.length == 2 &&
      validUuid(parts[0]) &&
      sequence != null &&
      sequence > 0 &&
      sequence <= 9007199254740991 &&
      sequence.toString() == parts[1];
}

/// Immutable wire operation. No time-based last-write-wins and no secrets.
class SyncOperation {
  final String origin, objectId, kind;
  final int sequence, logical;
  final List<String> parents;
  final Map<String, Object?> fields;

  SyncOperation({
    required this.origin,
    required this.sequence,
    required this.logical,
    required this.objectId,
    required this.kind,
    required List<String> parents,
    required Map<String, Object?> fields,
  }) : parents = List.unmodifiable([...parents]..sort()),
       fields = Map.unmodifiable(_copyFields(fields)) {
    _validate();
  }

  String get id => '$origin:$sequence';

  static Map<String, Object?> _copyFields(Map<String, Object?> input) {
    // A deep copy prevents caller mutation after validation or persistence.
    final copy = jsonDecode(jsonEncode(input)) as Map<String, dynamic>;
    Object? freeze(Object? value) {
      if (value is List) return List<Object?>.unmodifiable(value.map(freeze));
      if (value is Map) {
        final keys = value.keys.cast<String>().toList()..sort();
        return Map<String, Object?>.unmodifiable({
          for (final key in keys) key: freeze(value[key]),
        });
      }
      return value;
    }

    return (freeze(copy) as Map<String, Object?>);
  }

  void _validate() {
    if (!validUuid(origin) ||
        !validUuid(objectId) ||
        !validOperationId(id) ||
        logical <= 0 ||
        logical > 9007199254740991 ||
        !{'note', 'folder', 'task', 'project'}.contains(kind) ||
        parents.length > 64 ||
        parents.toSet().length != parents.length ||
        parents.any((p) => !validOperationId(p) || p == id) ||
        fields.isEmpty) {
      throw const SyncProtocolException('Некорректная операция.');
    }
    const noteFields = {
      'title',
      'body',
      'folderId',
      'pinned',
      'deleted',
      'attachments',
    };
    const folderFields = {'name', 'deleted'};
    const taskFields = {
      'title',
      'body',
      'deleted',
      'status',
      'priority',
      'projectId',
      'parentId',
      'dueDate',
      'reminderAt',
      'repeat',
      'anchorDay',
      'tags',
    };
    const projectFields = {'name', 'body', 'deleted', 'status'};
    final allowed = switch (kind) {
      'note' => noteFields,
      'folder' => folderFields,
      'task' => taskFields,
      _ => projectFields,
    };
    if (fields.keys.any((key) => !allowed.contains(key))) {
      throw const SyncProtocolException('Неизвестное поле объекта.');
    }
    for (final entry in fields.entries) {
      final value = entry.value;
      switch (entry.key) {
        case 'title':
        case 'name':
          if (value is! String || value.length > 1000) {
            throw const SyncProtocolException('Некорректный заголовок.');
          }
        case 'body':
          if (value is! String || value.length > 1000000) {
            throw const SyncProtocolException('Слишком большой текст.');
          }
        case 'status':
          if (value is! String ||
              !(kind == 'project'
                      ? {'active', 'done'}
                      : {'open', 'doing', 'done', 'cancelled'})
                  .contains(value)) {
            throw const SyncProtocolException('Некорректный статус.');
          }
        case 'priority':
          if (value is! int || value < 0 || value > 3) {
            throw const SyncProtocolException('Некорректный приоритет.');
          }
        case 'anchorDay':
          if (value is! int || value < 1 || value > 31) {
            throw const SyncProtocolException('Некорректный день повтора.');
          }
        case 'repeat':
          if (!{'none', 'daily', 'weekly', 'monthly'}.contains(value)) {
            throw const SyncProtocolException('Некорректный повтор.');
          }
        case 'dueDate':
          if (value != null && parseDay(value) == null) {
            throw const SyncProtocolException('Некорректная дата.');
          }
        case 'reminderAt':
          if (value != null &&
              (value is! int ||
                  value < 946684800000 ||
                  value > 7258118399999)) {
            throw const SyncProtocolException('Некорректное напоминание.');
          }
        case 'tags':
          if (value is! List ||
              value.length > 20 ||
              value.any(
                (v) => v is! String || v.trim().isEmpty || v.length > 40,
              ) ||
              value.toSet().length != value.length) {
            throw const SyncProtocolException('Некорректные теги.');
          }
        case 'projectId':
        case 'parentId':
        case 'folderId':
          if (value != null && !validUuid(value)) {
            throw const SyncProtocolException('Некорректная папка.');
          }
        case 'pinned':
        case 'deleted':
          if (value is! bool) {
            throw const SyncProtocolException('Некорректный флаг.');
          }
        case 'attachments':
          if (value is! List || value.length > 64) {
            throw const SyncProtocolException('Слишком много вложений.');
          }
          final hashes = <String>{};
          for (final item in value) {
            final attachment = AttachmentDescriptor.fromJson(item);
            if (!hashes.add(attachment.hash)) {
              throw const SyncProtocolException('Повтор вложения.');
            }
          }
      }
    }
    if (utf8.encode(encode()).length > maxSyncOperationBytes) {
      throw const SyncProtocolException('Слишком большая операция.');
    }
  }

  Map<String, Object?> toJson() => {
    'version': syncProtocolVersion,
    'origin': origin,
    'sequence': sequence,
    'logical': logical,
    'objectId': objectId,
    'kind': kind,
    'parents': parents,
    'fields': _copyFields(fields),
  };
  String encode() => jsonEncode(toJson());

  factory SyncOperation.fromJson(Object? input) {
    if (input is! Map ||
        input.length != 8 ||
        input['version'] != syncProtocolVersion ||
        input['origin'] is! String ||
        input['objectId'] is! String ||
        input['kind'] is! String ||
        input['sequence'] is! int ||
        input['logical'] is! int ||
        input['parents'] is! List ||
        (input['parents'] as List).any((p) => p is! String) ||
        input['fields'] is! Map) {
      throw const SyncProtocolException('Неподдерживаемая операция.');
    }
    try {
      return SyncOperation(
        origin: input['origin'] as String,
        sequence: input['sequence'] as int,
        logical: input['logical'] as int,
        objectId: input['objectId'] as String,
        kind: input['kind'] as String,
        parents: List<String>.from(input['parents'] as List),
        fields: Map<String, Object?>.from(input['fields'] as Map),
      );
    } on TypeError {
      throw const SyncProtocolException('Некорректные типы полей.');
    }
  }
}

class SyncBatch {
  final List<SyncOperation> operations;
  SyncBatch(List<SyncOperation> operations)
    : operations = List.unmodifiable(operations) {
    if (operations.length > maxSyncBatchOperations ||
        utf8.encode(encode()).length > maxSyncBatchBytes) {
      throw const SyncProtocolException('Превышен размер пакета.');
    }
  }
  String encode() => jsonEncode({
    'protocol': syncProtocolVersion,
    'operations': operations.map((op) => op.toJson()).toList(),
  });
  factory SyncBatch.decode(String input) {
    if (utf8.encode(input).length > maxSyncBatchBytes) {
      throw const SyncProtocolException('Превышен размер пакета.');
    }
    try {
      final value = jsonDecode(input);
      if (value is! Map ||
          value.length != 2 ||
          value['protocol'] != syncProtocolVersion ||
          value['operations'] is! List) {
        throw const SyncProtocolException('Несовместимая версия протокола.');
      }
      return SyncBatch(
        (value['operations'] as List).map(SyncOperation.fromJson).toList(),
      );
    } on FormatException {
      throw const SyncProtocolException('Повреждённый пакет.');
    }
  }
}

class AttachmentDescriptor {
  static const maxBytes = 100 * 1024 * 1024;
  final String hash, name;
  final int size;
  AttachmentDescriptor({
    required this.hash,
    required this.name,
    required this.size,
  }) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        name.isEmpty ||
        name.length > 255 ||
        name.contains('\u0000') ||
        size < 0 ||
        size > maxBytes) {
      throw const SyncProtocolException('Некорректное вложение.');
    }
  }
  Map<String, Object?> toJson() => {'hash': hash, 'name': name, 'size': size};
  factory AttachmentDescriptor.fromJson(Object? input) {
    if (input is! Map ||
        input.length != 3 ||
        input['hash'] is! String ||
        input['name'] is! String ||
        input['size'] is! int) {
      throw const SyncProtocolException('Некорректное описание вложения.');
    }
    return AttachmentDescriptor(
      hash: input['hash'] as String,
      name: input['name'] as String,
      size: input['size'] as int,
    );
  }
}
