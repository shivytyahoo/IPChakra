// v2.3.4 background sweep + Working filter tests.
//
// Shiv's asks (2026-10-11): (1) while the app is open, health
// checks must run by themselves in the background over ALL
// servers — otherwise Connect meets an unchecked pool and sits at
// "Connecting…" discovering dead servers one at a time; (2) a
// "Working" filter must collect verified servers automatically,
// country-wise, fastest first, so nobody has to hunt through
// unchecked entries.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ipchakra/core/theme.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/screens/servers_screen.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:ipchakra/services/health_sweeper.dart';
import 'package:ipchakra/services/ovpn_mirror_service.dart';
import 'package:ipchakra/services/server_database.dart';
import 'package:ipchakra/services/user_lists_service.dart';
import 'package:ipchakra/services/v2ray_service.dart';
import 'package:ipchakra/services/vpn_controller.dart';
import 'package:ipchakra/services/vpnbook_service.dart';
import 'package:ipchakra/services/vpngate_pool_service.dart';
import 'package:ipchakra/services/vpngate_service.dart';
import 'package:ipchakra/services/warp_service.dart';

VpnServer _probeServer(String id, int port) => VpnServer(
      id: id,
      name: id,
      country: 'JP',
      protocol: 'openvpn',
      source: 'vpngate-pool',
      probeHost: '127.0.0.1',
      probePort: port,
    );

Future<void> _until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  if (!condition()) fail('timed out waiting for: $what');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('HealthSweeper', () {
    test('checks the whole universe by itself, and picks up late '
        'arrivals on later passes', () async {
      final listener =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => listener.close());
      final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final closedPort = dead.port;
      await dead.close();

      final health = HealthService();
      final universe = <VpnServer>[
        _probeServer('sweep-up', listener.port),
        _probeServer('sweep-down', closedPort),
      ];
      final sweeper = HealthSweeper(
        health: health,
        collect: () => universe,
        interval: const Duration(milliseconds: 50),
      );
      addTearDown(sweeper.stop);
      sweeper.start();
      expect(sweeper.running, isTrue);

      await _until(
        () =>
            health.isWorking('sweep-up') != null &&
            health.isWorking('sweep-down') != null,
        'the first sweep to land verdicts',
      );
      expect(health.isWorking('sweep-up'), isTrue);
      expect(health.isWorking('sweep-down'), isFalse);

      // A source that loads late joins by itself on a later pass.
      universe.add(_probeServer('sweep-late', listener.port));
      await _until(
        () => health.isWorking('sweep-late') != null,
        'the late arrival to be swept',
      );
      expect(health.isWorking('sweep-late'), isTrue);

      sweeper.stop();
      expect(sweeper.running, isFalse);
    });
  });

  group('workingServers', () {
    test('keeps only verified-working servers, in input order', () {
      final health = HealthService();
      health.status['a'] = true;
      health.status['b'] = false;
      // 'c' has no verdict at all.
      VpnServer s(String id) => VpnServer(
            id: id,
            name: id,
            country: 'JP',
            protocol: 'v2ray',
            source: 'v2ray',
          );
      expect(
        workingServers([s('a'), s('b'), s('c')], health).map((e) => e.id),
        ['a'],
      );
    });
  });

  group('Working filter (Stealth tab)', () {
    testWidgets(
        'shows only working servers, grouped by country, fastest '
        'first — and fills live', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(400, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final db = ServerDatabase();
      final warp = WarpService();
      final v2ray = V2RayService();
      final health = HealthService();
      final userLists = UserListsService();
      final vpn = VpnController(warp);

      VpnServer stealth(String id, String name, String country) =>
          VpnServer(
            id: id,
            name: name,
            country: country,
            protocol: 'v2ray',
            type: 'v2ray',
            source: 'v2ray',
            shareLink:
                'ss://YWVzLTI1Ni1nY206cGFzcw==@203.0.113.9:8388#$id',
            tier: 'Shadowsocks',
          );
      v2ray.servers = [
        stealth('jp-slow', 'Tokyo Slow', 'Japan'),
        stealth('jp-fast', 'Tokyo Fast', 'Japan'),
        stealth('de-one', 'Berlin One', 'Germany'),
        stealth('fr-dead', 'Paris Dead', 'France'),
      ];
      health.status['jp-slow'] = true;
      health.latencyMs['jp-slow'] = 240;
      health.status['jp-fast'] = true;
      health.latencyMs['jp-fast'] = 40;
      health.status['de-one'] = true;
      health.latencyMs['de-one'] = 90;
      health.status['fr-dead'] = false;

      await tester.pumpWidget(MaterialApp(
        theme: ChakraTheme.dark(),
        home: Scaffold(
          body: ServersScreen(
            db: db,
            vpn: vpn,
            vpngate: VpnGateService(),
            pool: VpnGatePoolService(),
            vpnbook: VpnBookService(),
            mirror: OvpnMirrorService(),
            v2ray: v2ray,
            health: health,
            userLists: userLists,
            onGoHome: () {},
          ),
        ),
      ));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      await tester.tap(find.text('🕵️ Stealth'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.tap(find.widgetWithText(ChoiceChip, 'Working'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }

      // Country groups for working servers only: France's only
      // server is dead, so France must not appear at all.
      expect(find.text('Japan'), findsOneWidget);
      expect(find.text('Germany'), findsOneWidget);
      expect(find.text('France'), findsNothing);
      expect(find.text('2 servers'), findsOneWidget,
          reason: 'Japan keeps both working servers');
      expect(find.text('1 servers'), findsOneWidget,
          reason: 'Germany keeps its one working server');

      // Expand Japan: fastest first, dead absent.
      await tester.tap(find.text('Japan'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('Tokyo Fast'), findsOneWidget);
      expect(find.text('Tokyo Slow'), findsOneWidget);
      final fastY = tester.getTopLeft(find.text('Tokyo Fast')).dy;
      final slowY = tester.getTopLeft(find.text('Tokyo Slow')).dy;
      expect(fastY, lessThan(slowY),
          reason: 'fastest first inside the country group');
      expect(find.text('Paris Dead'), findsNothing);
    });
  });
}
