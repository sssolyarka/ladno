import 'dart:io';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ladno/sync/attachment_cache.dart';
import 'package:ladno/sync/operation.dart';

void main() {
  late Directory root;
  late AttachmentCache sender, receiver;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ladno-attachments-');
    sender = AttachmentCache(Directory('${root.path}/sender'));
    receiver = AttachmentCache(Directory('${root.path}/receiver'));
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  Future<AttachmentDescriptor> fixture(
    List<int> bytes, {
    String name = 'Файл.bin',
  }) async {
    final file = File('${root.path}/input.bin');
    await file.writeAsBytes(bytes, flush: true);
    return sender.importFile(file, name: name);
  }

  test('Оборванная передача восстанавливается с дисковой позиции после перезапуска', () async {
    final bytes = List.generate(
      AttachmentCache.chunkBytes + 53,
      (i) => i % 251,
    );
    final descriptor = await fixture(bytes);
    await receiver.append(descriptor, 0, await sender.readChunk(descriptor, 0));
    expect(await receiver.contains(descriptor), isFalse);
    receiver = AttachmentCache(Directory('${root.path}/receiver'));
    final offset = await receiver.resumeOffset(descriptor);
    expect(offset, AttachmentCache.chunkBytes);
    await receiver.append(
      descriptor,
      offset,
      await sender.readChunk(descriptor, offset),
    );
    await receiver.finish(descriptor);
    expect(await receiver.contains(descriptor), isTrue);
    expect(await receiver.resumeOffset(descriptor), bytes.length);
  });
  test(
    'Повтор блока не дописывает дубликат, изменённый повтор отклоняется',
    () async {
      final descriptor = await fixture([1, 2, 3, 4]);
      await receiver.append(descriptor, 0, [1, 2]);
      expect(await receiver.append(descriptor, 0, [1, 2]), 2);
      await expectLater(
        receiver.append(descriptor, 0, [9, 9]),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(await receiver.resumeOffset(descriptor), 2);
      await receiver.append(descriptor, 2, [3, 4]);
      await receiver.finish(descriptor);
      expect(await receiver.append(descriptor, 0, [1, 2]), 4);
    },
  );
  test(
    'Неверный SHA-256 никогда не публикует файл и сбрасывает докачку',
    () async {
      final descriptor = await fixture([1, 2, 3]);
      await receiver.append(descriptor, 0, [3, 2, 1]);
      await expectLater(
        receiver.finish(descriptor),
        throwsA(isA<SyncProtocolException>()),
      );
      expect(await receiver.contains(descriptor), isFalse);
      expect(await receiver.resumeOffset(descriptor), 0);
      await receiver.append(descriptor, 0, [1, 2, 3]);
      await receiver.finish(descriptor);
      expect(await receiver.contains(descriptor), isTrue);
    },
  );
  test('Пустое вложение проходит проверку без фиктивного блока', () async {
    final descriptor = await fixture([]);
    expect(descriptor.hash, sha256.convert([]).toString());
    await receiver.finish(descriptor);
    expect(await receiver.contains(descriptor), isTrue);
  });
  test('Имя файла не используется как путь', () async {
    final descriptor = await fixture([8, 9], name: '../../outside.bin');
    await receiver.append(descriptor, 0, [8, 9]);
    await receiver.finish(descriptor);
    expect(await File('${root.path}/outside.bin').exists(), isFalse);
    expect(
      await File('${root.path}/receiver/files/${descriptor.hash}').exists(),
      isTrue,
    );
  });
  test('Слишком большой блок и пропуск позиции запрещены', () async {
    final descriptor = await fixture([1, 2, 3]);
    await expectLater(
      receiver.append(descriptor, 2, [3]),
      throwsA(isA<SyncProtocolException>()),
    );
    expect(await receiver.resumeOffset(descriptor), 0);
    await expectLater(
      receiver.append(descriptor, 0, [1, 2, 3, 4]),
      throwsA(isA<SyncProtocolException>()),
    );
    await expectLater(
      receiver.append(descriptor, 0, []),
      throwsA(isA<SyncProtocolException>()),
    );
    expect(
      () => AttachmentDescriptor(
        hash: 'a' * 64,
        name: 'Большой',
        size: AttachmentDescriptor.maxBytes + 1,
      ),
      throwsA(isA<SyncProtocolException>()),
    );
  });
  test('Недокачанный файл недоступен для чтения', () async {
    final descriptor = await fixture([1, 2, 3]);
    await receiver.append(descriptor, 0, [1]);
    await expectLater(
      receiver.finish(descriptor),
      throwsA(isA<SyncProtocolException>()),
    );
    await expectLater(
      receiver.readChunk(descriptor, 0),
      throwsA(isA<SyncProtocolException>()),
    );
    expect(await receiver.contains(descriptor), isFalse);
  });
  test('Изменение исходного файла не меняет импортированный снимок', () async {
    final descriptor = await fixture([1, 2, 3]);
    await File('${root.path}/input.bin').writeAsBytes([9, 9, 9]);
    expect(await sender.readChunk(descriptor, 0), [1, 2, 3]);
  });
  test('Повреждение готового файла обнаруживается до передачи', () async {
    final descriptor = await fixture([1, 2, 3]);
    await File('${root.path}/sender/files/${descriptor.hash}')
        .writeAsBytes([3, 2, 1], flush: true);
    expect(await sender.contains(descriptor), isFalse);
    await expectLater(
      sender.readChunk(descriptor, 0),
      throwsA(isA<SyncProtocolException>()),
    );
  });
  test('Противоречивый размер того же хеша не меняет докачку', () async {
    final descriptor = await fixture([1, 2, 3]);
    await receiver.append(descriptor, 0, [1]);
    final bad = AttachmentDescriptor(
      hash: descriptor.hash,
      name: 'Другое имя',
      size: 2,
    );
    await expectLater(
      receiver.resumeOffset(bad),
      throwsA(isA<SyncProtocolException>()),
    );
    expect(await receiver.resumeOffset(descriptor), 1);
  });
  test('Конкурентные повторы одного блока сериализуются', () async {
    final descriptor = await fixture([1, 2, 3]);
    expect(
      await Future.wait([
        receiver.append(descriptor, 0, [1, 2]),
        receiver.append(descriptor, 0, [1, 2]),
      ]),
      [2, 2],
    );
    await receiver.append(descriptor, 2, [3]);
    await receiver.finish(descriptor);
    expect(await receiver.contains(descriptor), isTrue);
  });
  test('Хеш с попыткой выхода из каталога отклоняется', () async {
    expect(
      () => AttachmentDescriptor(hash: '../../private', name: 'Файл', size: 1),
      throwsA(isA<SyncProtocolException>()),
    );
  });
  test(
    'Повтор завершения убирает метаданные, оставшиеся после аварийного rename',
    () async {
      final descriptor = await fixture([1, 2, 3]);
      await receiver.append(descriptor, 0, [1, 2, 3]);
      await receiver.finish(descriptor);
      final meta = File(
        '${root.path}/receiver/partial/${descriptor.hash}.json',
      );
      final part = File(
        '${root.path}/receiver/partial/${descriptor.hash}.part',
      );
      await meta.writeAsString(jsonEncode(descriptor.toJson()));
      await part.writeAsBytes([1]);
      receiver = AttachmentCache(Directory('${root.path}/receiver'));
      await receiver.finish(descriptor);
      expect(await meta.exists(), isFalse);
      expect(await part.exists(), isFalse);
      expect(await receiver.contains(descriptor), isTrue);
    },
  );
}
