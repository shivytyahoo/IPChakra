// Tests for the v2.1.4 round-6 regression hunt (Shiv's S25 on
// v2.1.3):
//
// (1) Stealth Auto churned through all 6 (server, DNS)
//     combinations and gave up with "No working server and DNS
//     combination was found" on a network where v2.1.2 connected
//     cleanly. Root class: the DISCONNECTED events produced by the
//     controller's OWN engine stops (every combination teardown and
//     every attempt prologue stops all engines, and each stop makes
//     the engine emit a DISCONNECTED) carry no provenance. Delivered
//     late — after the next attempt has claimed the engine — such an
//     echo is indistinguishable from an external stop: routed as a
//     "native stop" it cancels the whole search; landing in the
//     connected/verify window it destroys the attempt being
//     verified; in a manual connect it is the attempt's _fail.
//     v2.1.3 moved the V2Ray plugin's DISCONNECTED broadcast to the
//     FIRST step of stopCore, removing the incidental delay that
//     used to park these echoes in the engine-unclaimed window
//     where engine scoping dropped them.
// (2) Free/WARP stopped connecting on the first tap: the same
//     unattributable 'disconnected' stage (the WireGuard plugin
//     emits one for every stopVpn, even with no tunnel running)
//     landing after the WireGuard claim fails the attempt via _fail
//     before startVpn has even run; _connectOnce's immediate
//     _markConnected is then rejected by the connected-event guard
//     because the state is already error. The next tap has no stale
//     echo pending and connects.
//
// These tests drive the REAL controller with fake engine event
// sequences (mocked plugin channels, a fake WireGuard engine —
// the plugin's desktop implementation shells out to `sudo wg`,
// which no test host has — and the debug event seams) and pin the
// required behaviour:
//   (i)   a self-stop echo delivered after the next attempt started
//         must not kill that attempt or the search;
//   (ii)  a genuinely external stop (no self-stop in flight) must
//         still cancel a search, exactly as in v2.1.1/v2.1.3;
//   (iii) a full simulated Auto run (fail, fail, success) ends
//         Connected;
//   (iv)  WARP connects on the first tap even when the prologue
//         stop's stale 'disconnected' lands inside the connect.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wireguard_flutter/wireguard_flutter_platform_interface.dart';

import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/services/vpn_controller.dart';
import 'package:ipchakra/services/warp_service.dart';

/// A WireGuard engine that does nothing but complete — the tunnel
/// events themselves are injected through the controller's debug
/// seams, in the exact order a scenario dictates.
class FakeWireGuard extends WireGuardFlutterInterface {
  final _stageController = StreamController<VpnStage>.broadcast();

