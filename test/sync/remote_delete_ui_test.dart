import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ladno/data/store.dart';
import 'package:ladno/main.dart';

void main() {
  sqfliteFfiInit();
  testWidgets(
    'Удаление открытой заметки с другого устройства переводит редактор в корзину',
    (tester) async {
      late Directory root;
      late Store local, remote;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('ladno-remote-delete-ui-');
        local = await Store.open(
          databaseFactoryFfiNoIsolate,
          Directory('${root.path}/a'),
        );
        remote = await Store.open(
          databaseFactoryFfiNoIsolate,
          Directory('${root.path}/b'),
        );
        await local.setSetting(
          'lastBackup',
          DateTime.now().toIso8601String().substring(0, 10),
        );
        final note = await local.createNote();
        note.title = 'Открытая заметка';
        note.body = 'Текст останется в корзине';
        await local.save(note);
        await remote.replica.receive(
          await local.replica.outgoing(remote.replica.deviceId),
        );
      });
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      await tester.pumpWidget(LadnoApp(store: local));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Открытая заметка'));
      await tester.pumpAndSettle();
      final editor = find.widgetWithText(TextField, 'Название заметки');
      expect(tester.widget<TextField>(editor).readOnly, isFalse);
      final workspace = tester.state(find.byType(Workspace)) as dynamic;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(workspace.sync.active, isTrue);
      await tester.runAsync(() async {
        final note = (await remote.notes()).single;
        note.deleted = true;
        await remote.save(note);
        await local.replica.receive(
          await remote.replica.outgoing(local.replica.deviceId),
        );
      });
      final Future<void> refreshed = workspace.refreshRemote();
      await tester.pumpAndSettle();
      await refreshed;
      expect(tester.widget<TextField>(editor).readOnly, isTrue);
      expect(
        find.text('Заметка в корзине. Восстановите её для редактирования.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await local.close();
        await remote.close();
        await root.delete(recursive: true);
      });
      await tester.binding.setSurfaceSize(null);
    },
  );
}
