import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ladno/data/store.dart';
import 'package:ladno/data/backup_archive.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  late Store a, b;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ladno-archive-');
    a = await Store.open(databaseFactoryFfi, Directory('${root.path}/a'));
    b = await Store.open(databaseFactoryFfi, Directory('${root.path}/b'));
  });
  tearDown(() async {
    await a.close();
    await b.close();
    await root.delete(recursive: true);
  });
  test('Полная копия возвращает вложение, историю и заметку', () async {
    final note = await a.createNote();
    note.body = 'С файлом';
    await a.save(note);
    final file = File('${root.path}/original');
    await file.writeAsBytes([1, 2, 3, 4]);
    await a.addAttachment(note.id, file, name: 'фото.png');
    final backup = await a.fullBackup();
    expect(Store.inspectArchive(backup)['notes'], hasLength(1));
    await b.restoreArchive(backup);
    expect((await b.notes()).single.body, 'С файлом');
    final d = (await b.noteAttachments(note.id)).single;
    expect(d.name, 'фото.png');
    expect(await b.attachments.contains(d), isTrue);
    expect(await (await b.attachments.verifiedFile(d))!.readAsBytes(), [
      1,
      2,
      3,
      4,
    ]);
  });
  test('Повреждённый файл отклоняется до изменения базы', () async {
    final note = await a.createNote();
    final file = File('${root.path}/original');
    await file.writeAsBytes([1, 2, 3]);
    await a.addAttachment(note.id, file);
    final archive = ZipDecoder().decodeBytes(await a.fullBackup());
    final changed = Archive();
    for (final entry in archive) {
      final data = entry.name.startsWith('files/')
          ? Uint8List.fromList([7, 8, 9])
          : entry.readBytes()!;
      changed.add(
        ArchiveFile(entry.name, data.length, data)
          ..compression = CompressionType.none,
      );
    }
    final original = await b.createNote();
    original.body = 'Не трогать';
    await b.save(original);
    await expectLater(
      b.restoreArchive(
        Uint8List.fromList(ZipEncoder().encodeBytes(changed, level: 0)),
      ),
      throwsFormatException,
    );
    expect((await b.notes()).single.body, 'Не трогать');
  });
  test('Опасные пути и сжатые записи не распаковываются', () async {
    for (final name in ['../outside', 'files/../../outside', '/absolute']) {
      final archive = Archive()
        ..add(ArchiveFile(name, 1, [1])..compression = CompressionType.none);
      expect(
        () => BackupArchive.inspect(
          Uint8List.fromList(ZipEncoder().encodeBytes(archive, level: 0)),
        ),
        throwsFormatException,
      );
    }
    final archive = Archive()
      ..add(ArchiveFile.string('snapshot.json', 'x' * 10000));
    expect(
      () => BackupArchive.inspect(
        Uint8List.fromList(ZipEncoder().encodeBytes(archive)),
      ),
      throwsFormatException,
    );
  });
  test('JSON-копия без вложений остаётся совместимой', () async {
    final note = await a.createNote();
    note.body = 'Старый формат';
    await a.save(note);
    final bytes = Uint8List.fromList(
      await File('${root.path}/legacy')
          .writeAsString(await a.backup())
          .then((f) => f.readAsBytes()),
    );
    await b.restoreArchive(bytes);
    expect((await b.notes()).single.body, 'Старый формат');
  });
}
