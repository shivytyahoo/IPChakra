// v2.3.4 search-presentation regression tests.
//
// Device complaint (2026-10-11): Stealth connect visibly cycled
// "connect / disconnect / connect / disconnect" and took forever.
// Cause: every combination attempt ends in an internal teardown
// (_disconnect) or a per-attempt failure (_fail), and both wrote
// straight to the public state — so a search read as endless
// flapping, and a session that WAS up could be torn down by the
// watchdog after two flaky probes. The fixes pinned here:
//
// 1. While a search runs, the public state is HELD at connecting:
//    no disconnected / disconnecting / error ever surfaces between
//    combinations; only the outcome moves it (Connected, or the
//    search's own final error).
// 2. The watchdog verdict [sessionCarriesTraffic]: a session is
//    only dead when DNS *and* the exit fetch fail together.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wireguard_flutter/wireguard_flutter_platform_interface.dart';

import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/services/dns_combo.dart';
import 'package:ipchakra/services/vpn_controller.dart';
import 'package:ipchakra/services/warp_service.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestDefaultBinaryMessenger messenger;
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

  VpnController stealthController() {
    late final VpnController vpn;
    vpn = VpnController(WarpService(), wgEngine: FakeWireGuard())
      ..debugForceAndroid = true
      ..debugStabilitySpacing = const Duration(milliseconds: 50);
    onV2rayCall = (method) {
      if (method != 'startV2Ray') return;
      Future<void>.delayed(const Duration(milliseconds: 60), () {
        vpn.debugV2rayStatus('CONNECTED');
      });
    };
    return vpn;
  }

  test(
    'a search that fails its first server never shows '
    'disconnected or error — one held Connecting until Connected',
    () async {
      SharedPreferences.setMockInitialValues(const {});
      final vpn = stealthController()
        ..debugAttemptDeadline = const Duration(seconds: 2);
      // The first server's core never comes up (its attempt fails
      // on the shortened deadline); the second one's does.
      var starts = 0;
      onV2rayCall = (method) {
        if (method != 'startV2Ray') return;
        starts++;
        if (starts < 2) return;
        Future<void>.delayed(const Duration(milliseconds: 60), () {
          vpn.debugV2rayStatus('CONNECTED');
        });
      };
      final states = <VpnState>[];
      vpn.addListener(() => states.add(vpn.state));

      await vpn
          .connectStealthAuto([
            stealthServer('bg-a', name: 'Background A'),
            stealthServer('bg-b', name: 'Background B'),
          ])
          .timeout(const Duration(seconds: 120));

      expect(vpn.state, VpnState.connected);
      expect(starts, 2,
          reason: 'the first server really did fail first');
      // Notifications before the search's first Connecting write
      // still carry the app's initial disconnected state — those
      // are not flicker. The device complaint is about what
      // happens AFTER connecting begins: from there to Connected,
      // nothing but connecting may appear.
      final fromConnecting = states.sublist(states.indexOf(VpnState.connecting));
      expect(fromConnecting, isNot(contains(VpnState.disconnected)),
          reason: 'a between-attempt teardown must stay in the '
              'background — the device complaint was exactly this '
              'state flickering through');
      expect(fromConnecting, isNot(contains(VpnState.disconnecting)));
      expect(fromConnecting, isNot(contains(VpnState.error)),
          reason: 'a per-attempt failure must not flash an error '
              'the next attempt clears');
      expect(fromConnecting.last, VpnState.connected);
    },
    timeout: const Timeout(Duration(seconds: 150)),
  );

  test(
    'a search where everything fails still ends in a real error',
    () async {
      SharedPreferences.setMockInitialValues(const {});
      final vpn = stealthController()
        ..debugAttemptDeadline = const Duration(seconds: 2);
      // No core ever comes up.
      onV2rayCall = (method) {};
      final states = <VpnState>[];
      vpn.addListener(() => states.add(vpn.state));

      await vpn
          .connectStealthAuto([stealthServer('bg-c', name: 'Background C')])
          .timeout(const Duration(seconds: 120));

      expect(vpn.state, VpnState.error,
          reason: 'the hold must never mask the final outcome');
      expect(vpn.errorMsg, contains('No working server'));
      final fromConnecting = states.sublist(states.indexOf(VpnState.connecting));
      expect(fromConnecting, isNot(contains(VpnState.disconnected)));
      expect(fromConnecting.last, VpnState.error);
    },
    timeout: const Timeout(Duration(seconds: 150)),
  );

  group('sessionCarriesTraffic (watchdog verdict)', () {
    test('either path answering means the session is alive', () {
      expect(
          sessionCarriesTraffic(dnsOk: true, exitIp: null), isTrue);
      expect(
          sessionCarriesTraffic(dnsOk: false, exitIp: '203.0.113.9'),
          isTrue);
      expect(
          sessionCarriesTraffic(dnsOk: true, exitIp: '203.0.113.9'),
          isTrue);
    });
    test('only total silence counts as failure', () {
      expect(sessionCarriesTraffic(dnsOk: false, exitIp: null), isFalse);
    });
  });
}
