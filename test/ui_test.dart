import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ladno/data/store.dart';
import 'package:ladno/main.dart';

void main() {
  sqfliteFfiInit();
  setUpAll(() async {
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '.tooling/flutter';
    final icons = File(
      '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    if (await icons.exists()) {
      final loader = FontLoader('MaterialIcons');
      loader.addFont(
        Future.value(ByteData.sublistView(await icons.readAsBytes())),
      );
      await loader.load();
    }
    final font = File(
      '/usr/share/fonts/liberation-sans-fonts/LiberationSans-Regular.ttf',
    );
    if (await font.exists()) {
      final loader = FontLoader('Roboto');
      loader.addFont(
        Future.value(ByteData.sublistView(await font.readAsBytes())),
      );
      await loader.load();
    }
  });
  for (final scenario in [
    (const Size(1440, 900), false),
    (const Size(390, 844), false),
    (const Size(320, 640), false),
    (const Size(1440, 900), true),
    (const Size(390, 844), true),
  ]) {
    final size = scenario.$1;
    final dark = scenario.$2;
    testWidgets('Навигация, редактор и сохранение ${size.width} dark=$dark', (
      tester,
    ) async {
      late Directory dir;
      late Store store;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('ladno-ui-');
        store = await Store.open(databaseFactoryFfiNoIsolate, dir);
        await store.setSetting('theme', dark ? 'dark' : 'light');
        await store.setSetting(
          'lastBackup',
          DateTime.now().toIso8601String().substring(0, 10),
        );
      });
      await tester.binding.setSurfaceSize(size);
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: LadnoApp(store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ладно'), findsOneWidget);
      final create = find.byTooltip(
        size.width >= 1050 ? 'Новая заметка (Ctrl+N)' : 'Новая заметка',
      );
      await tester.tap(create);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Название заметки'),
        'Тестовая заметка',
      );
      await tester.enterText(
        find.widgetWithText(
          TextField,
          'Запишите то, что важно…\n\nМожно использовать Markdown.',
        ),
        '## Важные мысли\n\nПланы становятся понятнее, когда записаны.\n\n- [ ] Обдумать идею\n- [x] Сделать первый шаг',
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      expect((await store.notes()).single.title, 'Тестовая заметка');
      expect(find.text('Сохранено локально'), findsOneWidget);
      // Test fixtures only; never inserted by the application.
      Future<void> screenshot(String view) async {
        await tester.runAsync(() async {
          final boundary =
              capture.currentContext!.findRenderObject()
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('artifacts').create();
          await File(
            'artifacts/$view-${size.width.toInt()}${dark ? '-dark' : ''}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }

      await screenshot('editor');
      await tester.tap(find.byTooltip('Предпросмотр Markdown'));
      await tester.pumpAndSettle();
      expect(find.text('Важные мысли'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (size.width < 1050) {
        await tester.tap(find.byTooltip('К списку'));
        await tester.pumpAndSettle();
      }
      await screenshot(size.width < 1050 ? 'list' : 'preview');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await store.close();
        await dir.delete(recursive: true);
      });
      await tester.binding.setSurfaceSize(null);
    });
  }
}
