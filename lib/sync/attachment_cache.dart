import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'operation.dart';

/// Content-addressed cache, independent of text operations. One process/instance
/// owns a directory. Disk offsets are the durable resume cursor; no RAM-only map.
class AttachmentCache {
  static const chunkBytes = 256 * 1024;
  final Directory root;
  Future<void> _tail = Future.value();
  AttachmentCache(this.root);

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  File _complete(AttachmentDescriptor descriptor) =>
      File(p.join(root.path, 'files', descriptor.hash));
  File _part(AttachmentDescriptor descriptor) =>
      File(p.join(root.path, 'partial', '${descriptor.hash}.part'));
  File _meta(AttachmentDescriptor descriptor) =>
      File(p.join(root.path, 'partial', '${descriptor.hash}.json'));
  Future<void> _directories() async {
    await Directory(p.join(root.path, 'files')).create(recursive: true);
    await Directory(p.join(root.path, 'partial')).create(recursive: true);
  }

  Future<String> _hash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<AttachmentDescriptor> importFile(File source, {String? name}) =>
      _serial(() async {
        await _directories();
        final temp = File(
          p.join(root.path, 'partial', 'local-${const Uuid().v4()}.tmp'),
        );
        try {
          // Stream a bounded snapshot, then hash the snapshot (the source may change).
          final output = await temp.open(mode: FileMode.write);
          var count = 0;
          try {
            await for (final chunk in source.openRead()) {
              count += chunk.length;
              if (count > AttachmentDescriptor.maxBytes) {
                throw const SyncProtocolException('Вложение больше 100 МБ.');
              }
              await output.writeFrom(chunk);
            }
            await output.flush();
          } finally {
            await output.close();
          }
          final descriptor = AttachmentDescriptor(
            hash: await _hash(temp),
            name: name ?? p.basename(source.path),
            size: count,
          );
          final target = _complete(descriptor);
          if (await target.exists() && await _validComplete(descriptor)) {
            await temp.delete();
          } else {
            if (await target.exists()) await target.delete();
            await temp.rename(target.path);
          }
          return descriptor;
        } finally {
          if (await temp.exists()) await temp.delete();
        }
      });

  Future<bool> _validComplete(AttachmentDescriptor descriptor) async {
    final file = _complete(descriptor);
    return await file.exists() &&
        await file.length() == descriptor.size &&
        await _hash(file) == descriptor.hash;
  }

  Future<bool> contains(AttachmentDescriptor descriptor) =>
      _serial(() => _validComplete(descriptor));

  Future<void> _prepare(AttachmentDescriptor descriptor) async {
    await _directories();
    final meta = _meta(descriptor);
    final part = _part(descriptor);
    if (await meta.exists()) {
      final saved = AttachmentDescriptor.fromJson(
        jsonDecode(await meta.readAsString()),
      );
      if (saved.hash != descriptor.hash || saved.size != descriptor.size) {
        throw const SyncProtocolException('Параметры докачки не совпадают.');
      }
      // Crash after meta commit but before creation of the empty .part is safe.
      if (!await part.exists()) await part.writeAsBytes([], flush: true);
    } else {
      final active = await Directory(p.join(root.path, 'partial'))
          .list()
          .where((f) => f.path.endsWith('.json'))
          .length;
      if (active >= 32) {
        throw const SyncProtocolException(
          'Слишком много одновременных вложений.',
        );
      }
      // Do not trust a leftover .part without its committed metadata.
      await part.writeAsBytes([], flush: true);
      final temporary = File('${meta.path}.tmp');
      await temporary.writeAsString(
        jsonEncode(descriptor.toJson()),
        flush: true,
      );
      await temporary.rename(meta.path);
    }
    if (await part.length() > descriptor.size) {
      throw const SyncProtocolException('Повреждено состояние докачки.');
    }
  }

  Future<int> resumeOffset(
    AttachmentDescriptor descriptor, {
    bool create = true,
  }) => _serial(() async {
    if (await _validComplete(descriptor)) return descriptor.size;
    if (!create && !await _meta(descriptor).exists()) return 0;
    await _prepare(descriptor);
    return _part(descriptor).length();
  });

  /// Sequential bounded chunks, with exact duplicate replay support. A sender
  /// asks resumeOffset after reconnect/restart. Text never waits for this call.
  Future<int> append(
    AttachmentDescriptor descriptor,
    int offset,
    List<int> bytes,
  ) => _serial(() async {
    if (offset < 0 ||
        bytes.isEmpty ||
        bytes.length > chunkBytes ||
        offset + bytes.length > descriptor.size ||
        bytes.any((b) => b < 0 || b > 255)) {
      throw const SyncProtocolException('Некорректный блок вложения.');
    }
    final complete = await _validComplete(descriptor);
    if (!complete) await _prepare(descriptor);
    final file = complete ? _complete(descriptor) : _part(descriptor);
    final length = await file.length();
    if (offset > length ||
        (offset < length && offset + bytes.length > length)) {
      throw const SyncProtocolException('Нужна докачка с сохранённой позиции.');
    }
    final handle = await file.open(
      mode: offset == length && !complete ? FileMode.append : FileMode.read,
    );
    try {
      if (offset < length || complete) {
        await handle.setPosition(offset);
        final previous = await handle.read(bytes.length);
        if (previous.length != bytes.length ||
            List.generate(
              bytes.length,
              (i) => i,
            ).any((i) => previous[i] != bytes[i])) {
          throw const SyncProtocolException(
            'Повторный блок содержит другие данные.',
          );
        }
        return length;
      }
      await handle.writeFrom(bytes);
      await handle.flush();
      return length + bytes.length;
    } finally {
      await handle.close();
    }
  });

  Future<void> finish(AttachmentDescriptor descriptor) => _serial(() async {
    if (await _validComplete(descriptor)) {
      if (await _meta(descriptor).exists()) await _meta(descriptor).delete();
      if (await _part(descriptor).exists()) await _part(descriptor).delete();
      return;
    }
    await _prepare(descriptor);
    final part = _part(descriptor);
    if (await part.length() != descriptor.size) {
      throw const SyncProtocolException('Вложение ещё не передано целиком.');
    }
    if (await _hash(part) != descriptor.hash) {
      await part.delete();
      await _meta(descriptor).delete();
      throw const SyncProtocolException(
        'SHA-256 вложения не совпадает. Повторите передачу.',
      );
    }
    final target = _complete(descriptor);
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
    // A crash between rename and cleanup leaves a valid complete file.
    if (await _meta(descriptor).exists()) await _meta(descriptor).delete();
  });

  Future<Uint8List> readChunk(AttachmentDescriptor descriptor, int offset) =>
      _serial(() async {
        if (offset < 0 ||
            offset > descriptor.size ||
            !await _validComplete(descriptor)) {
          throw const SyncProtocolException(
            'Нет проверенного файла или неверная позиция.',
          );
        }
        final handle = await _complete(descriptor).open();
        try {
          await handle.setPosition(offset);
          return await handle.read(min(chunkBytes, descriptor.size - offset));
        } finally {
          await handle.close();
        }
      });
}
