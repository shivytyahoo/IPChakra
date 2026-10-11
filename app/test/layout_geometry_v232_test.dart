// Regression tests for the v2.3.2 server-row layout fix.
//
// On Shiv's S25 (v2.3.1) the server name on the Free and OpenVPN tabs
// wrapped one character per line: both row widgets were Material
// ListTiles whose leading + trailing slots are sized first at full
// intrinsic width, leaving the title/subtitle text slot only ~30 dp
// at phone width once the Batch B share + favourite buttons joined
// the Connect button in the trailing slot. These tests pump the real
// Servers screen at 360 dp with fixture servers in the exact state
// from the screenshots and assert rendered geometry: the name must
// occupy a single line of a sane width and the whole row must stay
// under a sane height.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ipchakra/core/theme.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/screens/servers_screen.dart';
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
  late final vpn = VpnController(warp);
}

void _setSize(WidgetTester tester, double width, double height) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _runSeconds(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds * 2; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

Widget _app(Widget home) => MaterialApp(
      theme: ChakraTheme.dark(),
      home: Scaffold(body: home),
    );

Future<void> _pumpServers(WidgetTester tester, _Rig rig) async {
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
  await _runSeconds(tester, 2);
}

/// The rendered size of the server-name [Text] and of the row card
/// that contains it.
({Size name, Size row}) _measure(WidgetTester tester, String name) {
  final nameFinder = find.text(name);
  expect(nameFinder, findsOneWidget, reason: 'name "$name" must render');
  final rowFinder = find.ancestor(
    of: nameFinder,
    matching: find.byType(AnimatedContainer),
  );
  expect(rowFinder, findsWidgets, reason: 'row card must render');
  return (
    name: tester.getSize(nameFinder),
    row: tester.getSize(rowFinder.first),
  );
}

void _expectSingleLineRow(
  WidgetTester tester,
  String name, {
  required double maxNameHeight,
}) {
  final m = _measure(tester, name);
  expect(m.name.height, lessThan(maxNameHeight),
      reason: 'name "$name" must fit on ONE line, got height '
          '${m.name.height} (wrapped per character?)');
  expect(m.name.width, greaterThan(120),
      reason: 'name "$name" must get a large share of the row width, '
          'got ${m.name.width}');
  expect(m.row.height, lessThan(140),
      reason: 'row for "$name" must stay compact, got ${m.row.height}');
  expect(find.text('Connect'), findsWidgets,
      reason: 'the Connect control must still be on the row');
  expect(find.byIcon(Icons.star_border), findsWidgets,
      reason: 'the favourite star must still be on the row');
  expect(find.byIcon(Icons.share), findsWidgets,
      reason: 'the share button must still be on the row');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Free tab: WARP card name is one line at 360 dp',
      (tester) async {
    _setSize(tester, 360, 640);
    final rig = _Rig();
    rig.db.free = [
      const VpnServer(
        id: 'warp-1',
        name: 'WARP Free 1',
        protocol: 'wireguard',
        source: 'warp',
        warp: true,
      ),
    ];
    rig.health.status['warp-1'] = true;
    await _pumpServers(tester, rig);

    _expectSingleLineRow(tester, 'WARP Free 1', maxNameHeight: 30);
    // The subtitle must not fragment either (it wrapped word-fragment
    // by word-fragment in the same narrow column on the device).
    final sub = tester.getSize(find.text('WARP Free • WireGuard'));
    expect(sub.height, lessThan(40),
        reason: 'subtitle must fit on one line, got $sub');
    expect(sub.width, greaterThan(120),
        reason: 'subtitle must get real width, got $sub');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('OpenVPN tab: grouped row name is one line at 360 dp',
      (tester) async {
    _setSize(tester, 360, 640);
    final rig = _Rig();
    rig.vpnbook.servers = [
      const VpnServer(
        id: 'ca196',
        name: 'Canada ca196',
        country: 'Canada',
        protocol: 'openvpn',
        source: 'vpnbook',
        note: 'VPNBook • TCP 443',
      ),
    ];
    rig.health.status['ca196'] = true;
    rig.health.latencyMs['ca196'] = 371;
    await _pumpServers(tester, rig);

    await tester.tap(find.textContaining('OpenVPN').first);
    await _runSeconds(tester, 1);
    // Expand the Canada country group so the row is laid out fully.
    await tester.tap(find.text('Canada'));
    await _runSeconds(tester, 2);

    _expectSingleLineRow(tester, 'Canada ca196', maxNameHeight: 28);
    expect(find.textContaining('VPNBook • TCP 443'), findsWidgets,
        reason: 'the note line must still render');
    expect(find.textContaining('working'), findsWidgets,
        reason: 'the health badge must still render');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Stealth tab: filtered row name is one line at 360 dp',
      (tester) async {
    _setSize(tester, 360, 640);
    final rig = _Rig();
    rig.v2ray.servers = [
      const VpnServer(
        id: 'st-1',
        name: 'Germany Reality 1',
        country: 'Germany',
        protocol: 'v2ray',
        source: 'epodonios',
        tier: 'Reality',
        shareLink: 'vless://11111111-2222-3333-4444-555555555555'
            '@1.2.3.4:443?security=reality#Germany%20Reality%201',
      ),
    ];
    rig.health.status['st-1'] = true;
    rig.health.latencyMs['st-1'] = 88;
    await _pumpServers(tester, rig);

    await tester.tap(find.textContaining('Stealth').first);
    await _runSeconds(tester, 1);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Reality'));
    await _runSeconds(tester, 2);

    _expectSingleLineRow(tester, 'Germany Reality 1', maxNameHeight: 28);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Free tab: a very long name ellipsizes on one line',
      (tester) async {
    _setSize(tester, 360, 640);
    final rig = _Rig();
    const longName =
        'United States of America — New York City Premium Server 42';
    rig.db.free = [
      const VpnServer(
        id: 'warp-long',
        name: longName,
        protocol: 'wireguard',
        source: 'warp',
        warp: true,
      ),
    ];
    rig.health.status['warp-long'] = true;
    await _pumpServers(tester, rig);

    final m = _measure(tester, longName);
    expect(m.name.height, lessThan(30),
        reason: 'even a long name must stay on one line (ellipsis), '
            'got ${m.name.height}');
    expect(m.row.height, lessThan(140),
        reason: 'row must stay compact for long names, got ${m.row.height}');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
