// v2.3.4 health-speed regression tests.
//
// Device complaint (2026-10-11): the Servers list "kept refreshing
// and checking dead/alive forever" and Connect waited behind it.
// Three structural causes, three tests:
//
// 1. Verdicts were memory-only, so EVERY launch re-probed ~5,800
//    servers from zero. Verdicts are now persisted and stay fresh
//    for 30 minutes: a fresh verdict is never re-probed by an
//    incremental check; a stale one is.
// 2. The connect path's bounded checkMissing queued behind the
//    background mega-run. The priority path runs immediately.
// 3. Port-less pool UDP entries made the incremental check PAY A
//    CONFIG DOWNLOAD (up to 15 s) per server. They are deferred to
//    the manual full refresh now; entries with a direct probe
//    target probe normally.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

VpnServer _server({
  required String id,
  String source = 'vpngate-pool',
  String? probeHost,
  int? probePort,
  bool probeUdp = false,
  Future<String> Function()? configLoader,
}) {
  return VpnServer(
    id: id,
    name: id,
    country: 'JP',
    protocol: 'openvpn',
    source: source,
    probeHost: probeHost,
    probePort: probePort,
    probeUdp: probeUdp,
    configLoader: configLoader,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('persisted fresh verdicts load and are NOT re-probed; stale are',
      () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => listener.close());
    final openPort = listener.port;
    // A port with nothing listening: a probe would flip the
    // verdict to dead instantly.
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = dead.port;
    await dead.close();

    final now = DateTime.now().millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'health_results_v1': jsonEncode({
        // Fresh (just probed): working, latency 42.
        'srv-fresh': [1, 42, now],
        // Stale (31 minutes old): working, no latency recorded.
        'srv-stale': [1, -1, now - 31 * 60 * 1000],
      }),
    });

    final health = HealthService();
    await health.loadPersisted();
    expect(health.isWorking('srv-fresh'), isTrue);
    expect(health.latencyOf('srv-fresh'), 42);
    expect(health.isWorking('srv-stale'), isTrue);

    // srv-fresh points at a CLOSED port now: if the incremental
    // check re-probed it, its verdict would flip to dead. It must
    // not — the verdict is fresh. srv-stale points at the OPEN
    // listener: re-probing it records a latency.
    await health.checkMissing([
      _server(
          id: 'srv-fresh', probeHost: '127.0.0.1', probePort: closedPort),
      _server(id: 'srv-stale', probeHost: '127.0.0.1', probePort: openPort),
    ]);

    expect(health.isWorking('srv-fresh'), isTrue,
        reason: 'a fresh verdict must survive an incremental check');
    expect(health.latencyOf('srv-fresh'), 42);
    expect(health.isWorking('srv-stale'), isTrue);
    expect(health.latencyOf('srv-stale'), isNotNull,
        reason: 'a stale verdict must be re-probed (latency appears)');
  });

  test('priority checkMissing probes immediately and records a verdict',
      () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => listener.close());
    final health = HealthService();
    await health.checkMissing(
      [_server(id: 'prio', probeHost: '127.0.0.1', probePort: listener.port)],
      priority: true,
    );
    expect(health.isWorking('prio'), isTrue);
    expect(health.latencyOf('prio'), isNotNull);
  });

  test(
      'incremental check defers port-less pool UDP entries (no config '
      'download) but probes direct-target entries', () async {
    var loaderCalls = 0;
    final udpPool = _server(
      id: 'pool-udp',
      probeHost: null,
      probePort: null,
      probeUdp: true,
      configLoader: () async {
        loaderCalls++;
        return 'client\nremote 192.0.2.1 1194 udp\n<ca>x</ca>';
      },
    );
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => listener.close());
    final tcpPool = _server(
      id: 'pool-tcp',
      probeHost: '127.0.0.1',
      probePort: listener.port,
    );

    final health = HealthService();
    await health.checkMissing([udpPool, tcpPool]);

    expect(loaderCalls, 0,
        reason:
            'the auto check must never download a config to probe a pool UDP entry');
    expect(health.isWorking('pool-udp'), isNull,
        reason: 'deferred entries stay unchecked until a manual refresh');
    expect(health.isWorking('pool-tcp'), isTrue);

    // The manual full refresh (checkAll) still resolves them.
    await health.checkAll([udpPool]);
    expect(loaderCalls, 1);
    expect(health.isWorking('pool-udp'), isNotNull);
  });
}
