import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ladno/data/store.dart';
import 'package:ladno/planning/tasks.dart';
import 'package:ladno/widgets/task_board.dart';

void main() {
  sqfliteFfiInit();
  setUpAll(() async {
    for (final pair in [
      (
        '.tooling/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        'MaterialIcons',
      ),
      (
        '/usr/share/fonts/liberation-sans-fonts/LiberationSans-Regular.ttf',
        'Roboto',
      ),
    ]) {
      final f = File(pair.$1);
      if (await f.exists()) {
        final loader = FontLoader(pair.$2)
          ..addFont(Future.value(ByteData.sublistView(await f.readAsBytes())));
        await loader.load();
      }
    }
  });
  for (final width in [390.0, 1440.0]) {
    testWidgets('Создание, завершение и календарь $width', (tester) async {
      late Store store;
      late Directory root;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('ladno-task-ui-');
        store = await Store.open(databaseFactoryFfiNoIsolate, root);
        final book = TaskBook(store);
        final project = await book.createProject('Учёба');
        await book.createTask({
          'title': 'Подготовить введение',
          'projectId': project,
          'dueDate': '2026-11-12',
          'priority': 3,
          'tags': ['курсовая'],
        });
      });
      await tester.binding.setSurfaceSize(Size(width, 900));
      final capture = GlobalKey();
      Future<void> settle() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pumpAndSettle();
      }

      Future<void> screen(String name) async {
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('artifacts').create(recursive: true);
          await File('artifacts/$name-${width.toInt()}.png')
              .writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      Widget app(String section) => RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: const Locale('ru'),
          supportedLocales: const [Locale('ru')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff537665),
            ),
          ),
          home: Scaffold(
            body: TaskBoard(
              key: ValueKey(section),
              store: store,
              section: section,
              revision: 0,
              onChanged: () {},
            ),
          ),
        ),
      );
      await tester.pumpWidget(app('Задачи'));
      await settle();
      expect(find.text('Подготовить введение'), findsOneWidget);
      await screen('tasks');
      await tester.tap(find.widgetWithText(FilledButton, 'Задача'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(1), 'Забрать документы');
      await tester.pump();
      await screen('task-editor');
      await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
      await settle();
      expect(find.text('Забрать документы'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.bySemanticsLabel('Завершить Забрать документы'));
      await settle();
      expect(find.text('Забрать документы'), findsNothing);
      await tester.pumpWidget(app('Календарь'));
      await settle();
      expect(find.byType(CalendarDatePicker), findsOneWidget);
      await screen('calendar');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await store.close();
        await root.delete(recursive: true);
      });
      await tester.binding.setSurfaceSize(null);
    });
  }
}
