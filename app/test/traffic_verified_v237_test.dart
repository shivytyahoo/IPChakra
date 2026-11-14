// v2.3.7 traffic-verified servers.
//
// Device complaints (2026-11-14): in Stealth, the Fastest list's top
// servers mostly failed in practice — only 1-2 really connected, the
// rest showed "connected" but passed no internet; and with AdShield
// on, the connect stuck at "Connecting..." even though the log
// already said "Connected with ...".
//
// Root causes, three of them:
//
// 1. The health probe was TCP-only: a port that accepts TCP is not a
//    proxy that carries traffic. And the live stealth paths declared
//    "Connected" the moment the engine reported tunnel-up, with no
//    verification at all. Now every stealth connect runs through
//    the verified combination ladder, and servers that carried real
//    traffic are recorded traffic-verified and ranked first.
// 2. A late/duplicate CONNECTING status event from the V2Ray plugin
//    knocked a live session back to "Connecting..." —
//    shouldHonorConnectingEvent allowed it while connected. Now it
//    only honours the transition while an attempt is in flight.
// 3. The WARP "fastest endpoint" pick was a lie: WARP endpoints were
//    never latency-measured, so pickFastestInGroup always fell back
//    to the first entry. The probe now times the TCP refusal from
//    the WireGuard port, which is the endpoint's RTT.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/services/dns_combo.dart';
import 'package:ipchakra/services/dns_service.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:ipchakra/services/vpn_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

VpnServer _server({
  required String id,
  double? speedMbps,
  int? pingMs,
  String? endpoint,
  bool warp = false,
  String source = 'stealth',
}) {
  return VpnServer(
    id: id,
    name: id,
    country: 'SE',
    protocol: 'v2ray',
    source: source,
    speedMbps: speedMbps,
    pingMs: pingMs,
    endpoint: endpoint,
    warp: warp,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('traffic-verified verdicts', () {
    test('recordVerified marks working + verified; recordSpeed implies it',
        () {
      final health = HealthService();
      health.recordVerified('a');
      expect(health.isWorking('a'), true);
      expect(health.isVerified('a'), true);

      final health2 = HealthService();
      health2.recordSpeed('b', 12.5);
      expect(health2.isWorking('b'), true);
      expect(health2.isVerified('b'), true);
      expect(health2.speedOf('b'), 12.5);
    });

    test('recordDead revokes the traffic proof and clears stale numbers',
        () {
      final health = HealthService();
      health.recordVerified('a');
      health.recordSpeed('a', 20);
      health.latencyMs['a'] = 42;
      health.recordDead('a');
      expect(health.isWorking('a'), false);
      expect(health.isVerified('a'), false);
      expect(health.speedOf('a'), null);
      expect(health.latencyOf('a'), null);
    });

    test('a traffic proof older than 24h reads as unverified', () {
      final health = HealthService();
      health.recordVerified('a');
      expect(health.isVerified('a'), true);
      health.debugSetVerifiedAt(
        'a',
        DateTime.now().millisecondsSinceEpoch -
            HealthService.verifiedFor.inMilliseconds -
            1000,
      );
      expect(health.isVerified('a'), false);
    });

    test('verified proofs persist across launches', () async {
      final health = HealthService();
      health.recordVerified('a');
      // Let the debounced persist land.
      await Future.delayed(const Duration(milliseconds: 1000));
      final reloaded = HealthService();
      await reloaded.loadPersisted();
      expect(reloaded.isVerified('a'), true);
    });
  });

  group('verified-first ordering', () {
    test('sortByDownloadSpeed: verified beats TCP-working at any speed',
        () {
      final health = HealthService();
      final verifiedSlow = _server(id: 'verified-slow');
      final workingFast = _server(id: 'working-fast');
      final dead = _server(id: 'dead');
      health.recordVerified('verified-slow');
      health.recordSpeed('verified-slow', 5);
      health.status['working-fast'] = true;
      health.speedMbps['working-fast'] = 90;
      health.status['dead'] = false;
      final ordered = sortByDownloadSpeed(
        [workingFast, dead, verifiedSlow],
        health,
      );
      expect(ordered.map((s) => s.id).toList(),
          ['verified-slow', 'working-fast', 'dead']);
    });

    test('sortByHealthAndLatency: verified beats lower-latency TCP-only',
        () {
      final health = HealthService();
      final verified = _server(id: 'verified');
      final quick = _server(id: 'quick');
      health.recordVerified('verified');
      health.latencyMs['verified'] = 300;
      health.status['quick'] = true;
      health.latencyMs['quick'] = 20;
      final ordered = sortByHealthAndLatency([quick, verified], health);
      expect(ordered.map((s) => s.id).toList(), ['verified', 'quick']);
    });
  });

  group('WARP endpoint RTT', () {
    test('a refused TCP connect still measures the round trip', () async {
      final health = HealthService();
      // Bind a port, then close it: connecting to it is refused
      // at once, exactly like a live WireGuard endpoint's TCP port.
      final socket =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final rtt = await health.debugTimedTcpRtt('127.0.0.1', port);
      expect(rtt, isNotNull);
      expect(rtt!, greaterThanOrEqualTo(0));
      expect(rtt, lessThan(HealthService.probeTimeout.inMilliseconds));
    });

    test('endpoint parsing handles IPv4 and garbage', () {
      final health = HealthService();
      expect(health.debugParseEndpoint('162.159.192.1:2408'),
          ('162.159.192.1', 2408));
      expect(health.debugParseEndpoint('not-an-endpoint'), null);
      expect(health.debugParseEndpoint(null), null);
    });
  });

  group('Tier-3 stability gate', () {
    test('a probe with an exit fetch but no DNS answer passes only '
        'when DNS is not required', () {
      const probes = [(dnsOk: false, exitIp: '1.2.3.4')];
      expect(
        stabilityGatePassed(
          probes: probes,
          verifiedExitIp: '1.2.3.4',
          requiredProbes: 1,
          requireDns: false,
        ),
        true,
      );
      expect(
        stabilityGatePassed(
          probes: probes,
          verifiedExitIp: '1.2.3.4',
          requiredProbes: 1,
        ),
        false,
      );
    });

    test('total silence fails the lenient gate too', () {
      const probes = [(dnsOk: false, exitIp: null)];
      expect(
        stabilityGatePassed(
          probes: probes,
          verifiedExitIp: null,
          requiredProbes: 1,
          requireDns: false,
        ),
        false,
      );
    });
  });

  group('late CONNECTING events', () {
    test('a transitional event never demotes a live session', () {
      expect(shouldHonorConnectingEvent(VpnState.connected), false);
      expect(shouldHonorConnectingEvent(VpnState.reconnecting), false);
      expect(shouldHonorConnectingEvent(VpnState.disconnected), false);
      expect(shouldHonorConnectingEvent(VpnState.connecting), true);
    });
  });

  group('manual ladder bounds', () {
    test('maxTier2 caps the DNS escalation', () {
      final selected = DnsService.providers.first;
      final measured = {
        for (final p in DnsService.providers) p.id: 10,
      };
      final ladder = manualEscalationAttempts(
        selected: selected,
        measured: measured,
        maxTier2: 2,
      );
      // Selected + 2 alternatives + default-DNS Tier 3.
      expect(ladder.length, 4);
      expect(ladder.first.id, selected.id);
      expect(ladder.last.id, DnsService.defaultDns.id);
    });
  });
}
