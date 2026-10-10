// Tests for v2.2.0 "Stealth Resilience" (Shiv's detailed spec):
//
// R1 — a manual Stealth connect keeps the user's server fixed and
// escalates only the DNS: Tier 1 the selected provider, Tier 2 the
// other answering providers in measured speed order, Tier 3 the
// built-in default DNS treatment (no custom DNS object). Stealth
// Auto gains the same Tier-3 attempt before total failure.
// R2 — no fake "Connected": after through-tunnel verification, a
// stability gate (two further spaced probes, exit address stable)
// must pass before the state may flip to Connected.
// R3 — a connected session that dies silently (the native layer
// never reported a stop) is healed on the same server by the
// watchdog + ladder, under a distinct "reconnecting" presentation.
// A DISCONNECTED engine event stays a user/native stop: full
// teardown, never a heal. A user disconnect cancels anything.
// R4 — every step is narrated in the attempt log, in order, and
// the success line precedes the Connected flip.
//
// The harness mirrors round6/v215: mocked plugin channels, a fake
// WireGuard engine, the V2Ray core "coming up" 60 ms after every
// start, and the controller's debug seams for verification,
// stability and watchdog probes.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wireguard_flutter/wireguard_flutter_platform_interface.dart';

import 'package:ipchakra/core/theme.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/screens/home_screen.dart';
import 'package:ipchakra/screens/settings_screen.dart';
import 'package:ipchakra/services/dns_combo.dart';
import 'package:ipchakra/services/dns_service.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:ipchakra/services/server_database.dart';
import 'package:ipchakra/services/v2ray_service.dart';
import 'package:ipchakra/services/vpn_controller.dart';
import 'package:ipchakra/services/warp_service.dart';

/// A WireGuard engine that does nothing but complete — the tunnel
/// events are injected through the controller's debug seams.
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

VpnServer stealthServer(String id, {String? name}) => VpnServer(
      id: id,
      name: name ?? id,
      protocol: 'v2ray',
      type: 'v2ray',
      source: 'v2ray',
      shareLink: 'ss://YWVzLTI1Ni1nY206cGFzcw==@203.0.113.9:8388#$id',
      tier: 'Shadowsocks',
    );

