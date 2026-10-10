// Tests for the v2.1.5 "DNS in use" status display (Shiv's
// request): when a DNS provider is picked in Settings and a
// Stealth server is connected, the Home status card must show the
// DNS that is actually carrying the session — not merely the one
// that was selected.
//
// The controller therefore records the effective DNS at the moment
// a connection is established:
//   * manual Stealth connect — the provider of the (server, DNS)
//     combination that passed through-tunnel verification: the
//     selected provider when it worked, the FALLBACK provider
//     when it did not;
//   * Stealth Auto — the winning combination's provider;
//   * Free (WireGuard) — the selected provider, which is written
//     into the tunnel configuration at connect time and is
//     therefore effective by construction.
// The record is session state like currentServer/currentIp: every
// teardown path (user disconnect, native stop, failure) must
// clear it, so a dead session's DNS can never be shown for a new
// one. The widget tests pin the Home card's DNS row per mode:
// Stealth/Free show "Name · primary IP", OpenVPN honestly shows
// "Server provided", and every non-connected state shows a dash.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wireguard_flutter/wireguard_flutter_platform_interface.dart';

import 'package:ipchakra/core/theme.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/screens/home_screen.dart';
import 'package:ipchakra/services/dns_service.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:ipchakra/services/server_database.dart';
import 'package:ipchakra/services/v2ray_service.dart';
import 'package:ipchakra/services/vpn_controller.dart';
import 'package:ipchakra/services/warp_service.dart';

/// A WireGuard engine that does nothing but complete — the tunnel
/// events themselves are injected through the controller's debug
/// seams, exactly as in the round-6 harness.
class FakeWireGuard extends WireGuardFlutterInterface {
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
  }) async {}

  @override
  Future<void> stopVpn() async {}

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
  id: 'warp-1',
  name: 'WARP',
  protocol: 'wireguard',
  type: 'free',
  source: 'warp',
  warp: true,
  endpoint: '162.159.192.1:2408',
);

/// Pre-registered WARP identity (the WireGuard flow then needs no
/// network) plus the given DNS selection.
Map<String, Object> prefsWithDns(String? dnsId) {
  final prefs = <String, Object>{
    'warp_priv': 'cHJpdmF0ZS1rZXktcHJpdmF0ZS1rZXktcHJpdmF0ZQ==',
    'warp_addr': '172.16.0.2/32',
    'warp_peer': 'cGVlci1wdWJsaWMta2V5LXBlZXItcHVibGljLWtleQ==',
    'warp_endpoint': '162.159.192.1:2408',
  };
  if (dnsId != null) prefs['dns_provider_id'] = dnsId;
  return prefs;
}

