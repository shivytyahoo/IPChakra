// v2.3.6 auto-refresh + best-server tests.
//
// The 2026-11-14 round: lists only refreshed at process boot (or on
// upgrade / manual refresh), so an app left in memory for days kept
// serving dead servers; Free mode always took db.free.first; Stealth
// Auto ordered by latency only. Now: lists re-check on every
// open/resume with shorter TTLs, Free picks the lowest-latency
// WORKING WARP endpoint, and Stealth Auto orders by download speed.

import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:ipchakra/services/v2ray_service.dart';

VpnServer _warp({
  required String id,
  required String endpoint,
}) {
  return VpnServer(
    id: id,
    name: id,
    country: 'CF',
    protocol: 'wireguard',
    source: 'warp',
    warp: true,
    endpoint: endpoint,
  );
}

VpnServer _stealth({
  required String id,
  int? pingMs,
}) {
  return VpnServer(
    id: id,
    name: id,
    country: 'JP',
    protocol: 'v2ray',
    source: 'snsub',
    pingMs: pingMs,
  );
}

void main() {
  test('stealth lists expire after 4h, not 12h', () {
    expect(V2RayService.listTtl, const Duration(hours: 4));
  });

  group('Free mode best-WARP pick (pickFastestInGroup)', () {
    test('picks the lowest-latency WORKING endpoint, not list order',
        () {
      final health = HealthService();
      final servers = [
        _warp(id: 'warp-a', endpoint: '162.159.192.1:2408'),
        _warp(id: 'warp-b', endpoint: '162.159.193.1:2408'),
        _warp(id: 'warp-c', endpoint: '188.114.96.1:2408'),
      ];
      // List order says A; measured latency says C is fastest.
      health.status['warp-a'] = true;
      health.status['warp-b'] = true;
      health.status['warp-c'] = true;
      health.latencyMs['warp-a'] = 120;
      health.latencyMs['warp-b'] = 90;
      health.latencyMs['warp-c'] = 35;
      expect(
        pickFastestInGroup(servers, health)?.id,
        'warp-c',
      );
    });

    test('dead and unchecked endpoints never win', () {
      final health = HealthService();
      final servers = [
        _warp(id: 'warp-dead', endpoint: '162.159.192.1:2408'),
        _warp(id: 'warp-live', endpoint: '162.159.193.1:2408'),
        _warp(id: 'warp-new', endpoint: '188.114.96.1:2408'),
      ];
      health.status['warp-dead'] = false;
      health.status['warp-live'] = true;
      health.latencyMs['warp-dead'] = 5; // fastest on paper, dead
      health.latencyMs['warp-live'] = 200;
      expect(
        pickFastestInGroup(servers, health)?.id,
        'warp-live',
      );
    });

    test('null when nothing is measured yet (caller probes first)',
        () {
      final health = HealthService();
      final servers = [
        _warp(id: 'warp-a', endpoint: '162.159.192.1:2408'),
        _warp(id: 'warp-b', endpoint: '162.159.193.1:2408'),
      ];
      expect(pickFastestInGroup(servers, health), isNull);
    });
  });

  group('Stealth Auto ordering (sortByDownloadSpeed)', () {
    test('a slow-but-fast-downloading server outranks a fast-pinging one',
        () {
      final health = HealthService();
      final servers = [
        _stealth(id: 'ping-20', pingMs: 20),
        _stealth(id: 'dl-50mbps', pingMs: 300),
      ];
      health.status['ping-20'] = true;
      health.status['dl-50mbps'] = true;
      health.latencyMs['ping-20'] = 20;
      health.latencyMs['dl-50mbps'] = 300;
      health.speedMbps['dl-50mbps'] = 50;
      final ordered =
          sortByDownloadSpeed(servers, health).map((s) => s.id).toList();
      // Auto-connect tries candidates in this order, so the
      // 50 Mbps server must come first despite its 300 ms ping.
      expect(ordered, ['dl-50mbps', 'ping-20']);
    });
  });
}
