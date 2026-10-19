// Tests for the v2.3.3 interaction fixes (both reported from the
// user's S25 testing of v2.3.2):
//
// Bug A — switching modes disconnected the VPN. Root cause:
// HomeScreen._setMode awaited vpn.disconnect() whenever a session
// was live before switching the mode, so mere navigation tore the
// tunnel down. Required behaviour: mode/tab switching is pure
// navigation; the engine handover happens only on an explicit
// Connect tap in another mode, where the connect paths (all of
// which funnel through VpnController._connectOnce) stop the old
// engine cleanly — its stop echoes consumed as self-stops — before
// starting the new one. The widget test pins the navigation rule;
// the controller tests pin the handover order (old engine's stop
// strictly before the new engine's start, landing Connected on the
// new server) for Stealth→Free, Free→Stealth and Free→OpenVPN,
// plus unchanged same-mode reconnect behaviour.
//
// Bug B — the connection notification disappeared on "clear all".
// Root cause (audit detailed in the v2.3.3 report): the V2Ray and
// OpenVPN engines already attach ongoing notifications through
// startForeground, but the WireGuard engine's notification was
// posted standalone (Patch 2 of the vendored wireguard_flutter)
// with no foreground service anywhere in its path. Patch 3 gives
// it a foreground service (WgConnectionService) that owns the
// notification. Native dismissibility cannot be exercised from
// Dart, so the Bug B tests are source guards: they fail if the
// ongoing flag, the startForeground attachment, the service's
// manifest declaration, or the Disconnect action ever regress.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wireguard_flutter/wireguard_flutter_platform_interface.dart';

import 'package:ipchakra/core/theme.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/screens/home_screen.dart';
import 'package:ipchakra/services/adshield_service.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:ipchakra/services/server_database.dart';
import 'package:ipchakra/services/v2ray_service.dart';
import 'package:ipchakra/services/vpn_controller.dart';
import 'package:ipchakra/services/warp_service.dart';

/// A WireGuard engine that completes instantly and records every
/// call into the shared [events] log, so cross-engine ordering can
/// be asserted against the other engines' channel calls.
class RecordingWireGuard extends WireGuardFlutterInterface {
  RecordingWireGuard(this.events);

  final List<String> events;
  final _stageController = StreamController<VpnStage>.broadcast();

  @override
  Stream<VpnStage> get vpnStageSnapshot => _stageController.stream;

  @override
  Future<void> initialize({required String interfaceName}) async {}

  @override
  Future<void> startVpn({
    required String serverAddress,
    required String wgQuickConfig,
    required String providerBundleIdentifier,
  }) async {
    events.add('wg:startVpn');
  }

  @override
  Future<void> stopVpn() async {
    events.add('wg:stopVpn');
  }

  @override
  Future<void> refreshStage() async {}

  @override
  Future<VpnStage> stage() async => VpnStage.disconnected;
}

VpnServer stealthServer(String id) => VpnServer(
      id: id,
      name: id,
      protocol: 'v2ray',
      type: 'v2ray',
      source: 'v2ray',
      shareLink: 'ss://YWVzLTI1Ni1nY206cGFzcw==@203.0.113.9:8388#$id',
      tier: 'Shadowsocks',
    );

const warpServer = VpnServer(
  id: 'warp-auto',
  name: 'WARP Auto',
  protocol: 'wireguard',
  type: 'free',
  source: 'warp',
  warp: true,
  endpoint: '162.159.192.1:2408',
);

/// A pre-registered WARP identity, so the WireGuard flow needs no
/// network in tests (same values the v2.1.5 harness uses).
const warpPrefs = <String, Object>{
  'warp_priv': 'cHJpdmF0ZS1rZXktcHJpdmF0ZS1rZXktcHJpdmF0ZQ==',
  'warp_addr': '172.16.0.2/32',
  'warp_peer': 'cGVlci1wdWJsaWMta2V5LXBlZXItcHVibGljLWtleQ==',
  'warp_endpoint': '162.159.192.1:2408',
};

