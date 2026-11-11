import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/store.dart';
import 'device_vault.dart';
import 'discovery.dart';
import 'pairing.dart';
import 'tls_transport.dart';

class SyncController extends ChangeNotifier {
  final Store store;
  final SecretStore secrets;
  final bool useDiscovery;
  final InternetAddress bindAddress;
  final int preferredPort;
  final void Function() onDataChanged;
  DeviceVault? vault;
  TlsSyncServer? server;
  PairingServer? pairing;
  LanDiscovery? _discovery;
  Timer? _retry, _debounce, _pairExpiry;
  Completer<void>? _ready, _idle;
  Future<void> _lifecycle = Future.value();
  final Map<String, Uri> _addresses = {};
  final List<TlsSyncClient> _clients = [];
  final Map<String, String> peerStatus = {};
  final Map<String, DateTime> syncedAt = {};
  String status = 'Не подключено';
  bool enabled = false,
      active = true,
      _closed = false,
      _busy = false,
      _starting = false;
  SyncController(
    this.store, {
    required this.onDataChanged,
    this.secrets = const OsSecretStore(),
    this.useDiscovery = true,
    InternetAddress? bindAddress,
    this.preferredPort = 43821,
  }) : bindAddress = bindAddress ?? InternetAddress.anyIPv4;
  List<PairedDevice> get peers => vault?.peers ?? [];
  Future<void> initialize() async {
    if (await store.setting('sync.enabled') == 'true') await enable();
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> enable() async {
    if (_closed || _starting || server != null) return;
    _starting = true;
    _ready = Completer<void>();
    status = 'Подготовка подключения…';
    _notify();
    try {
      vault = await DeviceVault.open(store.replica.deviceId, storage: secrets);
      final identity = vault!.identity;
      Future<TlsSyncServer> start(int port) => TlsSyncServer.start(
        replica: store.replica,
        identity: identity,
        trusted: peers.map((p) => p.certificate).toList(),
        attachments: store.attachments,
        address: bindAddress,
        port: port,
        onDataChanged: () {
          onDataChanged();
          _notify();
        },
      );
      try {
        server = await start(preferredPort);
      } on SocketException {
        server = await start(0);
      }
      if (_closed || !active) {
        await server?.close();
        server = null;
        return;
      }
      enabled = true;
      await store.setSetting('sync.enabled', 'true');
      status = peers.isEmpty ? 'Устройства не подключены' : 'Готово к обмену';
      if (useDiscovery) {
        _discovery = LanDiscovery();
        try {
          await _discovery!.start(store.replica.deviceId, server!.port, (
            id,
            address,
          ) {
            if (peers.any((p) => p.certificate.deviceId == id)) {
              _addresses[id] = address;
              unawaited(syncNow());
            }
          });
        } on Object {
          status = 'Поиск в сети недоступен. Подключитесь по QR или адресу.';
        }
      }
      _retry?.cancel();
      _retry = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(syncNow()),
      );
      unawaited(syncNow());
    } on Object {
      status = 'Подключение недоступно. Проверьте хранилище ключей ОС и разрешения локальной сети.';
      await server?.close();
      server = null;
    } finally {
      _starting = false;
      _ready?.complete();
      _notify();
    }
  }

  Future<List<String>> localAddresses() async {
    final addresses = <String>[];
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      for (final address in interface.addresses) {
        if (!address.isLoopback) addresses.add(address.address);
      }
    }
    return addresses;
  }

  PairedDevice self(String host) {
    if (vault == null || server == null) {
      throw const FormatException('Сначала включите подключение.');
    }
    return PairedDevice(
      vault!.identity.certificate,
      Platform.isAndroid
          ? 'Телефон Android'
          : Platform.isWindows
          ? 'Компьютер Windows'
          : 'Компьютер Fedora',
      Uri(scheme: 'https', host: host, port: server!.port),
    );
  }

  Future<void> addPeer(PairedDevice peer) async {
    await vault!.add(peer);
    try {
      server!.trust(peer.certificate);
    } on Object {
      await vault!.revoke(peer.certificate.deviceId);
      rethrow;
    }
    await store.replica.forgetReceipts(peer.certificate.deviceId);
    _notify();
  }

  Future<PairingServer> beginPairing(String host) async {
    await pairing?.close();
    _pairExpiry?.cancel();
    pairing = await PairingServer.start(
      identity: vault!.identity,
      self: self(host),
      address: bindAddress,
      onPaired: addPeer,
      onChanged: _notify,
    );
    _notify();
    _pairExpiry = Timer(
      const Duration(minutes: 2),
      () => unawaited(endPairing()),
    );
    return pairing!;
  }

  Future<void> endPairing() async {
    _pairExpiry?.cancel();
    await pairing?.close();
    pairing = null;
    _notify();
  }

  Future<void> revoke(String id) async {
    // A single controller serializes sessions; cancellation prevents an in-flight
    // connection from silently finishing after trust was revoked.
    for (final client in _clients) {
      client.cancel();
    }
    await vault!.revoke(id);
    await server?.revoke(id);
    _addresses.remove(id);
    peerStatus.remove(id);
    syncedAt.remove(id);
    _notify();
  }

  void changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 1), () => unawaited(syncNow()));
  }

  Future<void> syncNow() async {
    if (_closed || !enabled || !active || server == null || _busy) return;
    _busy = true;
    _idle = Completer<void>();
    try {
      for (final peer in peers) {
        if (_closed || !active) break;
        final id = peer.certificate.deviceId;
        status = 'Идёт синхронизация';
        peerStatus[id] = status;
        _notify();
        final client = TlsSyncClient(
          identity: vault!.identity,
          peer: peer.certificate,
          endpoint: _addresses[id] ?? peer.endpoint,
        );
        _clients.add(client);
        try {
          final result = await client.synchronize(
            store.replica,
            attachments: store.attachments,
          );
          if (_closed ||
              !active ||
              !peers.any((p) => p.certificate.deviceId == id)) {
            continue;
          }
          syncedAt[id] = DateTime.now();
          peerStatus[id] = result.filesSynchronized
              ? 'Синхронизировано'
              : 'Текст синхронизирован; ${result.unavailableAttachments.length} вложений пока недоступно';
          status = peerStatus[id]!;
          onDataChanged();
        } on Object {
          if (!_closed) {
            peerStatus[id] = 'Другое устройство недоступно';
            status = peerStatus[id]!;
          }
        } finally {
          client.cancel();
          _clients.remove(client);
          _notify();
        }
      }
    } finally {
      _busy = false;
      _idle?.complete();
    }
  }

  Future<void> pause() => _lifecycle = _lifecycle.then((_) => _pause());
  Future<void> _pause() async {
    active = false;
    if (_starting) await _ready?.future;
    _retry?.cancel();
    _debounce?.cancel();
    for (final client in _clients.toList()) {
      client.cancel();
    }
    if (_busy) await _idle?.future;
    await endPairing();
    await _discovery?.close();
    _discovery = null;
    await server?.close();
    server = null;
  }

  Future<void> resume() => _lifecycle = _lifecycle.then((_) => _resume());
  Future<void> _resume() async {
    active = true;
    if (enabled || await store.setting('sync.enabled') == 'true') {
      await enable();
    }
  }

  Future<void> disable() async {
    enabled = false;
    await store.setSetting('sync.enabled', 'false');
    await pause();
    active = true;
    status = 'Подключение выключено';
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
