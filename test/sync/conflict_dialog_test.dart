import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ladno/sync/replica.dart';
import 'package:ladno/widgets/conflict_dialog.dart';

void main() {
  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    testWidgets('Экран конфликта выбирает и объединяет версии: ${size.width}', (
      tester,
    ) async {
      await tester.runAsync(() async {
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
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final version = ReplicaObject(
        id: 'note',
        kind: 'note',
        fields: {'title': 'Планы', 'body': 'Купить хлеб', 'deleted': true},
        heads: ['one', 'two'],
        conflicts: {
          'body': [
            const FieldVersion('one', 'Купить молоко'),
            const FieldVersion('two', 'Купить хлеб'),
          ],
          'deletionVsEdit': [const FieldVersion('two', true)],
        },
      );
      Map<String, Object?>? result;
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(useMaterial3: true),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showDialog<Map<String, Object?>>(
                      context: context,
                      builder: (_) =>
                          ConflictDialog(version: version, folders: const {}),
                    );
                  },
                  child: const Text('Открыть'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Взять вариант 1'));
      await tester.tap(find.text('Взять вариант 1'));
      await tester.pump();
      final editor = find.widgetWithText(TextField, 'Текст после объединения');
      await tester.ensureVisible(editor);
      expect(
        tester.widget<TextField>(editor).controller!.text,
        'Купить молоко',
      );
      await tester.enterText(editor, 'Купить молоко и хлеб');
      final restore = find.byType(SwitchListTile);
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('artifacts').create();
        await File('artifacts/conflict-${size.width.toInt()}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('Сохранить объединение'));
      await tester.pumpAndSettle();
      expect(result!['body'], 'Купить молоко и хлеб');
      expect(result!['deleted'], isFalse);
    });
  }
}
