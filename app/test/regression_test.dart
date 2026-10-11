// Regression tests for bugs that shipped in v1.3.x and must not return.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:ipchakra/services/v2ray_service.dart';
import 'package:ipchakra/services/vpn_controller.dart';
import 'package:ipchakra/services/warp_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('WARP is never probed over TCP and never labelled dead', () async {
    // Regression (v1.3.x): WireGuard/WARP runs over UDP, so a TCP probe
    // reported a working WARP tunnel as "dead". The health service must
    // short-circuit WARP servers to working without any probe.
    final health = HealthService();
    const warpServer = VpnServer(
      id: 'warp-test',
      name: 'WARP Free',
      protocol: 'wireguard',
      source: 'warp',
      warp: true,
    );
    await health.checkAll([warpServer]);
    expect(health.isWorking('warp-test'), isTrue);
  });

  test('VpnServer JSON without a tier field still parses (old cache)',
      () {
    final s = VpnServer.fromJson({
      'id': 'old-1',
      'name': 'Old Server',
      'protocol': 'wireguard',
    });
    expect(s.tier, '');
    expect(s.isStealth, isFalse);
  });

  test('Stealth Auto with no candidates fails honestly, never connects',
      () async {
    final vpn = VpnController(WarpService());
    await vpn.connectStealthAuto(const []);
    expect(vpn.state, VpnState.error);
    expect(vpn.lastError, isNotNull);
    expect(vpn.lastError, contains('No stealth servers available'));
    expect(vpn.currentServer, isNull);
  });

  test('Feed cap keeps every stealth tier represented', () {
    // A plain tier-sort + take() would let whichever tier floods the
    // feeds occupy the whole cap and starve the others out — but the
    // Stealth Auto ladder needs every tier present. The cap must give
    // every tier its guaranteed share (v2.3.0 quotas, cap 600:
    // Reality 200 / Hysteria2 60 / TLS 150 / Shadowsocks 110 /
    // VMess 80 — Reality never below its 175 floor, Hysteria2 never
    // below its 45 floor).
    final svc = V2RayService();
    final servers = <VpnServer>[];
    for (var i = 0; i < 250; i++) {
      servers.add(svc.debugToServer(
          'vless://u@10.0.0.1:${1000 + i}?security=reality#R$i')!);
      servers.add(svc.debugToServer('trojan://pw@10.0.0.2:${2000 + i}#T$i')!);
      servers.add(svc.debugToServer(
          'ss://YWVzLTI1Ni1nY206cGFzcw==@10.0.0.3:${3000 + i}#S$i')!);
      servers.add(svc.debugToServer(
          'vmess://${base64Encode(utf8.encode(jsonEncode({
                'v': '2',
                'ps': 'V$i',
                'add': '10.0.0.4',
                'port': '${4000 + i}',
                'id': '00000000-0000-0000-0000-000000000000',
                'aid': '0',
                'net': 'tcp',
                'type': 'none',
              })))}')!);
      if (i < 100) {
        servers.add(svc.debugToServer(
            'hysteria2://pw@10.0.0.5:${5000 + i}?sni=h#H$i')!);
      }
    }
    final capped = V2RayService.debugCapByTier(servers);
    expect(capped.length, 600);
    expect(capped.where((s) => s.tier == 'Reality').length, 200);
    expect(capped.where((s) => s.tier == 'Hysteria2').length, 60);
    expect(capped.where((s) => s.tier == 'TLS').length, 150);
    expect(capped.where((s) => s.tier == 'Shadowsocks').length, 110);
    expect(capped.where((s) => s.tier == 'VMess').length, 80);
    // Still grouped by tier: Reality first, VMess last.
    final lastReality = capped.lastIndexWhere((s) => s.tier == 'Reality');
    final firstHy2 = capped.indexWhere((s) => s.tier == 'Hysteria2');
    final lastHy2 = capped.lastIndexWhere((s) => s.tier == 'Hysteria2');
    final firstTls = capped.indexWhere((s) => s.tier == 'TLS');
    final lastTls = capped.lastIndexWhere((s) => s.tier == 'TLS');
    final firstSs = capped.indexWhere((s) => s.tier == 'Shadowsocks');
    expect(lastReality, lessThan(firstHy2));
    expect(lastHy2, lessThan(firstTls));
    expect(lastTls, lessThan(firstSs));
  });

  test('shouldHonorConnectedEvent truth table', () {
    // A native "connected" event counts only while an attempt or a
    // session is live AND a server is still selected.
    expect(shouldHonorConnectedEvent(VpnState.connecting, true), isTrue);
    expect(shouldHonorConnectedEvent(VpnState.connected, true), isTrue);
    expect(shouldHonorConnectedEvent(VpnState.connecting, false), isFalse);
    expect(shouldHonorConnectedEvent(VpnState.connected, false), isFalse);
    expect(shouldHonorConnectedEvent(VpnState.disconnected, true), isFalse);
    expect(shouldHonorConnectedEvent(VpnState.disconnecting, true), isFalse);
    expect(shouldHonorConnectedEvent(VpnState.error, true), isFalse);
    expect(shouldHonorConnectedEvent(VpnState.disconnected, false), isFalse);
  });

  test('late native connected event after disconnect does not resurrect',
      () {
    // Regression (v2.0.0, found on Shiv's S25): the first tap on
    // "Tap to disconnect" appeared to reconnect, and only the second
    // tap disconnected. The V2Ray plugin emits periodic status ticks
    // carrying CONNECTED; a tick landing after disconnect() called the
    // unguarded _markConnected() and resurrected the UI to Connected
    // over a tunnel that was already down.
    final vpn = VpnController(WarpService());
    const server = VpnServer(
      id: 'guard-1',
      name: 'Guard Server',
      protocol: 'v2ray',
      source: 'v2ray',
      shareLink: 'ss://YWVzLTI1Ni1nY206cGFzcw==@203.0.113.9:8388#Guard',
      tier: 'Shadowsocks',
    );

    // While connecting, the event is honoured.
    vpn.currentServer = server;
    vpn.state = VpnState.connecting;
    vpn.debugHandleNativeConnectedEvent();
    expect(vpn.state, VpnState.connected);
    expect(vpn.connectedAt, isNotNull);

    // Simulate the completed disconnect: disconnect() nulls the
    // session before stopping the engines, so state is disconnected
    // with no server when the late tick lands.
    vpn.currentServer = null;
    vpn.connectedAt = null;
    vpn.state = VpnState.disconnected;
    vpn.debugHandleNativeConnectedEvent();
    expect(vpn.state, VpnState.disconnected);
    expect(vpn.currentServer, isNull);
    expect(vpn.connectedAt, isNull);

    // Also ignored while disconnecting...
    vpn.state = VpnState.disconnecting;
    vpn.debugHandleNativeConnectedEvent();
    expect(vpn.state, VpnState.disconnecting);

    // ...and in the error state, even with a stale server reference.
    vpn.state = VpnState.error;
    vpn.currentServer = server;
    vpn.debugHandleNativeConnectedEvent();
    expect(vpn.state, VpnState.error);
  });

  test('stealth server ids are stable (no String.hashCode)', () {
    // Regression guard: ids used to be built from String.hashCode,
    // which Dart does not guarantee stable across app restarts — the
    // persisted stealth_last_good id silently stopped matching. The
    // FNV-1a based id must be identical for the same link, always.
    const link = 'trojan://pw@203.0.113.7:443?security=tls#Stable';
    final a = V2RayService().debugToServer(link)!;
    final b = V2RayService().debugToServer(link)!;
    expect(a.id, b.id);
    expect(a.id, 'v2ray-${V2RayService.stableLinkId(link)}');
    expect(
      V2RayService.stableLinkId(link),
      matches(RegExp(r'^[0-9a-f]{8}$')),
    );
    final other = V2RayService().debugToServer(
      'trojan://pw@203.0.113.8:443?security=tls#Stable',
    )!;
    expect(other.id, isNot(a.id));
  });

  test('Mode can switch to stealth and back without a tunnel', () {
    final vpn = VpnController(WarpService());
    expect(vpn.mode, AppMode.free);
    vpn.setMode(AppMode.stealth);
    expect(vpn.mode, AppMode.stealth);
    vpn.setMode(AppMode.chakra);
    expect(vpn.mode, AppMode.chakra);
    vpn.setMode(AppMode.free);
    expect(vpn.state, VpnState.disconnected);
    expect(vpn.currentServer, isNull);
  });
}