  /// Fired synchronously inside [startVpn] — the moment the real
  /// engine has been claimed and the tunnel start issued.
  void Function()? onStart;
  int starts = 0;

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
    starts++;
    onStart?.call();
  }

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
    // A pre-registered WARP identity: the WireGuard flow then needs
    // no network (registration is cached in SharedPreferences).
    SharedPreferences.setMockInitialValues({
      'warp_priv': 'cHJpdmF0ZS1rZXktcHJpdmF0ZS1rZXktcHJpdmF0ZQ==',
      'warp_addr': '172.16.0.2/32',
      'warp_peer': 'cGVlci1wdWJsaWMta2V5LXBlZXItcHVibGljLWtleQ==',
      'warp_endpoint': '162.159.192.1:2408',
    });
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

  group('isSelfStopEcho (stop-echo attribution window)', () {
    final now = DateTime(2026, 10, 10, 12, 0, 0);
    test('a fresh self-stop is attributable', () {
      expect(isSelfStopEcho(issuedAt: now, now: now), isTrue);
      expect(
        isSelfStopEcho(
          issuedAt: now.subtract(const Duration(seconds: 5)),
          now: now,
        ),
        isTrue,
      );
      expect(
        isSelfStopEcho(
          issuedAt: now.subtract(selfStopEchoWindow),
          now: now,
        ),
        isTrue,
      );
    });

    test('an aged-out or absent record is not an echo', () {
      expect(
        isSelfStopEcho(
          issuedAt:
              now.subtract(selfStopEchoWindow + const Duration(seconds: 1)),
          now: now,
        ),
        isFalse,
      );
      expect(isSelfStopEcho(issuedAt: null, now: now), isFalse);
      expect(
        isSelfStopEcho(
          issuedAt: now.add(const Duration(seconds: 1)),
          now: now,
        ),
        isFalse,
        reason: 'a stop recorded "in the future" is a clock artefact',
      );
    });
  });

  test(
    '(i) a stale self-stop DISCONNECTED delivered after the next '
    'attempt started must not kill the attempt or the search',
    () async {
      final wg = FakeWireGuard();
      final vpn = VpnController(WarpService(), wgEngine: wg)
        ..debugForceAndroid = true;
      final serverA = stealthServer('seq-a');
      final serverB = stealthServer('seq-b');
      var starts = 0;
      var verifyCalls = 0;
      onV2rayCall = (method) {
        if (method != 'startV2Ray') return;
        starts++;
        if (starts == 1) {
          // Attempt A's core comes up.
          Future<void>.delayed(const Duration(milliseconds: 60), () {
            vpn.debugV2rayStatus('CONNECTED');
          });
        } else if (starts == 2) {
          // Attempt B has claimed the engine and is starting. NOW
          // the DISCONNECTED echo of the controller's own teardown
          // of attempt A is delivered — the v2.1.3 regression: it
          // must be consumed as a self-stop, never routed as an
          // external native stop (which would cancel the search).
          vpn.debugV2rayStatus('DISCONNECTED');
          Future<void>.delayed(const Duration(milliseconds: 60), () {
            vpn.debugV2rayStatus('CONNECTED');
          });
        }
      };
      vpn.debugComboVerifier = (_) async => ++verifyCalls > 1;
      await vpn
          .connectStealthAuto([serverA, serverB])
          .timeout(const Duration(seconds: 60));
      expect(starts, 2, reason: 'both combinations were attempted');
      expect(vpn.state, VpnState.connected,
          reason: 'attempt B survives the stale echo and connects');
      expect(vpn.currentServer?.id, serverB.id);
      expect(vpn.errorMsg, isNull);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    '(ii) an external stop with no self-stop in flight still '
    'cancels a running search (v2.1.1 behaviour preserved)',
    () async {
      final wg = FakeWireGuard();
      final vpn = VpnController(WarpService(), wgEngine: wg)
        ..debugForceAndroid = true;
      final serverA = stealthServer('ext-a');
      final serverB = stealthServer('ext-b');
      var starts = 0;
      onV2rayCall = (method) {
        if (method == 'startV2Ray') starts++;
      };
      final search = vpn.connectStealthAuto([serverA, serverB]);
      expect(vpn.debugAutoRunning, isTrue);
      // Arrange the in-flight attempt exactly as the search leaves
      // it (as in the v2.1.1 test): v2ray claimed, state connecting.
      // No engine stop has been issued by the controller in this
      // scenario, so the stop below can only be external.
      vpn.debugSetActiveEngine('v2ray');
      vpn.state = VpnState.connecting;
      vpn.currentServer = serverA;
      vpn.debugNativeDisconnected('v2ray');
      await search.timeout(const Duration(seconds: 30));
      // The native-stop teardown runs asynchronously behind the
      // search's return; wait for it to settle.
      await waitUntil(
          () => vpn.state == VpnState.disconnected, 'native-stop teardown');
      expect(vpn.state, VpnState.disconnected);
      expect(vpn.errorMsg, isNull,
          reason: 'a native stop is never surfaced as an error');
      expect(vpn.currentServer, isNull);
      expect(vpn.debugAutoRunning, isFalse);
      expect(starts, 0,
          reason: 'no combination was started after the stop');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    '(iii) a full simulated Auto run (fail, fail, success) ends '
    'Connected',
    () async {
      final wg = FakeWireGuard();
      final vpn = VpnController(WarpService(), wgEngine: wg)
        ..debugForceAndroid = true;
      final servers = [
        stealthServer('run-1'),
        stealthServer('run-2'),
        stealthServer('run-3'),
      ];
      var starts = 0;
      var verifyCalls = 0;
      onV2rayCall = (method) {
        if (method != 'startV2Ray') return;
        starts++;
        // Every attempt's core comes up; verification decides.
        Future<void>.delayed(const Duration(milliseconds: 60), () {
          vpn.debugV2rayStatus('CONNECTED');
        });
      };
      vpn.debugComboVerifier = (_) async => ++verifyCalls >= 3;
      await vpn
          .connectStealthAuto(servers)
          .timeout(const Duration(seconds: 90));
      expect(starts, 3);
      expect(verifyCalls, 3);
      expect(vpn.state, VpnState.connected);
      expect(vpn.currentServer?.id, 'run-3');
      expect(vpn.errorMsg, isNull);
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test(
    '(iv) WARP connects on the first tap even when the prologue '
    "stop's stale 'disconnected' lands inside the connect",
    () async {
      final wg = FakeWireGuard();
      final vpn = VpnController(WarpService(), wgEngine: wg)
        ..debugForceAndroid = true;
      const warpServer = VpnServer(
        id: 'warp-1',
        name: 'WARP',
        protocol: 'wireguard',
        type: 'free',
        source: 'warp',
        warp: true,
        endpoint: '162.159.192.1:2408',
      );
      wg.onStart = () {
        // The stale echo of the controller's own prologue stop is
        // delivered at the worst moment: the engine is claimed and
        // startVpn has just been issued. It is a self-stop — it
        // must not fail this attempt (the v2.1.3 first-tap bug).
        vpn.debugWgStage('disconnected');
      };
      await vpn.connect(warpServer).timeout(const Duration(seconds: 60));
      expect(wg.starts, 1, reason: 'one tap, one tunnel start');
      expect(vpn.state, VpnState.connected,
          reason: 'the first attempt reaches Connected');
      expect(vpn.currentServer?.id, 'warp-1');
      expect(vpn.errorMsg, isNull);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'a self-stop echo during a manual connect is consumed, not '
    'failed (the poisoning route, unit level)',
    () async {
      final wg = FakeWireGuard();
      final vpn = VpnController(WarpService(), wgEngine: wg)
        ..debugForceAndroid = true;
      // Issue a real controller stop: every engine is stopped, so
      // every engine owes the controller one DISCONNECTED echo.
      await vpn.disconnect();
      // A manual connect attempt is now in flight (arranged as the
      // connect path leaves it): engine claimed, state connecting,
      // no search running.
      final server = stealthServer('manual-1');
      vpn.debugSetActiveEngine('v2ray');
      vpn.currentServer = server;
      vpn.state = VpnState.connecting;
      // The echo of the controller's own stop arrives late.
      vpn.debugNativeDisconnected('v2ray');
      expect(vpn.state, VpnState.connecting,
          reason: 'a self-stop echo must not fail the attempt');
      expect(vpn.errorMsg, isNull);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'consumption is one-for-one: a second stop event after the '
    'echo was consumed is a genuine external stop',
    () async {
      final wg = FakeWireGuard();
      final vpn = VpnController(WarpService(), wgEngine: wg)
        ..debugForceAndroid = true;
      await vpn.disconnect(); // one self-stop echo owed per engine
      final server = stealthServer('one-for-one');
      vpn.debugSetActiveEngine('v2ray');
      vpn.currentServer = server;
      vpn.state = VpnState.connecting;
      vpn.debugNativeDisconnected('v2ray'); // the echo: consumed
      expect(vpn.state, VpnState.connecting);
      // No echo is owed any more: this stop is external. During a
      // manual connect an external engine stop keeps the failure
      // semantics — crucially it is NOT swallowed.
      vpn.debugNativeDisconnected('v2ray');
      expect(vpn.state, VpnState.error);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'a settled session still honours an external stop even after '
    'self-stops were issued earlier (echoes die at Connected)',
    () async {
      final wg = FakeWireGuard();
      final vpn = VpnController(WarpService(), wgEngine: wg)
        ..debugForceAndroid = true;
      await vpn.disconnect(); // self-stop echoes owed
      final server = stealthServer('settled-1');
      vpn.debugSetActiveEngine('v2ray');
      vpn.currentServer = server;
      vpn.state = VpnState.connecting;
      // The new session's own Connected event: a live tunnel
      // supersedes every pending stop echo for its engine.
      vpn.debugHandleNativeConnectedEvent();
      expect(vpn.state, VpnState.connected);
      // The user now stops the VPN from the notification: it must
      // tear the session down exactly like an in-app disconnect.
      vpn.debugNativeDisconnected('v2ray');
      await waitUntil(
          () => vpn.state == VpnState.disconnected, 'native-stop teardown');
      expect(vpn.state, VpnState.disconnected);
      expect(vpn.currentServer, isNull);
      expect(vpn.errorMsg, isNull);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