/// Polls until [condition] holds (the controller's flows run on
/// real timers against mocked channels, so tests wait on state,
/// never on fixed sleeps, wherever the flow allows it).
Future<void> waitUntil(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  if (!condition()) throw TestFailure('timed out waiting for: $what');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDefaultBinaryMessenger messenger;

  /// Hook fired for every V2Ray plugin method call, per test.
  void Function(String method)? onV2rayCall;

  setUp(() {
    onV2rayCall = null;
    messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('flutter_v2ray_client'),
      (call) async {
        onV2rayCall?.call(call.method);
        if (call.method == 'requestPermission') return true;
        if (call.method == 'getConnectionState') {
          return 'V2RAY_DISCONNECTED';
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('id.laskarmedia.openvpn_flutter/vpncontrol'),
      (call) async => null,
    );
  });

  /// A controller whose V2Ray core "comes up" shortly after every
  /// start, so connect flows proceed to verification.
  VpnController stealthController() {
    late final VpnController vpn;
    vpn = VpnController(WarpService(), wgEngine: FakeWireGuard())
      ..debugForceAndroid = true;
    onV2rayCall = (method) {
      if (method != 'startV2Ray') return;
      Future<void>.delayed(const Duration(milliseconds: 60), () {
        vpn.debugV2rayStatus('CONNECTED');
      });
    };
    return vpn;
  }

  test(
    'manual Stealth connect records the SELECTED provider when it '
    'is the one that verifies (Shiv\'s Control D scenario)',
    () async {
      SharedPreferences.setMockInitialValues(
          prefsWithDns('controld-ads'));
      final vpn = stealthController();
      final verifiedWith = <String>[];
      vpn.debugComboVerifier = (dns) async {
        verifiedWith.add(dns.id);
        return true;
      };
      await vpn
          .connect(stealthServer('manual-preferred'))
          .timeout(const Duration(seconds: 60));
      expect(vpn.state, VpnState.connected);
      expect(verifiedWith, ['controld-ads'],
          reason: 'the selected provider is tried (and wins) first');
      // The record carries the provider's real name and primary
      // address from the catalogue — Control D's malware resolver.
      expect(vpn.effectiveDns?.id, 'controld-ads');
      expect(vpn.effectiveDns?.name, 'Control D Malware + Ads');
      expect(vpn.effectiveDns?.primary, '76.76.2.2');
      expect(vpn.dnsFallbackNote, isNull,
          reason: 'no fallback happened, so no fallback note');
      // A user disconnect clears the record with the session.
      await vpn.disconnect();
      expect(vpn.state, VpnState.disconnected);
      expect(vpn.effectiveDns, isNull,
          reason: 'the DNS record must not survive its session');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'manual Stealth connect records the FALLBACK provider — not '
    'the selected one — when the selected DNS does not verify',
    () async {
      SharedPreferences.setMockInitialValues(
          prefsWithDns('controld-ads'));
      final vpn = stealthController();
      // Only Google answered the connect-time measurement, so it is
      // the one fallback a manual connect may try.
      vpn.debugMeasureProviders = () async => {'google': 40};
      final verifiedWith = <String>[];
      vpn.debugComboVerifier = (dns) async {
        verifiedWith.add(dns.id);
        return dns.id != 'controld-ads';
      };
      await vpn
          .connect(stealthServer('manual-fallback'))
          .timeout(const Duration(seconds: 60));
      expect(vpn.state, VpnState.connected);
      expect(verifiedWith, ['controld-ads', 'google'],
          reason: 'selected first, then the measured fallback');
      expect(vpn.effectiveDns?.id, 'google',
          reason: 'the provider that actually carried the verified '
              'connection is recorded, not the one that failed');
      expect(vpn.effectiveDns?.name, 'Google Public DNS');
      expect(vpn.effectiveDns?.primary, '8.8.8.8');
      expect(vpn.dnsFallbackNote, contains('Google Public DNS'));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'Stealth Auto records the winning combination\'s provider',
    () async {
      SharedPreferences.setMockInitialValues(prefsWithDns(null));
      final vpn = stealthController();
      // Quad9 answered fastest, Google second; the default
      // selection (Cloudflare) did not answer at all.
      vpn.debugMeasureProviders = () async => {'quad9': 30, 'google': 50};
      var verifyCalls = 0;
      vpn.debugComboVerifier = (_) async => ++verifyCalls >= 2;
      await vpn
          .connectStealthAuto(
              [stealthServer('auto-1'), stealthServer('auto-2')])
          .timeout(const Duration(seconds: 90));
      expect(vpn.state, VpnState.connected);
      // Combinations run (server, Quad9) first: auto-1 fails
      // verification, auto-2 passes — with Quad9.
      expect(vpn.currentServer?.id, 'auto-2');
      expect(vpn.effectiveDns?.id, 'quad9');
      expect(vpn.effectiveDns?.name, 'Quad9');
      expect(vpn.effectiveDns?.primary, '9.9.9.9');
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'a native stop (notification / Settings) clears the recorded '
    'DNS with the rest of the session',
    () async {
      SharedPreferences.setMockInitialValues(
          prefsWithDns('controld-ads'));
      final vpn = stealthController();
      vpn.debugComboVerifier = (_) async => true;
      await vpn
          .connect(stealthServer('native-stop'))
          .timeout(const Duration(seconds: 60));
      expect(vpn.state, VpnState.connected);
      expect(vpn.effectiveDns?.id, 'controld-ads');
      // The user stops the VPN from outside the app.
      vpn.debugNativeDisconnected('v2ray');
      await waitUntil(
          () => vpn.state == VpnState.disconnected, 'native-stop teardown');
      expect(vpn.effectiveDns, isNull);
      expect(vpn.currentServer, isNull);
      expect(vpn.errorMsg, isNull,
          reason: 'a native stop is never surfaced as an error');
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'Free (WireGuard) records the selected provider — it is '
    'written into the tunnel config — and clears it on disconnect',
    () async {
      SharedPreferences.setMockInitialValues(prefsWithDns('quad9'));
      final vpn = VpnController(WarpService(), wgEngine: FakeWireGuard())
        ..debugForceAndroid = true;
      await vpn.connect(warpServer).timeout(const Duration(seconds: 60));
      expect(vpn.state, VpnState.connected);
      expect(vpn.effectiveDns?.id, 'quad9');
      expect(vpn.effectiveDns?.name, 'Quad9');
      expect(vpn.effectiveDns?.primary, '9.9.9.9');
      await vpn.disconnect();
      expect(vpn.effectiveDns, isNull);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  group('Home status card DNS row', () {
    Widget app(Widget home) => MaterialApp(
          theme: ChakraTheme.dark(),
          home: Scaffold(body: home),
        );

    Future<void> pumpHome(
      WidgetTester tester,
      VpnController vpn, {
      required double width,
      required double height,
    }) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = Size(width, height);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(HomeScreen(
        db: ServerDatabase(),
        vpn: vpn,
        v2ray: V2RayService(),
        health: HealthService(),
      )));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }

    testWidgets(
        'connected Stealth session shows the effective DNS '
        '(phone and TV sizes)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      for (final size in [const Size(360, 640), const Size(1920, 1080)]) {
        final vpn = VpnController(WarpService());
        vpn.state = VpnState.connected;
        vpn.currentServer = stealthServer('ui-stealth');
        vpn.connectedAt = DateTime.now();
        vpn.effectiveDns = DnsService.byId('controld-ads');
        await pumpHome(tester, vpn, width: size.width, height: size.height);
        expect(tester.takeException(), isNull);
        expect(find.text('DNS'), findsOneWidget);
        expect(
          find.text('Control D Malware + Ads · 76.76.2.2'),
          findsOneWidget,
          reason: 'the row names the provider that is in use, '
              'with its primary address',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('connected OpenVPN session honestly shows '
        '"Server provided"', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final vpn = VpnController(WarpService());
      vpn.state = VpnState.connected;
      vpn.currentServer = const VpnServer(
        id: 'ovpn-1',
        name: 'Gate One',
        protocol: 'openvpn',
        source: 'vpngate',
      );
      vpn.connectedAt = DateTime.now();
      await pumpHome(tester, vpn, width: 360, height: 640);
      expect(tester.takeException(), isNull);
      expect(find.text('DNS'), findsOneWidget);
      expect(find.text('Server provided'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no DNS is claimed while disconnected',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final vpn = VpnController(WarpService());
      await pumpHome(tester, vpn, width: 360, height: 640);
      expect(tester.takeException(), isNull);
      expect(find.text('DNS'), findsOneWidget);
      expect(find.textContaining('76.76.2.2'), findsNothing);
      expect(find.text('Server provided'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