/// Polls until [condition] holds; the flows run on real timers
/// against mocked channels, so tests wait on state, not sleeps.
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
  /// start, with the stability spacing shrunk so gates run fast.
  VpnController stealthController({void Function()? onStart}) {
    late final VpnController vpn;
    vpn = VpnController(WarpService(), wgEngine: FakeWireGuard())
      ..debugForceAndroid = true
      ..debugStabilitySpacing = const Duration(milliseconds: 50);
    onV2rayCall = (method) {
      if (method != 'startV2Ray') return;
      onStart?.call();
      Future<void>.delayed(const Duration(milliseconds: 60), () {
        vpn.debugV2rayStatus('CONNECTED');
      });
    };
    return vpn;
  }

  group('manualEscalationAttempts (R1 tiers, pure)', () {
    final selected = DnsService.byId('controld-ads');

    test('selected first, other answering providers by speed, '
        'default last', () {
      final attempts = manualEscalationAttempts(
        selected: selected,
        measured: {'google': 50, 'quad9': 30, 'cloudflare': 80},
      );
      expect(
        attempts.map((p) => p.id),
        ['controld-ads', 'quad9', 'google', 'cloudflare', 'dns-default'],
      );
    });

    test('Tier 2 is capped, and the selected provider is never '
        'repeated', () {
      final attempts = manualEscalationAttempts(
        selected: selected,
        measured: {
          'controld-ads': 10,
          'google': 20,
          'quad9': 30,
          'cloudflare': 40,
          'adguard': 50,
          'opendns': 60,
          'verisign': 70,
          'comodo': 80,
        },
        maxTier2: 3,
      );
      expect(attempts.map((p) => p.id),
          ['controld-ads', 'google', 'quad9', 'cloudflare', 'dns-default']);
    });

    test('when nothing answered the measurement, Tier 2 is empty '
        'and the default follows the selected directly', () {
      final attempts = manualEscalationAttempts(
        selected: selected,
        measured: const {},
      );
      expect(attempts.map((p) => p.id), ['controld-ads', 'dns-default']);
    });
  });

  group('stabilityGatePassed (R2 verdict, pure)', () {
    test('all probes answering with the verified exit passes', () {
      expect(
        stabilityGatePassed(
          probes: [
            (dnsOk: true, exitIp: '203.0.113.9'),
            (dnsOk: true, exitIp: '203.0.113.9'),
          ],
          verifiedExitIp: '203.0.113.9',
          requiredProbes: 2,
        ),
        isTrue,
      );
    });

    test('too few probes fails', () {
      expect(
        stabilityGatePassed(
          probes: [(dnsOk: true, exitIp: '203.0.113.9')],
          verifiedExitIp: '203.0.113.9',
          requiredProbes: 2,
        ),
        isFalse,
      );
    });

    test('a probe without a DNS answer fails', () {
      expect(
        stabilityGatePassed(
          probes: [
            (dnsOk: true, exitIp: '203.0.113.9'),
            (dnsOk: false, exitIp: null),
          ],
          verifiedExitIp: '203.0.113.9',
          requiredProbes: 2,
        ),
        isFalse,
      );
    });

    test('an exit address that moved during the gate fails', () {
      expect(
        stabilityGatePassed(
          probes: [
            (dnsOk: true, exitIp: '203.0.113.9'),
            (dnsOk: true, exitIp: '198.51.100.7'),
          ],
          verifiedExitIp: '203.0.113.9',
          requiredProbes: 2,
        ),
        isFalse,
      );
    });

    test('with no verified exit known, DNS answers alone decide', () {
      expect(
        stabilityGatePassed(
          probes: [
            (dnsOk: true, exitIp: '203.0.113.9'),
            (dnsOk: true, exitIp: '198.51.100.7'),
          ],
          verifiedExitIp: null,
          requiredProbes: 2,
        ),
        isTrue,
      );
    });
  });

  group('DnsService.defaultDnsConfig (Tier-3 config, pure)', () {
    test('removes the dns object and the app 853 rule, keeps the '
        'rest', () {
      final treated = DnsService.applyStealthDns(
        '{"inbounds":[],"outbounds":[{"tag":"proxy"}],'
        '"routing":{"domainStrategy":"UseIp","rules":['
        '{"type":"field","port":"80","outboundTag":"direct"}]}}',
        ['9.9.9.9'],
      );
      expect(treated.contains('"dns"'), isTrue); // sanity: applied
      final stripped = DnsService.defaultDnsConfig(treated);
      expect(stripped.contains('"dns"'), isFalse);
      expect(stripped.contains('"853"'), isFalse,
          reason: 'the app-added port-853 rule goes with the object');
      expect(stripped.contains('"port":"80"'), isTrue,
          reason: 'unrelated routing rules survive');
      expect(stripped.contains('"proxy"'), isTrue);
    });

    test('malformed input is returned unchanged', () {
      expect(DnsService.defaultDnsConfig('not json'), 'not json');
      expect(DnsService.defaultDnsConfig('[1,2]'), '[1,2]');
    });
  });

  test('isNativeStopEvent treats reconnecting as a native stop '
      '(a heal never resurrects a user stop)', () {
    expect(
      isNativeStopEvent(state: VpnState.reconnecting, searchRunning: false),
      isTrue,
    );
    expect(
      isNativeStopEvent(state: VpnState.reconnecting, searchRunning: true),
      isTrue,
    );
  });

  test(
    'R1+R4: a manual connect escalates selected → measured others '
    '→ (default not needed) with the server fixed, narrating each '
    'step in order',
    () async {
      SharedPreferences.setMockInitialValues(
          {'dns_provider_id': 'controld-ads'});
      var starts = 0;
      final vpn = stealthController(onStart: () => starts++);
      vpn.debugMeasureProviders =
          () async => {'quad9': 30, 'google': 50, 'cloudflare': 80};
      final verifiedWith = <String>[];
      vpn.debugComboVerifier = (dns) async {
        verifiedWith.add(dns.id);
        return dns.id == 'google';
      };
      final server = stealthServer('us-1', name: 'New York');
      await vpn.connect(server).timeout(const Duration(seconds: 90));
      expect(vpn.state, VpnState.connected);
      expect(vpn.currentServer?.id, 'us-1',
          reason: 'the picked server never changes during escalation');
      expect(starts, 3, reason: 'one engine start per DNS attempt');
      expect(verifiedWith, ['controld-ads', 'quad9', 'google'],
          reason: 'Tier 1 selected, then Tier 2 in measured speed order');
      expect(vpn.effectiveDns?.id, 'google');
      // The log narrates the whole sequence, in order.
      final log = vpn.attemptLog;
      int at(String line) => log.indexOf(line);
      expect(at('Trying New York with Control D Malware + Ads…'), 0);
      expect(at('Control D Malware + Ads did not answer through the tunnel.'),
          greaterThan(at('Trying New York with Control D Malware + Ads…')));
      expect(at('Trying New York with Quad9…'),
          greaterThan(at('Control D Malware + Ads did not answer through the tunnel.')));
      expect(at('Quad9 did not answer through the tunnel.'),
          greaterThan(at('Trying New York with Quad9…')));
      expect(at('Trying New York with Google Public DNS…'),
          greaterThan(at('Quad9 did not answer through the tunnel.')));
      expect(at('Tunnel verified with Google Public DNS. Checking stability…'),
          greaterThan(at('Trying New York with Google Public DNS…')));
      expect(log.last, 'Connection stable — connected with Google Public DNS.',
          reason: 'the success line is the last narration before '
              'the Connected state it announces');
      await vpn.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'R1 Tier 3: when no named DNS verifies, the same server '
    'connects with the default DNS treatment',
    () async {
      SharedPreferences.setMockInitialValues(
          {'dns_provider_id': 'controld-ads'});
      final vpn = stealthController();
      vpn.debugMeasureProviders = () async => {'quad9': 30};
      final verifiedWith = <String>[];
      vpn.debugComboVerifier = (dns) async {
        verifiedWith.add(dns.id);
        return DnsService.isDefaultDns(dns);
      };
      await vpn
          .connect(stealthServer('us-2', name: 'Chicago'))
          .timeout(const Duration(seconds: 90));
      expect(vpn.state, VpnState.connected);
      expect(verifiedWith, ['controld-ads', 'quad9', 'dns-default']);
      expect(vpn.effectiveDns?.id, 'dns-default');
      expect(vpn.attemptLog,
          contains('Trying Chicago with the default DNS…'));
      expect(vpn.attemptLog.last,
          'Connection stable — connected with the default DNS.');
      expect(vpn.dnsFallbackNote, contains('default DNS'));
      await vpn.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'R2: verification alone never shows Connected — a combination '
    'that fails the stability gate is torn down and the state '
    'never passes through Connected',
    () async {
      SharedPreferences.setMockInitialValues(
          {'dns_provider_id': 'controld-ads'});
      final vpn = stealthController();
      vpn.debugMeasureProviders = () async => const {};
      // Every combination VERIFIES, but the tunnel's exit address
      // moves during the gate — the classic "Connected, then dead
      // by the time a site opens" shape.
      vpn.debugComboVerifier = (_) async => true;
      vpn.debugVerifiedExitIp = '203.0.113.9';
      vpn.debugStabilityProbe =
          (dns) async => (dnsOk: true, exitIp: '198.51.100.7');
      final states = <VpnState>[];
      vpn.addListener(() => states.add(vpn.state));
      await vpn
          .connect(stealthServer('flappy', name: 'Flappy'))
          .timeout(const Duration(seconds: 90));
      expect(vpn.state, VpnState.error,
          reason: 'all attempts failed the stability gate, so the '
              'connect ends in an honest error');
      expect(states, isNot(contains(VpnState.connected)),
          reason: 'the state must never have claimed Connected');
      expect(vpn.attemptLog,
          contains('The tunnel with Control D Malware + Ads did not stay stable.'));
      expect(vpn.attemptLog,
          contains('The tunnel with the default DNS did not stay stable.'));
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'R2→R1: a stability failure on the selected DNS escalates to '
    'the next DNS, which connects',
    () async {
      SharedPreferences.setMockInitialValues(
          {'dns_provider_id': 'controld-ads'});
      final vpn = stealthController();
      vpn.debugMeasureProviders = () async => {'google': 40};
      vpn.debugComboVerifier = (_) async => true;
      vpn.debugVerifiedExitIp = '203.0.113.9';
      vpn.debugStabilityProbe = (dns) async => dns.id == 'google'
          ? (dnsOk: true, exitIp: '203.0.113.9')
          : (dnsOk: true, exitIp: '198.51.100.7');
      await vpn
          .connect(stealthServer('us-3', name: 'Dallas'))
          .timeout(const Duration(seconds: 90));
      expect(vpn.state, VpnState.connected);
      expect(vpn.effectiveDns?.id, 'google');
      expect(vpn.attemptLog.first, 'Trying Dallas with Control D Malware + Ads…');
      expect(vpn.attemptLog,
          contains('The tunnel with Control D Malware + Ads did not stay stable.'));
      expect(vpn.attemptLog.last,
          'Connection stable — connected with Google Public DNS.');
      await vpn.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'R3: two failed watchdog probes heal the session on the same '
    'server, starting from the last working DNS, and the DNS '
    'record follows the heal winner',
    () async {
      SharedPreferences.setMockInitialValues(
          {'dns_provider_id': 'controld-ads'});
      final vpn = stealthController();
      vpn.debugMeasureProviders = () async => {'google': 40};
      var verifyCalls = 0;
      vpn.debugComboVerifier = (dns) async {
        verifyCalls++;
        // Call 1: the initial connect (Control D wins). During the
        // heal, Control D fails and Google carries the session.
        if (verifyCalls == 1) return dns.id == 'controld-ads';
        return dns.id == 'google';
      };
      final server = stealthServer('heal-1', name: 'Heal Server');
      await vpn.connect(server).timeout(const Duration(seconds: 90));
      expect(vpn.state, VpnState.connected);
      expect(vpn.effectiveDns?.id, 'controld-ads');
      expect(vpn.debugWatchdogRunning, isTrue,
          reason: 'the watchdog arms when the session is confirmed');
      final connectedAt = vpn.connectedAt;

      // Healthy probes change nothing.
      vpn.debugWatchdogProbe = () async => true;
      await vpn.debugWatchdogTick();
      expect(vpn.state, VpnState.connected);

      // The tunnel dies silently (network switch): probes fail.
      vpn.debugWatchdogProbe = () async => false;
      final states = <VpnState>[];
      vpn.addListener(() => states.add(vpn.state));
      await vpn.debugWatchdogTick();
      expect(vpn.state, VpnState.connected,
          reason: 'one failed probe is not yet death');
      await vpn.debugWatchdogTick();
      // The second consecutive failure starts the heal.
      await waitUntil(
        () => vpn.state == VpnState.connected && !vpn.debugHealing,
        'heal to complete',
      );
      expect(states, contains(VpnState.reconnecting),
          reason: 'the heal presents as reconnecting — neither '
              'Connected nor plain Disconnected');
      expect(vpn.currentServer?.id, 'heal-1',
          reason: 'the heal keeps the same server');
      expect(vpn.effectiveDns?.id, 'google',
          reason: 'the DNS record follows the heal winner');
      expect(vpn.connectedAt, connectedAt,
          reason: 'a healed session is the same session — its '
              'start time does not reset');
      expect(vpn.attemptLog,
          contains('Connection lost. Reconnecting to Heal Server…'));
      expect(vpn.attemptLog.last, 'Reconnected with Google Public DNS.');
      expect(vpn.debugWatchdogRunning, isTrue,
          reason: 'the watchdog re-arms for the healed session');
      await vpn.disconnect();
      expect(vpn.debugWatchdogRunning, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'R3: a user disconnect mid-heal cancels everything — nothing '
    'reconnects afterwards',
    () async {
      SharedPreferences.setMockInitialValues(
          {'dns_provider_id': 'controld-ads'});
      var starts = 0;
      final vpn = stealthController(onStart: () => starts++);
      // A slow measurement keeps the heal in its early phase long
      // enough to disconnect inside it.
      var slowMeasure = false;
      vpn.debugMeasureProviders = () async {
        if (slowMeasure) {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        return {'google': 40};
      };
      vpn.debugComboVerifier = (_) async => true;
      await vpn
          .connect(stealthServer('heal-2', name: 'Cancel Heal'))
          .timeout(const Duration(seconds: 90));
      expect(vpn.state, VpnState.connected);

      slowMeasure = true;
      vpn.debugWatchdogProbe = () async => false;
      await vpn.debugWatchdogTick();
      await vpn.debugWatchdogTick();
      await waitUntil(() => vpn.debugHealing, 'heal to start');
      expect(vpn.state, VpnState.reconnecting);
      final startsAtDisconnect = starts;
      await vpn.disconnect();
      expect(vpn.state, VpnState.disconnected);
      expect(vpn.attemptLog, isEmpty,
          reason: 'a user disconnect clears the attempt log');
      // Give the aborted heal every chance to misbehave.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(vpn.state, VpnState.disconnected);
      expect(starts, startsAtDisconnect,
          reason: 'no engine start may follow the disconnect');
      expect(vpn.debugHealing, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'R3 invariant (rounds 4–6 pin): an engine DISCONNECTED while '
    'connected is a native stop — full teardown, NO heal, even '
    'with the watchdog primed to fail',
    () async {
      SharedPreferences.setMockInitialValues(
          {'dns_provider_id': 'controld-ads'});
      final vpn = stealthController();
      vpn.debugMeasureProviders = () async => const {};
      vpn.debugComboVerifier = (_) async => true;
      await vpn
          .connect(stealthServer('stop-1', name: 'Stop Server'))
          .timeout(const Duration(seconds: 90));
      expect(vpn.state, VpnState.connected);
      expect(vpn.debugWatchdogRunning, isTrue);

      // Even with probes that would fail, a reported stop is a
      // stop: the notification path must keep working exactly as
      // before, and no heal may resurrect the session.
      vpn.debugWatchdogProbe = () async => false;
      final states = <VpnState>[];
      vpn.addListener(() => states.add(vpn.state));
      vpn.debugNativeDisconnected('v2ray');
      await waitUntil(
          () => vpn.state == VpnState.disconnected, 'native-stop teardown');
      expect(vpn.currentServer, isNull);
      expect(vpn.effectiveDns, isNull);
      expect(vpn.errorMsg, isNull,
          reason: 'a native stop is never surfaced as an error');
      expect(states, isNot(contains(VpnState.reconnecting)),
          reason: 'a native stop must never enter the heal path');
      expect(vpn.debugHealing, isFalse);
      expect(vpn.debugWatchdogRunning, isFalse);
      // The watchdog is dead with the session: a manual tick now
      // must not start anything either.
      await vpn.debugWatchdogTick();
      expect(vpn.state, VpnState.disconnected);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    'R1 for Auto: after every normal combination fails, one '
    'Tier-3 default-DNS attempt on the best candidate runs before '
    'total failure',
    () async {
      SharedPreferences.setMockInitialValues(const {});
      final vpn = stealthController();
      vpn.debugMeasureProviders = () async => {'quad9': 30};
      final verifiedPairs = <String>[];
      vpn.debugComboVerifier = (dns) async {
        verifiedPairs.add(dns.id);
        return DnsService.isDefaultDns(dns);
      };
      final s1 = stealthServer('auto-a', name: 'Auto A');
      final s2 = stealthServer('auto-b', name: 'Auto B');
      await vpn
          .connectStealthAuto([s1, s2])
          .timeout(const Duration(seconds: 120));
      expect(vpn.state, VpnState.connected);
      expect(verifiedPairs, ['quad9', 'quad9', 'dns-default'],
          reason: 'both normal combinations, then the default');
      expect(vpn.currentServer?.id, 'auto-a',
          reason: 'Tier 3 runs on the best candidate');
      expect(vpn.effectiveDns?.id, 'dns-default');
      expect(vpn.attemptLog,
          contains('Trying Auto A with the default DNS…'));
      expect(vpn.attemptLog.last,
          'Connection stable — connected with the default DNS.');
    },
    timeout: const Timeout(Duration(seconds: 150)),
  );

  group('Home attempt log + reconnecting presentation (R3/R4 UI)',
      () {
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

    testWidgets('the last log lines render under the connect area '
        '(phone and TV)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      for (final size in [const Size(360, 640), const Size(1920, 1080)]) {
        final vpn = VpnController(WarpService());
        vpn.state = VpnState.connecting;
        vpn.debugAddLogLine('Trying Berlin with Quad9…');
        vpn.debugAddLogLine('Quad9 did not answer through the tunnel.');
        vpn.debugAddLogLine('Trying Berlin with Google Public DNS…');
        await pumpHome(tester, vpn, width: size.width, height: size.height);
        expect(tester.takeException(), isNull);
        expect(find.text('Trying Berlin with Quad9…'), findsOneWidget);
        expect(find.text('Quad9 did not answer through the tunnel.'),
            findsOneWidget);
        expect(find.text('Trying Berlin with Google Public DNS…'),
            findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('reconnecting is its own presentation — not '
        'Connected, not Disconnected', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final vpn = VpnController(WarpService());
      vpn.state = VpnState.reconnecting;
      vpn.currentServer = stealthServer('heal-ui', name: 'Heal UI');
      await pumpHome(tester, vpn, width: 360, height: 640);
      expect(tester.takeException(), isNull);
      expect(find.text('Reconnecting…'), findsWidgets);
      expect(find.text('Connected'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('Settings carries the honest leak-protection note '
      'and the system VPN settings button (R5)', (tester) async {
    // Scrolling this screen builds the DNS section's radio tiles,
    // which trip a long-standing DEBUG-ONLY ListTile assertion
    // ("background color or ink splashes may be invisible" —
    // glass sections have no Material ancestor) that predates
    // this release and is stripped from release builds. It is not
    // what this test pins, so those reports are filtered out and
    // every other framework error still fails the test.
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('ListTile background color')) {
        return;
      }
      previousOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousOnError);
    SharedPreferences.setMockInitialValues({});
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1920, 1080);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      theme: ChakraTheme.dark(),
      home: Scaffold(
        body: SettingsScreen(db: ServerDatabase(), vpn: VpnController(WarpService())),
      ),
    ));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(tester.takeException(), isNull);
    final note = find.textContaining('Block connections without VPN');
    await tester.scrollUntilVisible(note, 200);
    expect(note, findsWidgets);
    expect(
      find.textContaining('IPChakra itself does not block your traffic'),
      findsOneWidget,
      reason: 'the note must not claim the app itself blocks '
          'traffic when the tunnel is down',
    );
    final button = find.text('Open system VPN settings');
    await tester.scrollUntilVisible(button, 200);
    expect(button, findsOneWidget);
  });
}
