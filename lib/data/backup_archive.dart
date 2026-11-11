import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../sync/attachment_cache.dart';
import '../sync/operation.dart';

class BackupArchive {
  static const maxBytes = 256 * 1024 * 1024;
  final String snapshot;
  final Map<String, Uint8List> files;
  final Map<String, AttachmentDescriptor> descriptors;
  BackupArchive._(this.snapshot, this.files, this.descriptors);
  static Map<String, AttachmentDescriptor> references(String snapshot) {
    final envelope = jsonDecode(snapshot) as Map;
    final data = jsonDecode(envelope['payload'] as String) as Map;
    final descriptors = <String, AttachmentDescriptor>{};
    for (final value in data['operations'] as List? ?? []) {
      final op = SyncOperation.fromJson(value);
      for (final file in op.fields['attachments'] as List? ?? []) {
        final descriptor = AttachmentDescriptor.fromJson(file);
        if (descriptors.containsKey(descriptor.hash) &&
            descriptors[descriptor.hash]!.size != descriptor.size) {
          throw const FormatException('Противоречивое вложение.');
        }
        descriptors[descriptor.hash] = descriptor;
      }
    }
    return descriptors;
  }

  static Future<Uint8List> create(
    String snapshot,
    AttachmentCache cache,
  ) async {
    final archive = Archive();
    final json = utf8.encode(snapshot);
    var total = json.length;
    archive.add(
      ArchiveFile('snapshot.json', json.length, json)
        ..compression = CompressionType.none,
    );
    for (final descriptor in references(snapshot).values) {
      total += descriptor.size;
      if (total > maxBytes - 1024 * 1024) {
        throw const FormatException(
          'Полная копия больше 256 МБ. Экспортируйте данные по частям.',
        );
      }
      final file = await cache.verifiedFile(descriptor);
      if (file == null) {
        throw const FormatException(
          'Не все вложения загружены. Дождитесь синхронизации перед созданием полной копии.',
        );
      }
      final bytes = await file.readAsBytes();
      archive.add(
        ArchiveFile('files/${descriptor.hash}', bytes.length, bytes)
          ..compression = CompressionType.none,
      );
    }
    final result = ZipEncoder().encodeBytes(archive, level: 0);
    if (result.length > maxBytes) {
      throw const FormatException('Полная копия больше 256 МБ.');
    }
    return Uint8List.fromList(result);
  }

  static BackupArchive inspect(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('Архив больше 256 МБ.');
    }
    try {
      if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) {
        final snapshot = utf8.decode(bytes);
        final refs = references(snapshot);
        if (refs.isNotEmpty) {
          throw const FormatException(
            'Для вложений выберите полную копию .ladno, а не JSON-экспорт.',
          );
        }
        return BackupArchive._(snapshot, {}, refs);
      }
      final directory = ZipDirectory()
        ..read(InputMemoryStream(bytes), verify: true);
      if (directory.fileHeaders.length > 10001) {
        throw const FormatException('Слишком много файлов.');
      }
      final names = <String>{};
      var total = 0;
      for (final header in directory.fileHeaders) {
        final name = header.filename;
        total += header.uncompressedSize;
        final mode = header.externalFileAttributes >> 16;
        if (header.compressionMethod != 0 ||
            header.uncompressedSize != header.compressedSize ||
            total > maxBytes ||
            header.uncompressedSize > 100 * 1024 * 1024 ||
            (mode & 0xf000 != 0 && mode & 0xf000 != 0x8000) ||
            !names.add(name) ||
            (name != 'snapshot.json' &&
                !RegExp(r'^files/[0-9a-f]{64}$').hasMatch(name))) {
          throw const FormatException(
            'Неподдерживаемый или небезопасный архив.',
          );
        }
      }
      final archive = ZipDecoder().decodeBytes(bytes, verify: true);
      final json = archive.findFile('snapshot.json')?.readBytes();
      if (json == null || json.length > 50 * 1024 * 1024) {
        throw const FormatException('Нет снимка базы или он слишком большой.');
      }
      final snapshot = utf8.decode(json);
      final refs = references(snapshot);
      final files = <String, Uint8List>{};
      if (names.length != refs.length + 1) {
        throw const FormatException('Состав вложений не совпадает с журналом.');
      }
      for (final d in refs.values) {
        final file = archive.findFile('files/${d.hash}');
        if (file == null || file.size != d.size) {
          throw const FormatException('Не хватает вложения.');
        }
        final content = file.readBytes();
        if (content == null ||
            content.length != d.size ||
            sha256.convert(content).toString() != d.hash) {
          throw const FormatException('Повреждено вложение.');
        }
        files[d.hash] = content;
      }
      return BackupArchive._(snapshot, files, refs);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('Не удалось проверить резервный архив.');
    }
  }

  Future<void> install(AttachmentCache cache) async {
    final temp = await Directory.systemTemp.createTemp('ladno-restore-');
    try {
      for (final descriptor in descriptors.values) {
        final file = File('${temp.path}/${descriptor.hash}');
        await file.writeAsBytes(files[descriptor.hash]!, flush: true);
        await cache.importFile(file, name: descriptor.name);
      }
    } finally {
      await temp.delete(recursive: true);
    }
  }
}
