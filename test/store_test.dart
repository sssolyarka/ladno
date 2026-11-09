import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ladno/data/store.dart';

void main() {
  sqfliteFfiInit();
  late Directory dir;
  late Store store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ladno-test-');
    store = await Store.open(databaseFactoryFfi, dir);
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });
  test('Пустая пользовательская база без демоданных', () async {
    expect(await store.notes(), isEmpty);
    expect(await store.folders(), isEmpty);
  });
  test('Превышение лимита текста не изменяет сохранённую заметку', () async {
    final n = await store.createNote();
    n.body = 'Сохранённый текст';
    await store.save(n);
    n.body = 'я' * 1000001;
    await expectLater(store.save(n), throwsFormatException);
    expect((await store.notes()).single.body, 'Сохранённый текст');
  });
  test('Сохранение Unicode после закрытия и открытия базы', () async {
    final n = await store.createNote();
    n.title = 'Планы на неделю';
    n.body = 'Ćao! Привет 👋\n- [ ] Купить хлеб';
    await store.save(n);
    await store.close();
    store = await Store.open(databaseFactoryFfi, dir);
    final read = (await store.notes()).single;
    expect(read.toMap(), n.toMap());
    expect((await store.notes(query: 'ПЛАНЫ')).single.id, n.id);
    expect((await store.notes(query: 'ĆAO')).single.id, n.id);
  });
  test('Корзина и восстановление сохраняют содержимое', () async {
    final n = await store.createNote();
    n.body = 'Не потерять';
    n.deleted = true;
    await store.save(n);
    expect(await store.notes(), isEmpty);
    expect((await store.notes(trash: true)).single.body, 'Не потерять');
    n.deleted = false;
    await store.save(n);
    expect((await store.notes()).single.body, 'Не потерять');
  });
  test('История ограничена, версии растут даже со старым снимком', () async {
    final n = await store.createNote();
    for (var i = 0; i < 38; i++) {
      n.body = 'Редакция $i';
      n.revision = 1;
      await store.save(n);
    }
    expect((await store.notes()).single.revision, 39);
    expect(await store.history(n.id), hasLength(30));
  });
  test('Удаление папки оставляет заметки', () async {
    await store.addFolder('Работа');
    final id = (await store.folders()).single['id'] as String;
    final n = await store.createNote(folderId: id);
    n.body = 'Текст';
    await store.save(n);
    await store.deleteFolder(id);
    expect((await store.notes()).single.folderId, isNull);
    expect((await store.notes()).single.body, 'Текст');
  });
  test(
    'Полная копия восстанавливает папки, корзину, историю, но не секреты',
    () async {
      await store.addFolder('Личное');
      final id = (await store.folders()).single['id'] as String;
      final n = await store.createNote(folderId: id);
      n.title = 'Запись';
      n.body = 'Первый';
      await store.save(n);
      n.body = 'Второй';
      n.deleted = true;
      await store.save(n);
      await store.setSetting('apiKey', 'test-only-secret');
      final backup = await store.backup();
      expect(backup, isNot(contains('test-only-secret')));
      await store.createNote();
      await store.restore(backup);
      expect(await store.notes(), isEmpty);
      expect((await store.notes(trash: true)).single.body, 'Второй');
      expect(await store.history(n.id), hasLength(2));
      expect(await store.folders(), hasLength(1));
    },
  );
  test('Повреждённая копия не меняет текущую базу', () async {
    final n = await store.createNote();
    n.body = 'Важное';
    await store.save(n);
    final envelope = jsonDecode(await store.backup()) as Map<String, dynamic>;
    envelope['payload'] = '${envelope['payload']}broken';
    await expectLater(
      store.restore(jsonEncode(envelope)),
      throwsFormatException,
    );
    expect((await store.notes()).single.body, 'Важное');
  });
  test('Неподдерживаемая версия отклоняется', () async {
    final e = jsonDecode(await store.backup()) as Map<String, dynamic>;
    e['version'] = 999;
    await expectLater(store.restore(jsonEncode(e)), throwsFormatException);
  });
  test('Небезопасные имена не влияют на пути Markdown', () async {
    final n = await store.createNote();
    n.title = '../../outside';
    n.body = '**Текст**';
    await store.save(n);
    final out = Directory('${dir.path}/export');
    await store.exportMarkdown(out);
    expect(
      await File('${out.path}/${n.id}.md').readAsString(),
      contains('**Текст**'),
    );
    expect(await out.list().length, 2);
  });
  test('Автокопии ограничены семью и проходят валидацию', () async {
    for (var i = 0; i < 10; i++) {
      await store.localBackup();
    }
    final files = await Directory('${dir.path}/backups').list().toList();
    expect(files, hasLength(7));
    for (final f in files) {
      expect(
        () => Store.validateBackup(File(f.path).readAsStringSync()),
        returnsNormally,
      );
    }
  });
}
