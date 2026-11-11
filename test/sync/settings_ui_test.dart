import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:ladno/data/store.dart';
import 'package:ladno/sync/controller.dart';
import 'package:ladno/widgets/sync_settings.dart';

import 'pairing_controller_test.dart' show MemorySecrets;

void main() {
  sqfliteFfiInit();
  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    testWidgets('Настройки и QR помещаются на экране ${size.width}', (
      tester,
    ) async {
      late Directory directory;
      late Store store;
      late SyncController sync;
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
        directory = await Directory.systemTemp.createTemp('ladno-settings-ui-');
        store = await Store.open(databaseFactoryFfiNoIsolate, directory);
        sync = SyncController(
          store,
          onDataChanged: () {},
          secrets: MemorySecrets(),
          useDiscovery: false,
          bindAddress: InternetAddress.loopbackIPv4,
          preferredPort: 0,
        );
        await sync.enable();
      });
      await tester.binding.setSurfaceSize(size);
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SyncSettings(sync: sync),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Показать QR'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsOneWidget);
      final data = sync.pairing!
          .invitation(sync.pairing!.self.endpoint.host)
          .encode();
      expect(
        QrValidator.validate(
          data: data,
          version: QrVersions.auto,
          errorCorrectionLevel: QrErrorCorrectLevel.L,
        ).status,
        QrValidationStatus.valid,
      );
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('artifacts').create();
        await File('artifacts/pairing-${size.width.toInt()}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await tester.runAsync(() async {
        await tester.tap(find.text('Отмена'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await sync.close();
        await store.close();
        await directory.delete(recursive: true);
      });
      await tester.binding.setSurfaceSize(null);
    });
  }
}