const ovpnServer = VpnServer(
  id: 'ovpn-handover',
  name: 'Gate Handover',
  protocol: 'openvpn',
  source: 'vpngate',
  ovpnConfig: 'client\n<ca>\n-----BEGIN CERTIFICATE-----\n'
      'MIIB\n-----END CERTIFICATE-----\n</ca>\n',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> events;
  late TestDefaultBinaryMessenger messenger;

  /// The controller currently under test, so the V2Ray channel
  /// mock can report the core as up shortly after every start.
  VpnController? activeVpn;

  setUp(() {
    events = <String>[];
    activeVpn = null;
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_v2ray_client'),
      (call) async {
        events.add('v2ray:${call.method}');
        if (call.method == 'requestPermission') return true;
        if (call.method == 'getConnectionState') {
          return 'V2RAY_DISCONNECTED';
        }
        if (call.method == 'startV2Ray') {
          final vpn = activeVpn;
          if (vpn != null) {
            Future<void>.delayed(const Duration(milliseconds: 60), () {
              vpn.debugV2rayStatus('CONNECTED');
            });
          }
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('id.laskarmedia.openvpn_flutter/vpncontrol'),
      (call) async {
        events.add('ovpn:${call.method}');
        if (call.method == 'stage') return 'connected';
        return null;
      },
    );
  });

  VpnController controller() {
    final vpn = VpnController(
      WarpService(),
      wgEngine: RecordingWireGuard(events),
    )..debugForceAndroid = true;
    activeVpn = vpn;
    return vpn;
  }

  group('Bug A — mode switching is pure navigation', () {
    testWidgets(
        'tapping Free / Chakra / Stealth with a live Stealth session '
        'changes only the mode — state, server and session survive',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final vpn = VpnController(
        WarpService(),
        wgEngine: RecordingWireGuard(events),
      );
      vpn.setMode(AppMode.stealth);
      vpn.state = VpnState.connected;
      vpn.currentServer = stealthServer('ui-stealth-live');
      vpn.connectedAt = DateTime.now();

      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: ChakraTheme.dark(),
        home: Scaffold(
          body: HomeScreen(
            db: ServerDatabase(),
            vpn: vpn,
            v2ray: V2RayService(),
            health: HealthService(),
            adshield: AdShieldService(),
          ),
        ),
      ));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(tester.takeException(), isNull);
      expect(vpn.state, VpnState.connected);

      void expectSessionIntact(String step) {
        expect(vpn.state, VpnState.connected,
            reason: '$step: the live session must not be torn down');
        expect(vpn.currentServer?.id, 'ui-stealth-live',
            reason: '$step: the connected server must not change');
        expect(events.where((e) => e.endsWith('stopVpn') || e == 'v2ray:stopV2Ray'),
            isEmpty,
            reason: '$step: navigation must not stop any engine');
      }

      await tester.tap(find.text('Free').first);
      await tester.pump(const Duration(milliseconds: 400));
      expect(vpn.mode, AppMode.free);
      expectSessionIntact('Stealth -> Free tab');

      await tester.tap(find.text('Chakra').first);
      await tester.pump(const Duration(milliseconds: 400));
      expect(vpn.mode, AppMode.chakra);
      expectSessionIntact('Free -> Chakra tab');

      await tester.tap(find.text('Stealth').first);
      await tester.pump(const Duration(milliseconds: 400));
      expect(vpn.mode, AppMode.stealth);
      expectSessionIntact('Chakra -> Stealth tab');

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Bug A — cross-mode Connect performs a clean handover', () {
    test(
      'Stealth live -> Connect a Free (WARP) server: the V2Ray stop '
      'is issued before WireGuard starts, ending Connected on WARP',
      () async {
        SharedPreferences.setMockInitialValues(warpPrefs);
        final vpn = controller();
        vpn.debugComboVerifier = (_) async => true;
        await vpn
            .connect(stealthServer('handover-from'))
            .timeout(const Duration(seconds: 60));
        expect(vpn.state, VpnState.connected);
        expect(vpn.currentServer?.id, 'handover-from');

        events.clear();
        await vpn.connect(warpServer).timeout(const Duration(seconds: 60));
        expect(vpn.state, VpnState.connected);
        expect(vpn.currentServer?.id, warpServer.id,
            reason: 'the session must land on the new server');
        final stopAt = events.indexOf('v2ray:stopV2Ray');
        final startAt = events.indexOf('wg:startVpn');
        expect(stopAt, isNonNegative,
            reason: 'the old engine must be stopped, got: $events');
        expect(startAt, isNonNegative,
            reason: 'the new engine must be started, got: $events');
        expect(stopAt < startAt, isTrue,
            reason: 'stop(old) must precede start(new), got: $events');
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'Free live -> Connect a Stealth server: the WireGuard stop is '
      'issued before V2Ray starts, ending Connected on Stealth',
      () async {
        SharedPreferences.setMockInitialValues(warpPrefs);
        final vpn = controller();
        await vpn.connect(warpServer).timeout(const Duration(seconds: 60));
        expect(vpn.state, VpnState.connected);
        expect(vpn.currentServer?.id, warpServer.id);

        vpn.debugComboVerifier = (_) async => true;
        events.clear();
        await vpn
            .connect(stealthServer('handover-to'))
            .timeout(const Duration(seconds: 90));
        expect(vpn.state, VpnState.connected);
        expect(vpn.currentServer?.id, 'handover-to',
            reason: 'the session must land on the new server');
        final stopAt = events.indexOf('wg:stopVpn');
        final startAt = events.indexOf('v2ray:startV2Ray');
        expect(stopAt, isNonNegative,
            reason: 'the old engine must be stopped, got: $events');
        expect(startAt, isNonNegative,
            reason: 'the new engine must be started, got: $events');
        expect(stopAt < startAt, isTrue,
            reason: 'stop(old) must precede start(new), got: $events');
      },
      timeout: const Timeout(Duration(seconds: 150)),
    );

    test(
      'Free live -> Connect an OpenVPN server: the WireGuard stop '
      'is issued before the OpenVPN connect, ending Connected',
      () async {
        SharedPreferences.setMockInitialValues(warpPrefs);
        final vpn = controller();
        await vpn.connect(warpServer).timeout(const Duration(seconds: 60));
        expect(vpn.state, VpnState.connected);

        events.clear();
        await vpn.connect(ovpnServer).timeout(const Duration(seconds: 60));
        expect(vpn.state, VpnState.connected);
        expect(vpn.currentServer?.id, ovpnServer.id);
        final stopAt = events.indexOf('wg:stopVpn');
        final startAt = events.indexOf('ovpn:connect');
        expect(stopAt, isNonNegative,
            reason: 'the old engine must be stopped, got: $events');
        expect(startAt, isNonNegative,
            reason: 'the new engine must be started, got: $events');
        expect(stopAt < startAt, isTrue,
            reason: 'stop(old) must precede start(new), got: $events');
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'same-mode reconnect (Free -> Free) is unchanged: stop still '
      'precedes start and the new server wins',
      () async {
        SharedPreferences.setMockInitialValues(warpPrefs);
        final vpn = controller();
        await vpn.connect(warpServer).timeout(const Duration(seconds: 60));
        expect(vpn.state, VpnState.connected);

        const second = VpnServer(
          id: 'warp-second',
          name: 'WARP Second',
          protocol: 'wireguard',
          type: 'free',
          source: 'warp',
          warp: true,
          endpoint: '162.159.192.1:2408',
        );
        events.clear();
        await vpn.connect(second).timeout(const Duration(seconds: 60));
        expect(vpn.state, VpnState.connected);
        expect(vpn.currentServer?.id, second.id);
        final stopAt = events.indexOf('wg:stopVpn');
        final startAt = events.indexOf('wg:startVpn');
        expect(stopAt, isNonNegative);
        expect(startAt, isNonNegative);
        expect(stopAt < startAt, isTrue,
            reason: 'stop(old) must precede start(new), got: $events');
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });

  group('Bug B — the connected notification is the ongoing '
      'foreground-service notification (source guards)', () {
    String read(String relative) => File(relative).readAsStringSync();

    test('WireGuard: a foreground service owns the notification', () {
      final service = read('../packages/wireguard_flutter/android/src/main/'
          'kotlin/billion/group/wireguard_flutter/WgConnectionService.kt');
      expect(service, contains('startForeground('),
          reason: 'the notification must be attached via '
              'startForeground, not posted standalone');
      expect(service, contains('FOREGROUND_SERVICE_TYPE_SPECIAL_USE'));
      expect(service, contains('START_NOT_STICKY'),
          reason: 'the notification must die with the session, '
              'never be resurrected by a service restart');
    });

    test('WireGuard: notification stays ongoing, keeps its '
        'Disconnect action, and show() starts the service', () {
      final helper = read('../packages/wireguard_flutter/android/src/main/'
          'kotlin/billion/group/wireguard_flutter/WgNotification.kt');
      expect(helper, contains('.setOngoing(true)'));
      expect(helper, contains('startForegroundService'),
          reason: 'show() must start the foreground service');
      expect(helper, contains('ACTION_DISCONNECT'),
          reason: 'the Disconnect action (Patch 2) must survive');
      expect(helper, contains('stopService'),
          reason: 'cancel() must stop the foreground service');
    });

    test('WireGuard: the service is declared with its FGS type', () {
      final manifest = read('../packages/wireguard_flutter/android/src/main/'
          'AndroidManifest.xml');
      expect(manifest, contains('WgConnectionService'));
      expect(manifest, contains('android:foregroundServiceType="specialUse"'));
      expect(manifest,
          contains('android.permission.FOREGROUND_SERVICE_SPECIAL_USE'));
    });

    test('Stealth (V2Ray): notification remains ongoing + '
        'startForeground with the STOP_SERVICE Disconnect action', () {
      final manager = read('../packages/flutter_v2ray_client/android/src/'
          'main/java/dev/amirzr/flutter_v2ray_client/v2ray/core/'
          'V2rayCoreManager.java');
      expect(manager, contains('.setOngoing(true)'));
      expect(manager, contains('startForeground('));
      expect(manager, contains('STOP_SERVICE'),
          reason: 'the v2.1.2 Disconnect-action fix must survive');
    });

    test('HomeScreen mode switching contains no disconnect call', () {
      final home = read('lib/screens/home_screen.dart');
      final start = home.indexOf('void _setMode');
      expect(start, isNonNegative,
          reason: '_setMode must stay a synchronous navigation method');
      final body = home.substring(start, home.indexOf('\n  }', start));
      expect(body, isNot(contains('.disconnect(')),
          reason: 'navigation must never tear down a live tunnel '
              '(Bug A root cause)');
    });
  });
}
