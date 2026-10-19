// Widget smoke tests for the v2.0.0 redesign.
//
// Pumps the Home and Servers screens at a small phone size and at a TV
// size, in all three app modes, advancing several seconds of fake time
// so every animation (rotating ring, pulses, breathing glow, drifting
// background orbs, sliding mode indicator) runs. Any RenderFlex
// overflow, rendering exception or leaked ticker fails the test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ipchakra/core/theme.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/screens/home_screen.dart';
import 'package:ipchakra/screens/servers_screen.dart';
import 'package:ipchakra/services/adshield_service.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:ipchakra/services/ovpn_mirror_service.dart';
import 'package:ipchakra/services/server_database.dart';
import 'package:ipchakra/services/user_lists_service.dart';
import 'package:ipchakra/services/v2ray_service.dart';
import 'package:ipchakra/services/vpn_controller.dart';
import 'package:ipchakra/services/vpnbook_service.dart';
import 'package:ipchakra/services/vpngate_pool_service.dart';
import 'package:ipchakra/services/vpngate_service.dart';
import 'package:ipchakra/services/warp_service.dart';
import 'package:ipchakra/widgets/animated_background.dart';
import 'package:ipchakra/widgets/connect_button.dart';

class _Rig {
  final db = ServerDatabase();
  final warp = WarpService();
  final vpngate = VpnGateService();
  final pool = VpnGatePoolService();
  final vpnbook = VpnBookService();
  final mirror = OvpnMirrorService();
  final v2ray = V2RayService();
  final health = HealthService();
  final userLists = UserListsService();
  final adshield = AdShieldService();
  late final vpn = VpnController(warp);
}

