import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

class LanDiscovery {
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription? _events;
  Future<void> start(
    String id,
    int port,
    void Function(String, Uri) found,
  ) async {
    final broadcast = _broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: 'Ladno-${id.substring(0, 8)}',
        type: '_ladno._tcp',
        port: port,
        attributes: {'id': id, 'v': '1'},
      ),
    );
    await broadcast.initialize();
    await broadcast.start();
    final discovery = _discovery = BonsoirDiscovery(type: '_ladno._tcp');
    await discovery.initialize();
    _events = discovery.eventStream!.listen((event) {
      if (event is BonsoirDiscoveryServiceFoundEvent) {
        event.service.resolve(discovery.serviceResolver);
      } else if (event is BonsoirDiscoveryServiceResolvedEvent) {
        final service = event.service;
        final peerId = service.attributes['id'];
        if (peerId == null || peerId == id || service.attributes['v'] != '1') {
          return;
        }
        for (final address in service.hostAddresses) {
          final parsed = InternetAddress.tryParse(address);
          if (parsed != null &&
              parsed.type == InternetAddressType.IPv4 &&
              !parsed.isLoopback) {
            found(
              peerId,
              Uri(scheme: 'https', host: address, port: service.port),
            );
            break;
          }
        }
      }
    }, onError: (Object _) {});
    await discovery.start();
  }

  Future<void> close() async {
    await _events?.cancel();
    try {
      await _discovery?.stop();
    } on Object {
      /* optional multicast */
    }
    try {
      await _broadcast?.stop();
    } on Object {
      /* optional multicast */
    }
  }
}
