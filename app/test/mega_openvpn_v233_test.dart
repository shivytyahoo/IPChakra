// Tests for v2.3.3 "OpenVPN Mega-Database":
//  * the VPNGate rolling-pool index parser (on a trimmed fixture of
//    the real published index) and the change-index marker logic
//    that keeps the ~7 MB download conditional;
//  * the liveness-registry parser and the overlay merge rules — a
//    registry-verified server is a hint for ordering/display only,
//    the app's own health verdict always wins;
//  * cross-source deduplication of the whole OpenVPN database by
//    endpoint identity (host:port + protocol);
//  * VPNBook's four protocol variants per host;
//  * per-source failure isolation (a dead network never wipes the
//    cached pool);
//  * a widget test pumping a ~5,000-entry OpenVPN list: it must
//    build lazily, show country counts and scroll without errors.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ipchakra/core/theme.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/screens/servers_screen.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:ipchakra/services/openvpn_database.dart';
import 'package:ipchakra/services/ovpn_mirror_service.dart';
import 'package:ipchakra/services/server_database.dart';
import 'package:ipchakra/services/user_lists_service.dart';
import 'package:ipchakra/services/v2ray_service.dart';
import 'package:ipchakra/services/vpnbook_service.dart';
import 'package:ipchakra/services/vpn_controller.dart';
import 'package:ipchakra/services/vpngate_pool_service.dart';
import 'package:ipchakra/services/vpngate_service.dart';
import 'package:ipchakra/services/warp_service.dart';

String _fixture(String name) =>
    File('test/fixtures/$name').readAsStringSync();