void _setSize(WidgetTester tester, double width, double height) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Advances [seconds] of fake time in half-second steps (animations run).
Future<void> _runSeconds(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds * 2; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

/// Mirrors the real app: screens live inside a Material [Scaffold]
/// (without it, Text falls back to the 48px debug default style and
/// every measurement is meaningless).
Widget _app(Widget home) => MaterialApp(
      theme: ChakraTheme.dark(),
      home: Scaffold(body: home),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('ConnectButton pumps in every visual state (phone size)',
      (tester) async {
    _setSize(tester, 360, 640);
    for (final state in VpnStateVisual.values) {
      await tester.pumpWidget(_app(Scaffold(
        body: Center(child: ConnectButton(state: state, onTap: () {})),
      )));
      await _runSeconds(tester, 5);
      expect(tester.takeException(), isNull,
          reason: 'ConnectButton state $state must render cleanly');
    }
    // Unmount: all animation controllers must dispose without errors.
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('AnimatedBackground pumps connected and disconnected',
      (tester) async {
    _setSize(tester, 360, 640);
    for (final connected in [false, true]) {
      await tester.pumpWidget(_app(AnimatedBackground(
        connected: connected,
        child: const Scaffold(body: Center(child: Text('content'))),
      )));
      await _runSeconds(tester, 5);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home pumps in all three modes (phone size)', (tester) async {
    _setSize(tester, 360, 640);
    final rig = _Rig();
    await tester.pumpWidget(_app(HomeScreen(
      db: rig.db,
      vpn: rig.vpn,
      v2ray: rig.v2ray,
      health: rig.health,
      adshield: rig.adshield,
    )));
    await _runSeconds(tester, 5);
    expect(tester.takeException(), isNull);
    expect(find.byType(ConnectButton), findsOneWidget);

    // Switch through every mode; the sliding indicator must animate
    // without overflow or exceptions.
    for (final label in ['Stealth', 'Chakra', 'Free']) {
      await tester.tap(find.text(label).first);
      await _runSeconds(tester, 2);
      expect(tester.takeException(), isNull,
          reason: 'switching to $label mode must render cleanly');
    }
    expect(rig.vpn.mode, AppMode.free);
    // Let any snackbar finish, then unmount (tickers disposed).
    await _runSeconds(tester, 5);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home pumps in all three modes (TV size)', (tester) async {
    _setSize(tester, 1920, 1080);
    final rig = _Rig();
    await tester.pumpWidget(_app(HomeScreen(
      db: rig.db,
      vpn: rig.vpn,
      v2ray: rig.v2ray,
      health: rig.health,
      adshield: rig.adshield,
    )));
    await _runSeconds(tester, 5);
    expect(tester.takeException(), isNull);
    for (final label in ['Stealth', 'Chakra', 'Free']) {
      await tester.tap(find.text(label).first);
      await _runSeconds(tester, 2);
      expect(tester.takeException(), isNull,
          reason: 'TV size: switching to $label must render cleanly');
    }
    await _runSeconds(tester, 5);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('Home connected label names the real stealth scheme',
      (tester) async {
    _setSize(tester, 360, 640);
    final cases = <(VpnServer, String)>[
      (
        const VpnServer(
          id: 'v2ray-1',
          name: 'Reality One',
          protocol: 'v2ray',
          source: 'v2ray',
          tier: 'Reality',
          shareLink:
              'vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?security=reality&sni=www.microsoft.com#Reality%20One',
        ),
        'VLESS',
      ),
      (
        const VpnServer(
          id: 'v2ray-2',
          name: 'Trojan One',
          protocol: 'v2ray',
          source: 'v2ray',
          tier: 'TLS',
          shareLink: 'trojan://pw@5.6.7.8:443#Trojan%20One',
        ),
        'Trojan',
      ),
      (
        const VpnServer(
          id: 'v2ray-3',
          name: 'SS One',
          protocol: 'v2ray',
          source: 'v2ray',
          tier: 'Shadowsocks',
          shareLink: 'ss://YWVzLTI1Ni1nY206cGFzcw==@9.9.9.9:8388#SS%20One',
        ),
        'Shadowsocks',
      ),
      (
        const VpnServer(
          id: 'warp-1',
          name: 'WARP Free',
          protocol: 'wireguard',
          source: 'warp',
          warp: true,
        ),
        'WireGuard',
      ),
    ];
    for (final (server, expected) in cases) {
      final rig = _Rig();
      rig.vpn.state = VpnState.connected;
      rig.vpn.currentServer = server;
      rig.vpn.connectedAt = DateTime.now();
      await tester.pumpWidget(_app(HomeScreen(
        db: rig.db,
        vpn: rig.vpn,
        v2ray: rig.v2ray,
        health: rig.health,
        adshield: rig.adshield,
      )));
      await _runSeconds(tester, 2);
      expect(tester.takeException(), isNull);
      expect(find.textContaining(expected), findsWidgets,
          reason: 'protocol label must show $expected for ${server.name}');
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('Servers screen pumps and switches tabs (phone size)',
      (tester) async {
    _setSize(tester, 360, 640);
    final rig = _Rig();
    await tester.pumpWidget(_app(ServersScreen(
      db: rig.db,
      vpn: rig.vpn,
      vpngate: rig.vpngate,
      pool: rig.pool,
      vpnbook: rig.vpnbook,
      mirror: rig.mirror,
      v2ray: rig.v2ray,
      health: rig.health,
      userLists: rig.userLists,
      onGoHome: () {},
    )));
    await _runSeconds(tester, 5);
    expect(tester.takeException(), isNull);

    await tester.tap(find.textContaining('Stealth').first);
    await _runSeconds(tester, 3);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Stealth Auto'), findsWidgets);

    await tester.tap(find.textContaining('Chakra').first);
    await _runSeconds(tester, 2);
    expect(tester.takeException(), isNull);

    // Unmount, then flush the background health-check loop.
    await tester.pumpWidget(const SizedBox());
    await _runSeconds(tester, 5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Servers screen pumps (TV size)', (tester) async {
    _setSize(tester, 1920, 1080);
    final rig = _Rig();
    await tester.pumpWidget(_app(ServersScreen(
      db: rig.db,
      vpn: rig.vpn,
      vpngate: rig.vpngate,
      pool: rig.pool,
      vpnbook: rig.vpnbook,
      mirror: rig.mirror,
      v2ray: rig.v2ray,
      health: rig.health,
      userLists: rig.userLists,
      onGoHome: () {},
    )));
    await _runSeconds(tester, 5);
    expect(tester.takeException(), isNull);
    await tester.tap(find.textContaining('Stealth').first);
    await _runSeconds(tester, 3);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await _runSeconds(tester, 5);
    expect(tester.takeException(), isNull);
  });
}
