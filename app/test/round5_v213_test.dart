// Tests for the v2.1.3 round-5 fixes (Shiv's S25 on v2.1.2):
// A. A Stealth tunnel stopped from the VPN notification died, but
//    the app kept showing "Connected" — the stop event never
//    landed. The start/resume ground-truth reconciliation
//    (reconcileAction + VpnController.reconcileNativeState) is the
//    guarantee that the UI can never claim Connected over a dead
//    tunnel, whichever event got lost.
// B. Free (WireGuard) mode had no notification at all — fixed in
//    the vendored plugin (see packages/wireguard_flutter/PATCHES.md);
//    nothing app-side to test here beyond the reconcile behaviour
//    for the WireGuard engine below.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/services/vpn_controller.dart';
import 'package:ipchakra/services/warp_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('reconcileAction (ground-truth reconciliation decision)', () {
    test('connected app + native down tears down', () {
      expect(
        reconcileAction(
          appState: VpnState.connected,
          native: NativeTunnelStatus.down,
          searchRunning: false,
          connectingFor: Duration.zero,
        ),
        ReconcileAction.teardownToDisconnected,
      );
    });

    test('connected app + native up or unknown never tears down', () {
      for (final native in [NativeTunnelStatus.up, NativeTunnelStatus.unknown]) {
        expect(
          reconcileAction(
            appState: VpnState.connected,
            native: native,
            searchRunning: false,
            connectingFor: Duration.zero,
          ),
          ReconcileAction.none,
          reason: 'native=$native must not kill a live session',
        );
      }
    });

    test('a connecting attempt is left alone while it is fresh', () {
      // Early in an attempt the engine legitimately reads "down"
      // (not yet up); the attempt's own watchdog owns the outcome.
      expect(
        reconcileAction(
          appState: VpnState.connecting,
          native: NativeTunnelStatus.down,
          searchRunning: false,
          connectingFor: const Duration(seconds: 10),
        ),
        ReconcileAction.none,
      );
    });

    test('a stale connecting attempt past the settle window is torn down', () {
      expect(
        reconcileAction(
          appState: VpnState.connecting,
          native: NativeTunnelStatus.down,
          searchRunning: false,
          connectingFor: const Duration(seconds: 60),
        ),
        ReconcileAction.teardownToDisconnected,
      );
    });

    test('a running search is never reconciled mid-flight', () {
      // Between combinations the engine is down by design; the
      // search loop owns the state machine.
      expect(
        reconcileAction(
          appState: VpnState.connecting,
          native: NativeTunnelStatus.down,
          searchRunning: true,
          connectingFor: const Duration(minutes: 5),
        ),
        ReconcileAction.none,
      );
      // Even a settled "connected" claim during a search belongs
      // to the search's own verification flow.
      expect(
        reconcileAction(
          appState: VpnState.connected,
          native: NativeTunnelStatus.down,
          searchRunning: true,
          connectingFor: Duration.zero,
        ),
        ReconcileAction.teardownToDisconnected,
      );
    });

    test('states that claim no tunnel are never reconciled', () {
      for (final state in [
        VpnState.disconnected,
        VpnState.disconnecting,
        VpnState.error,
      ]) {
        expect(
          reconcileAction(
            appState: state,
            native: NativeTunnelStatus.down,
            searchRunning: false,
            connectingFor: const Duration(minutes: 5),
          ),
          ReconcileAction.none,
          reason: 'state=$state claims nothing, nothing to reconcile',
        );
      }
    });
  });

  group('VpnController.reconcileNativeState', () {
    late TestDefaultBinaryMessenger messenger;
    String v2rayNativeState = 'V2RAY_DISCONNECTED';

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      v2rayNativeState = 'V2RAY_DISCONNECTED';
      messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      // The V2Ray plugin channel answers the ground-truth query
      // with the scenario's native state; every other call (the
      // teardown stops all engines) just completes.
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_v2ray_client'),
        (call) async {
          if (call.method == 'getConnectionState') return v2rayNativeState;
          return null;
        },
      );
      for (final name in [
        'id.laskarmedia.openvpn_flutter/vpncontrol',
        'billion.group.wireguard_flutter/wgcontrol',
      ]) {
        messenger.setMockMethodCallHandler(
          MethodChannel(name),
          (call) async => null,
        );
      }
    });

    VpnController connectedStealth() {
      final vpn = VpnController(WarpService());
      vpn.debugSetActiveEngine('v2ray');
      vpn.currentServer = VpnServer(
        id: 'srv-1',
        name: 'EPODONIOS',
        protocol: 'v2ray',
        type: 'v2ray',
        source: 'feed',
        shareLink: 'vless://example',
      );
      vpn.currentIp = '152.56.140.205';
      vpn.state = VpnState.connected;
      return vpn;
    }

    test(
      'native down under a Connected claim tears the session down '
      '(the v2.1.2 notification-stop screenshot)',
      () async {
        final vpn = connectedStealth();
        v2rayNativeState = 'V2RAY_DISCONNECTED';
        await vpn.reconcileNativeState();
        expect(vpn.state, VpnState.disconnected);
        expect(vpn.currentServer, isNull);
        expect(vpn.currentIp, isNull);
        expect(vpn.errorMsg, isNull,
            reason: 'a native stop is never surfaced as an error');
      },
    );

    test('native up leaves a Connected session untouched', () async {
      final vpn = connectedStealth();
      v2rayNativeState = 'V2RAY_CONNECTED';
      await vpn.reconcileNativeState();
      expect(vpn.state, VpnState.connected);
      expect(vpn.currentServer, isNotNull);
      expect(vpn.currentIp, '152.56.140.205');
    });

    test('an undecidable native answer changes nothing', () async {
      final vpn = connectedStealth();
      v2rayNativeState = 'V2RAY_CONNECTING';
      await vpn.reconcileNativeState();
      expect(vpn.state, VpnState.connected);
      expect(vpn.currentServer, isNotNull);
    });

    test('a disconnected app is never reconciled into anything', () async {
      final vpn = VpnController(WarpService());
      vpn.debugSetActiveEngine('v2ray');
      v2rayNativeState = 'V2RAY_DISCONNECTED';
      await vpn.reconcileNativeState();
      expect(vpn.state, VpnState.disconnected);
    });

    test('a fresh connecting attempt survives a native-down reading',
        () async {
      final vpn = VpnController(WarpService());
      vpn.debugSetActiveEngine('v2ray');
      vpn.currentServer = VpnServer(
        id: 'srv-1',
        name: 'EPODONIOS',
        protocol: 'v2ray',
        type: 'v2ray',
        source: 'feed',
        shareLink: 'vless://example',
      );
      vpn.state = VpnState.connecting;
      v2rayNativeState = 'V2RAY_DISCONNECTED';
      await vpn.reconcileNativeState();
      expect(vpn.state, VpnState.connecting,
          reason: 'an in-flight attempt is owned by its own watchdog');
      expect(vpn.currentServer, isNotNull);
    });
  });
}
