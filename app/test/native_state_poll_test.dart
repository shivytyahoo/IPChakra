// Regression tests for the on-device total Stealth failure
// (2026-10-11): every server showed Working, the connect only
// cycled DNS providers, and Connected never landed.
//
// Root cause pinned by elimination: the real TunnelVerifier
// passes against a local fake tunnel (verifier_e2e_local_test),
// the config path is unchanged from v2.3.3, and the Dart state
// machinery is coherent — the one unproven link was the tunnel-up
// signal itself. The attempt machinery waited ONLY for the
// plugin's status EVENT, and its settle-wait backup probe checked
// the app's own exit address — which can never change, because
// the app process is excluded from its own tunnel. When the event
// is missed or throttled on a device, every attempt therefore
// watched a live tunnel time out. The plugin already carries a
// pull-based ground truth (Patch 3, getConnectionState); these
// tests pin that the attempt machinery now polls it.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wireguard_flutter/wireguard_flutter_platform_interface.dart';

import 'package:ipchakra/models/vpn_server.dart';
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

VpnServer _stealthServer(String id) => VpnServer(
      id: id,
      name: id,
      protocol: 'v2ray',
      type: 'v2ray',
      source: 'v2ray',
      shareLink: 'ss://YWVzLTI1Ni1nY206cGFzcw==@203.0.113.9:8388#$id',
      tier: 'Shadowsocks',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The V2Ray plugin channel: permission granted, and —
    // crucially — NO status event is ever fired for a start. The
    // only way this connect can learn the tunnel is up is the
    // native ground-truth poll.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_v2ray_client'),
      (call) async {
        if (call.method == 'requestPermission') return true;
        if (call.method == 'getConnectionState') {
          return 'V2RAY_DISCONNECTED';
        }
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('id.laskarmedia.openvpn_flutter/vpncontrol'),
      (call) async => null,
    );
  });

  group('isNativeV2rayConnected (pure)', () {
    test('only the connected states count as up', () {
      expect(isNativeV2rayConnected('V2RAY_CONNECTED'), isTrue);
      expect(isNativeV2rayConnected('CONNECTED'), isTrue);
      expect(isNativeV2rayConnected('V2RAY_DISCONNECTED'), isFalse);
      expect(isNativeV2rayConnected('V2RAY_CONNECTING'), isFalse);
      expect(isNativeV2rayConnected(null), isFalse);
      expect(isNativeV2rayConnected(''), isFalse);
    });
  });

  test(
    'a stealth connect lands even when the status EVENT never '
    'arrives, because the attempt polls the native ground truth',
    () async {
      SharedPreferences.setMockInitialValues(
          {'dns_provider_id': 'controld-ads'});
      final vpn = VpnController(WarpService(), wgEngine: FakeWireGuard())
        ..debugForceAndroid = true
        ..debugStabilitySpacing = const Duration(milliseconds: 50);
      // No debugV2rayStatus call anywhere in this test: the event
      // never comes. The native side, asked directly, says the
      // core is up.
      vpn.debugNativeV2rayState = 'V2RAY_CONNECTED';
      vpn.debugMeasureProviders = () async => const {};
      vpn.debugComboVerifier = (_) async => true;
      vpn.debugVerifiedExitIp = '203.0.113.9';

      await vpn
          .connect(_stealthServer('eventless'))
          .timeout(const Duration(seconds: 60));
      expect(vpn.state, VpnState.connected,
          reason: 'the ground-truth poll must carry the attempt '
              'past tunnel-up, through verification and the gate');
      await vpn.disconnect();
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
