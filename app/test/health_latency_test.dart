// Tests for the v2.0.1 health fixes: measured latency, incremental
// checkMissing (only unchecked servers are probed), the shared
// fastest-first ordering helper, and dead-server exclusion.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/services/health_service.dart';

VpnServer _ssServer(String id, int port) => VpnServer(
      id: id,
      name: id,
      protocol: 'v2ray',
      source: 'v2ray',
      shareLink: 'ss://YWVzLTI1Ni1nY206cGFzcw==@127.0.0.1:$port#X',
    );

VpnServer _plain(String id, {int? pingMs}) => VpnServer(
      id: id,
      name: id,
      protocol: 'openvpn',
      source: 'vpngate',
      pingMs: pingMs,
    );

void main() {
  test('TCP probe records latency', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = listener.port;
    // Accept every incoming connection so probes can complete.
    final sub = listener.listen((socket) {
      socket.listen((_) {}, onError: (_) {});
    });
    try {
      final health = HealthService();
      final a = _ssServer('srv-a', port);
      await health.checkMissing([a]);
      expect(health.isWorking('srv-a'), isTrue);
      expect(health.latencyOf('srv-a'), isNotNull);
      expect(health.latencyOf('srv-a'), greaterThanOrEqualTo(0));
    } finally {
      await sub.cancel();
      await listener.close();
    }
  });

  test('checkMissing probes only unchecked ids', () async {
    // A is probed while its port is open, the port then closes, and a
    // second checkMissing over [A, B] must leave A's verdict untouched
    // (a re-probe would now find the port closed and flip A to dead),
    // while B — unchecked so far — is probed and found dead.
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = listener.port;
    await _checkMissingSkipsChecked(port, listener);
  });

  test('WARP gets a working verdict from checkMissing, with no latency',
      () async {
    final health = HealthService();
    const warpServer = VpnServer(
      id: 'warp-x',
      name: 'WARP Free',
      protocol: 'wireguard',
      source: 'warp',
      warp: true,
    );
    await health.checkMissing([warpServer]);
    expect(health.isWorking('warp-x'), isTrue);
    expect(health.latencyOf('warp-x'), isNull);
  });

  test('sortByHealthAndLatency: fastest first, working, unchecked, dead',
      () {
    final health = HealthService();
    health.status['fast'] = true;
    health.latencyMs['fast'] = 40;
    health.status['slow'] = true;
    health.latencyMs['slow'] = 220;
    health.status['api'] = true; // no probe latency, API ping 90
    health.status['nol'] = true; // working, no speed info at all
    health.status['dead'] = false;

    final input = [
      _plain('dead'),
      _plain('new2'),
      _plain('slow'),
      _plain('nol'),
      _plain('new1'),
      _plain('api', pingMs: 90),
      _plain('fast'),
    ];
    final out =
        sortByHealthAndLatency(input, health).map((s) => s.id).toList();
    expect(
      out,
      ['fast', 'api', 'slow', 'nol', 'new2', 'new1', 'dead'],
    );
  });

  test('aliveOrAll drops dead servers unless all are dead', () {
    final health = HealthService();
    health.status['dead1'] = false;
    health.status['dead2'] = false;
    final mixed = [_plain('dead1'), _plain('fresh'), _plain('dead2')];
    expect(
      aliveOrAll(mixed, health).map((s) => s.id),
      ['fresh'],
    );
    final allDead = [_plain('dead1'), _plain('dead2')];
    expect(aliveOrAll(allDead, health).length, 2);
  });

  test('Hysteria2: a reachable host is working, with no latency',
      () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sub = listener.listen((socket) {
      socket.listen((_) {}, onError: (_) {});
    });
    try {
      final health = HealthService();
      final hy2 = VpnServer(
        id: 'hy2-up',
        name: 'hy2-up',
        protocol: 'v2ray',
        source: 'v2ray',
        tier: 'Hysteria2',
        shareLink: 'hysteria2://pw@127.0.0.1:${listener.port}#H',
      );
      await health.checkMissing([hy2]);
      expect(health.isWorking('hy2-up'), isTrue);
      // QUIC speed cannot be measured with a TCP probe — the server
      // must carry no latency, so it never jumps the fastest queue
      // on a meaningless number.
      expect(health.latencyOf('hy2-up'), isNull);
    } finally {
      await sub.cancel();
      await listener.close();
    }
  });

  test('Hysteria2: an unreachable host is left UNCHECKED, never dead',
      () async {
    // Nothing listens on this loopback port (nor on 443/80): a
    // Hysteria2 server speaks UDP/QUIC, so silence on TCP says
    // nothing about it. The verdict must stay "unchecked" — the
    // server remains eligible for Stealth Auto.
    final health = HealthService();
    final hy2 = VpnServer(
      id: 'hy2-down',
      name: 'hy2-down',
      protocol: 'v2ray',
      source: 'v2ray',
      tier: 'Hysteria2',
      shareLink: 'hysteria2://pw@127.0.0.1:59991#H',
    );
    await health.checkAll([hy2]);
    expect(health.status.containsKey('hy2-down'), isFalse);
    expect(health.isWorking('hy2-down'), isNull);
    expect(health.deadCount, 0);
  });
}

/// Runs the skip-checked scenario against an already-bound [listener]:
/// probe A (port open), close the listener, then checkMissing([A, B]).
Future<void> _checkMissingSkipsChecked(int port, ServerSocket listener) async {
  final sub = listener.listen((socket) {
    socket.listen((_) {}, onError: (_) {});
  });
  final health = HealthService();
  final a = _ssServer('srv-a', port);
  await health.checkMissing([a]);
  expect(health.isWorking('srv-a'), isTrue);
  await sub.cancel();
  await listener.close();

  final b = _ssServer('srv-b', port); // same port, now closed
  await health.checkMissing([a, b]);
  expect(
    health.isWorking('srv-a'),
    isTrue,
    reason: 'an already-checked server must not be re-probed',
  );
  expect(health.isWorking('srv-b'), isFalse);
}