VpnServer _srv({
  required String id,
  required String source,
  String? probeHost,
  int? probePort,
  bool probeUdp = false,
  String country = 'Japan',
  String? ovpnConfig,
}) {
  return VpnServer(
    id: id,
    name: id,
    country: country,
    protocol: 'openvpn',
    source: source,
    probeHost: probeHost,
    probePort: probePort,
    probeUdp: probeUdp,
    ovpnConfig: ovpnConfig,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VPNGate pool index parser (real trimmed fixture)', () {
    final entries = parsePoolIndex(_fixture('pool_index_trimmed.json'));

    test('every fixture entry parses', () {
      expect(entries.length, 8);
      for (final e in entries) {
        expect(e['cfg'], isNotEmpty);
        expect(e['sha'], isNotEmpty);
        expect(e['c'], isNotEmpty);
      }
    });

    test('a TCP entry carries its endpoint from the probe target', () {
      final us = entries.firstWhere((e) => e['ip'] == '67.10.84.82');
      expect(us['p'], 1543);
      expect(us['u'], 0);
      expect(us['cc'], 'US');
      expect(us['ping'], 16);
    });

    test('a UDP entry has no port in the index (resolved later)', () {
      final th = entries.firstWhere((e) => e['ip'] == '27.130.53.199');
      expect(th['u'], 1);
      expect(th['p'], isNull);
    });

    test('entries become listable pool servers', () async {
      final servers = VpnGatePoolService().debugServers(entries);
      expect(servers.length, 8);
      final us = servers.firstWhere((s) => s.probeHost == '67.10.84.82');
      expect(us.source, 'vpngate-pool');
      expect(us.protocol, 'openvpn');
      expect(us.country, 'United States');
      expect(us.flag, '🇺🇸');
      expect(us.probePort, 1543);
      expect(us.probeUdp, isFalse);
      expect(us.pingMs, 16);
      expect(us.authUsername, 'vpn');
      expect(us.authPassword, 'vpn');
      expect(us.note, contains('TCP • 1543'));
      expect(us.configLoader, isNotNull);
      final th = servers.firstWhere((s) => s.probeHost == '27.130.53.199');
      expect(th.probePort, isNull);
      expect(th.probeUdp, isTrue);
      expect(th.note, startsWith('UDP'));
    });

    test('the config loader fetches the entry\'s own config path',
        () async {
      Map<String, dynamic>? seen;
      final entry = entries.first;
      final server = poolEntryToServer(
        entry,
        configFetcher: (e) async {
          seen = e;
          return 'client\n<ca>\nx\n</ca>';
        },
      );
      final cfg = await server.configLoader!();
      expect(cfg, contains('<ca>'));
      expect(seen?['cfg'], entry['cfg']);
    });

    test('malformed bodies parse to an empty pool, never a throw', () {
      expect(parsePoolIndex('{}'), isEmpty);
      expect(parsePoolIndex('[]'), isEmpty);
      expect(parsePoolIndex('{"servers": 42}'), isEmpty);
      expect(parsePoolIndex('{"servers": [{"ip": ""}]}'), isEmpty);
    });
  });

  group('change-index logic', () {
    final marker = poolIndexMarker(_fixture('pool_change_index.json'));

    test('the marker is the published SHA-256 of pool/servers.json', () {
      expect(
        marker,
        '665377a5f5a98f3ff870c52e10ba325adb0f2bcdb31f84db0eb5cc0510ba1e5b',
      );
    });

    test('an unchanged marker means NO re-download', () {
      expect(poolIndexChanged(marker, marker), isFalse);
    });

    test('a moved marker triggers exactly one download', () {
      expect(poolIndexChanged(marker, 'deadbeef'), isTrue);
      expect(poolIndexChanged(null, marker), isTrue);
    });

    test('a failed poll never triggers a download', () {
      expect(poolIndexChanged(marker, null), isFalse);
      expect(poolIndexMarker('not json'), isNull);
      expect(poolIndexMarker('{}'), isNull);
    });
  });

  group('liveness registry parser (real trimmed fixture)', () {
    test('only handshake-verified servers contribute keys', () {
      final keys = parseMonitorAliveKeys(
        _fixture('monitor_latest_trimmed.json'),
      );
      expect(
        keys.toSet(),
        {
          '219.100.37.59:443:tcp',
          '219.100.37.23:443:tcp',
          '46.110.212.225:4822:udp',
        },
      );
    });

    test('malformed bodies parse to no keys', () {
      expect(parseMonitorAliveKeys('{}'), isEmpty);
      expect(parseMonitorAliveKeys('[]'), isEmpty);
    });
  });

  group('cross-source dedupe by endpoint identity', () {
    const cfg =
        'client\ndev tun\nproto tcp\nremote 1.2.3.4 1194\n<ca>\nx\n</ca>';

    test('the API entry wins over the pool sighting of the same relay',
        () {
      final api = _srv(
        id: 'vpngate-1.2.3.4',
        source: 'vpngate',
        probeHost: '1.2.3.4',
        probePort: 1194,
        ovpnConfig: cfg,
      );
      final pool = _srv(
        id: 'pool-1.2.3.4-1194-tcp',
        source: 'vpngate-pool',
        probeHost: '1.2.3.4',
        probePort: 1194,
      );
      final merged = mergeOpenvpnServers([
        [api],
        [pool],
      ]);
      expect(merged.length, 1);
      expect(merged.single.id, api.id);
    });

    test('same host, different port or protocol stays distinct', () {
      final a = _srv(
        id: 'pool-a',
        source: 'vpngate-pool',
        probeHost: '1.2.3.4',
        probePort: 1194,
      );
      final b = _srv(
        id: 'pool-b',
        source: 'vpngate-pool',
        probeHost: '1.2.3.4',
        probePort: 443,
      );
      final c = _srv(
        id: 'pool-c',
        source: 'vpngate-pool',
        probeHost: '1.2.3.4',
        probePort: 1194,
        probeUdp: true,
      );
      expect(mergeOpenvpnServers([
        [a, b, c],
      ]).length, 3);
      // An exact duplicate inside one source is dropped too.
      expect(mergeOpenvpnServers([
        [a, a],
      ]).length, 1);
    });

    test('a port-less pool UDP entry covers the mirror copy of its host',
        () {
      final poolUdp = _srv(
        id: 'pool-9.9.9.9-x-udp',
        source: 'vpngate-pool',
        probeHost: '9.9.9.9',
        probeUdp: true,
      );
      final mirror = _srv(
        id: 'mirror-Japan-FOV_JP_9.9.9.9_udp.ovpn',
        source: 'mirror',
      );
      final merged = mergeOpenvpnServers([
        [poolUdp],
        [mirror],
      ]);
      expect(merged.length, 1);
      expect(merged.single.id, poolUdp.id);
    });

    test('mirror entries dedupe among themselves by host + protocol',
        () {
      final m1 = _srv(
        id: 'mirror-Japan-FOV_JP_8.8.8.8_tcp.ovpn',
        source: 'mirror',
      );
      final m2 = _srv(
        id: 'mirror-Japan-IPS_JP_8.8.8.8_tcp.ovpn',
        source: 'mirror',
      );
      final m3 = _srv(
        id: 'mirror-Japan-FOV_JP_8.8.4.4_tcp.ovpn',
        source: 'mirror',
      );
      final merged = mergeOpenvpnServers([
        [m1, m2, m3],
      ]);
      expect(merged.map((s) => s.id), [m1.id, m3.id]);
    });

    test('an entry with no derivable identity is always kept', () {
      final x = _srv(id: 'custom-1', source: 'custom');
      final y = _srv(id: 'custom-2', source: 'custom');
      expect(mergeOpenvpnServers([
        [x, y],
      ]).length, 2);
    });

    test('an empty source never breaks the merge (failure isolation)',
        () {
      final a = _srv(
        id: 'pool-a',
        source: 'vpngate-pool',
        probeHost: '1.1.1.1',
        probePort: 1194,
      );
      expect(
        mergeOpenvpnServers([[], [a], [], []]).single.id,
        a.id,
      );
      expect(mergeOpenvpnServers([[], []]), isEmpty);
    });
  });

  group('overlay merge rules', () {
    VpnServer poolSrv(String ip, int port) => _srv(
          id: 'pool-$ip-$port-tcp',
          source: 'vpngate-pool',
          probeHost: ip,
          probePort: port,
        );

    test('a registry-alive endpoint marks the kept entry verified', () {
      final merged = mergeOpenvpnServers(
        [
          [poolSrv('219.100.37.59', 443), poolSrv('1.1.1.1', 1194)],
        ],
        verifiedAliveKeys: {'219.100.37.59:443:tcp'},
      );
      expect(merged[0].externalVerified, isTrue);
      expect(merged[1].externalVerified, isFalse);
    });

    test('the app\'s dead verdict beats the registry: still last', () {
      final verified = poolSrv('219.100.37.59', 443).markVerified();
      final plain = poolSrv('1.1.1.1', 1194);
      final health = HealthService();
      health.status[verified.id] = false; // the app found it dead
      final sorted = sortByHealthAndLatency([verified, plain], health);
      expect(sorted.last.id, verified.id);
    });

    test('among unchecked servers, verified ones come first', () {
      final verified = poolSrv('219.100.37.59', 443).markVerified();
      final plain = poolSrv('1.1.1.1', 1194);
      final health = HealthService();
      final sorted = sortByHealthAndLatency([plain, verified], health);
      expect(sorted.first.id, verified.id);
    });

    test('verified never outranks a working server\'s measured speed',
        () {
      final slowVerified = poolSrv('219.100.37.59', 443).markVerified();
      final fastPlain = poolSrv('1.1.1.1', 1194);
      final health = HealthService();
      health.status[slowVerified.id] = true;
      health.status[fastPlain.id] = true;
      health.latencyMs[slowVerified.id] = 900;
      health.latencyMs[fastPlain.id] = 50;
      final sorted =
          sortByHealthAndLatency([slowVerified, fastPlain], health);
      expect(sorted.first.id, fastPlain.id);
    });
  });

  group('VPNBook protocol variants', () {
    test('one host becomes four entries, TCP 443 first with its old id',
        () {
      final variants = VpnBookService().debugVariants('us16.vpnbook.com');
      expect(variants.length, 4);
      expect(variants.map((s) => s.id).toSet().length, 4);
      expect(variants.first.id, 'vpnbook-us16.vpnbook.com');
      expect(
        variants.map((s) => s.note).toList(),
        [
          'VPNBook • TCP 443',
          'VPNBook • TCP 80',
          'VPNBook • UDP 53',
          'VPNBook • UDP 25000',
        ],
      );
      expect(variants.map((s) => s.probePort).toList(), [443, 80, 53, 25000]);
      expect(
        variants.map((s) => s.probeUdp).toList(),
        [false, false, true, true],
      );
      for (final v in variants) {
        expect(v.probeHost, 'us16.vpnbook.com');
        expect(v.configLoader, isNotNull);
        expect(v.country, 'United States');
      }
    });
  });

  group('pool service failure isolation', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('a dead network with an empty cache loads nothing, no throw',
        () async {
      final svc = VpnGatePoolService();
      await svc.load();
      expect(svc.servers, isEmpty);
      expect(svc.error, isNotNull);
    });

    test('a cached pool survives a failed refresh (last-good wins)',
        () async {
      final entries = parsePoolIndex(_fixture('pool_index_trimmed.json'));
      SharedPreferences.setMockInitialValues({
        'pool_entries_v1': jsonEncode(entries),
      });
      final svc = VpnGatePoolService();
      await svc.load(forceRefresh: true);
      expect(svc.servers.length, 8);
      expect(svc.source, 'cache');
    });
  });

  group('OpenVPN list at mega-database scale (widget)', () {
    testWidgets('5,000 servers: lazy build, counts, smooth scrolling',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});

      const countries = [
        'Argentina',
        'Brazil',
        'Canada',
        'France',
        'Germany',
        'India',
        'Italy',
        'Japan',
        'Poland',
        'Spain',
      ];
      final warp = WarpService();
      final db = ServerDatabase();
      final vpngate = VpnGateService();
      final pool = VpnGatePoolService();
      final vpnbook = VpnBookService();
      final mirror = OvpnMirrorService();
      final v2ray = V2RayService();
      final health = HealthService();
      final userLists = UserListsService();
      final vpn = VpnController(warp);

      pool.servers = [
        for (var i = 0; i < 5000; i++)
          VpnServer(
            id: 'pool-10.0.${i ~/ 250}.${i % 250}-${1000 + i}-tcp',
            name: '${countries[i ~/ 500]} Server $i',
            country: countries[i ~/ 500],
            protocol: 'openvpn',
            source: 'vpngate-pool',
            probeHost: '10.0.${i ~/ 250}.${i % 250}',
            probePort: 1000 + i,
          ),
      ];
      // Pre-fill health results so the incremental checker has
      // nothing to probe in the test environment.
      for (final s in pool.servers) {
        health.status[s.id] = true;
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: ChakraTheme.dark(),
          home: Scaffold(
            body: ServersScreen(
              db: db,
              vpn: vpn,
              vpngate: vpngate,
              pool: pool,
              vpnbook: vpnbook,
              mirror: mirror,
              v2ray: v2ray,
              health: health,
              userLists: userLists,
              onGoHome: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.textContaining('OpenVPN').first);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      // The summary counts the whole merged database.
      expect(find.textContaining('5000 servers'), findsWidgets);
      expect(find.textContaining('10 countries'), findsOneWidget);
      // Collapsed groups build NO server rows (lazy by construction).
      expect(find.text('Japan Server 3500'), findsNothing);
      expect(tester.takeException(), isNull);

      // Scroll to the last country header and expand Japan on the
      // way: the list must keep building items as it scrolls.
      final listFinder = find.byType(ListView).last;
      await tester.dragUntilVisible(
        find.text('Spain'),
        listFinder,
        const Offset(0, -240),
      );
      expect(find.text('Spain'), findsOneWidget);
      expect(find.textContaining('500 servers'), findsWidgets);
      await tester.dragUntilVisible(
        find.text('Japan'),
        listFinder,
        const Offset(0, 240),
      );
      await tester.tap(find.text('Japan'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.dragUntilVisible(
        find.text('Japan Server 3500'),
        listFinder,
        const Offset(0, -240),
      );
      expect(find.text('Japan Server 3500'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  });
}
