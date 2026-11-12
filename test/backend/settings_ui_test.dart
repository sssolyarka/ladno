import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ladno/data/store.dart';
import 'package:ladno/sync/backend_controller.dart';
import 'package:ladno/sync/backend_connection.dart';
import 'package:ladno/sync/secret_store.dart';
import 'package:ladno/widgets/backend_settings.dart';

class MemoryStore implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

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
      final file = File(pair.$1);
      if (await file.exists()) {
        final loader = FontLoader(pair.$2)
          ..addFont(
            Future.value(ByteData.sublistView(await file.readAsBytes())),
          );
        await loader.load();
      }
    }
  });
  for (final width in [390.0, 1440.0]) {
    testWidgets('HTTPS-настройки и отказ небезопасному адресу $width', (
      tester,
    ) async {
      late Store store;
      late Directory directory;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('ladno-server-ui-');
        store = await Store.open(databaseFactoryFfiNoIsolate, directory);
      });
      final sync = BackendSyncController(
        store,
        onDataChanged: () {},
        secrets: MemoryStore(),
      );
      await tester.binding.setSurfaceSize(Size(width, 900));
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: BackendSettings(sync: sync),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        defaultBackendUrl,
      );
      expect(find.text('Одноразовый код подключения'), findsOneWidget);
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('artifacts').create(recursive: true);
        await File('artifacts/backend-settings-${width.toInt()}.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await tester.enterText(
        find.byType(TextField).at(0),
        'http://makar.frogville.fun',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Подключить сервер'));
      await tester.pumpAndSettle();
      expect(
        find.text('Введите HTTPS-адрес сервера без пути и параметров.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await sync.close();
      sync.dispose();
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await store.close();
        await directory.delete(recursive: true);
      });
      await tester.binding.setSurfaceSize(null);
    });
  }
}
