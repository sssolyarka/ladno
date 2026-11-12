import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:ladno_backend/backend.dart';

Future<void> main(List<String> args) async {
  final backend = await Backend.open(
    Directory(Platform.environment['DATA_DIR'] ?? '/data'),
    maxOperations: int.parse(
      Platform.environment['MAX_OPERATIONS'] ?? '100000',
    ),
    maxStorageBytes: int.parse(
      Platform.environment['MAX_STORAGE_BYTES'] ?? '10737418240',
    ),
  );
  if (args.isNotEmpty) {
    try {
      switch (args.first) {
        case 'invite':
          stdout.writeln(await backend.invite());
        case 'recover':
          await backend.recoverIdentity();
          stdout.writeln(
            'Server identity rotated; enroll all devices again after restart',
          );
        case 'devices':
          for (final device in await backend.devices()) {
            stdout.writeln(
              '${device['id']}\t${device['revoked'] == 1 ? 'revoked' : 'active'}\t${device['name']}',
            );
          }
        case 'revoke':
          if (args.length != 2) {
            throw const FormatException('Use: revoke DEVICE_UUID');
          }
          await backend.revoke(args[1]);
          stdout.writeln('Device revoked');
        default:
          throw const FormatException(
            'Use: invite | devices | revoke DEVICE_UUID | recover',
          );
      }
    } finally {
      await backend.close();
    }
    return;
  }
  await backend.listen(port: int.parse(Platform.environment['PORT'] ?? '8080'));
  stdout.writeln('Ladno backend listening');
  var stopping = false;
  Future<void> shutdown() async {
    if (stopping) return;
    stopping = true;
    await backend.close();
    exit(0);
  }

  Future<void> commands = Future.value();
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    commands = commands.then((_) async {
      final parts = line.trim().split(RegExp(r'\s+'));
      try {
        switch (parts.first) {
          case 'invite':
            stdout.writeln(
              'One-use invite (10 minutes): ${await backend.invite()}',
            );
          case 'devices':
            for (final device in await backend.devices()) {
              stdout.writeln(
                '${device['id']}\t${device['revoked'] == 1 ? 'revoked' : 'active'}\t${device['name']}',
              );
            }
          case 'revoke':
            if (parts.length != 2)
              throw const FormatException('Use: revoke DEVICE_UUID');
            await backend.revoke(parts[1]);
            stdout.writeln('Device revoked');
          case 'stop':
            await shutdown();
          case 'help':
            stdout.writeln(
              'Commands: invite | devices | revoke DEVICE_UUID | stop',
            );
          case '':
            break;
          default:
            stdout.writeln('Unknown command; type help');
        }
      } catch (_) {
        stderr.writeln('Command failed; check arguments and storage.');
      }
    });
  }, onError: (Object _) {});
  for (final signal in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    signal.watch().listen((_) => unawaited(shutdown()));
  }
}
