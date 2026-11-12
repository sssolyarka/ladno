import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/store.dart';
import 'backend_connection.dart';
import 'secret_store.dart';
import 'tls_transport.dart';

class BackendSyncController extends ChangeNotifier {
  final Store store;
  final SecretStore secrets;
  final VoidCallback onDataChanged;
  BackendConnection? connection;
  String status = 'Сервер не подключён';
  DateTime? syncedAt;
  bool active = true, enabled = false, _closed = false, _busy = false;
  Timer? _retry, _debounce;
  TlsSyncClient? _client;
  Future<void>? _running;
  int _epoch = 0;
  String get _key => 'ladno.backend.${store.replica.deviceId}';
  BackendSyncController(
    this.store, {
    required this.onDataChanged,
    this.secrets = const OsSecretStore(),
  });
  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> initialize() async {
    final epoch = _epoch;
    try {
      final saved = await secrets.read(_key);
      if (_closed || epoch != _epoch) return;
      if (saved != null) {
        connection = BackendConnection.decode(saved);
        if (connection!.deviceId != store.replica.deviceId) {
          throw const FormatException('device');
        }
        enabled = await store.setting('backend.enabled') != 'false';
      }
      if (enabled) {
        _start();
        unawaited(syncNow());
      }
    } catch (_) {
      status = 'Хранилище подключения недоступно. Локальные данные сохранены.';
    }
    _notify();
  }

  Future<void> connect(String url, String invite, String name) async {
    _epoch++;
    await pause();
    active = true;
    // Check that protected storage works before consuming the one-use invite.
    final probe = '$_key.probe';
    await secrets.write(probe, 'ok');
    if (await secrets.read(probe) != 'ok') {
      throw const FormatException('Не удалось проверить защищённое хранилище.');
    }
    await secrets.delete(probe);
    final value = await BackendConnection.enroll(
      endpoint: backendEndpoint(url),
      deviceId: store.replica.deviceId,
      invite: invite.trim(),
      name: name.trim(),
    );
    final encoded = jsonEncode(value.toJson());
    await secrets.write(_key, encoded);
    if (await secrets.read(_key) != encoded) {
      throw const FormatException(
        'Не удалось сохранить токен. Он не будет записан открытым текстом.',
      );
    }
    await store.replica.forgetReceipts(value.serverId);
    connection = value;
    enabled = true;
    await store.setSetting('backend.enabled', 'true');
    _start();
    await syncNow();
  }

  void _start() {
    _retry?.cancel();
    if (!_closed && active && enabled) {
      _retry = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(syncNow()),
      );
    }
  }

  void changed() {
    _debounce?.cancel();
    if (!_closed) {
      _debounce = Timer(const Duration(seconds: 1), () => unawaited(syncNow()));
    }
  }

  Future<void> syncNow() {
    if (_closed || !active || !enabled || connection == null || _busy) {
      return Future.value();
    }
    _busy = true;
    final run = _sync();
    _running = run;
    return run;
  }

  Future<void> _sync() async {
    final c = connection!;
    status = 'Обмен с сервером…';
    _notify();
    final client = TlsSyncClient.backend(
      endpoint: c.endpoint,
      token: c.token,
      deviceId: store.replica.deviceId,
      serverId: c.serverId,
    );
    _client = client;
    try {
      final result = await client.synchronize(
        store.replica,
        attachments: store.attachments,
      );
      if (_closed || !active) return;
      syncedAt = DateTime.now();
      status = result.filesSynchronized
          ? 'Синхронизировано с сервером'
          : 'Текст синхронизирован; недоступных вложений: ${result.unavailableAttachments.length}';
      onDataChanged();
    } catch (e) {
      if (!_closed) {
        status = e is SyncTransportException && e.code == 'unauthorized'
            ? 'Доступ к серверу отозван или токен неверен'
            : 'Сервер недоступен. Изменения сохранены локально; обмен повторится.';
      }
    } finally {
      client.cancel();
      _client = null;
      _busy = false;
      _notify();
    }
  }

  Future<void> pause() async {
    active = false;
    _retry?.cancel();
    _debounce?.cancel();
    _client?.cancel();
    await _running;
  }

  Future<void> resume() async {
    if (_closed) return;
    active = true;
    _start();
    unawaited(syncNow());
  }

  Future<void> disable() async {
    _epoch++;
    enabled = false;
    await pause();
    await store.setSetting('backend.enabled', 'false');
    active = true;
    status = 'Обмен с сервером приостановлен';
    _notify();
  }

  Future<void> enable() async {
    enabled = connection != null;
    await store.setSetting('backend.enabled', enabled.toString());
    await resume();
    _notify();
  }

  Future<void> disconnect() async {
    await disable();
    await secrets.delete(_key);
    connection = null;
    status = 'Сервер отключён. Локальные записи сохранены.';
    _notify();
  }

  Future<void> close() async {
    _closed = true;
    await pause();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
