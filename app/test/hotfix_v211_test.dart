// Tests for the v2.1.1 reliability hotfix (Shiv's S25 round 4):
// 1. Stealth search loops must abort on a user disconnect.
// 2. Native engine events are scoped to the active engine.
// 3. Stealth cache schema invalidation.
// 4. First-launch-after-upgrade refresh predicate.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ipchakra/core/app_version.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/services/v2ray_service.dart';
import 'package:ipchakra/services/vpn_controller.dart';
import 'package:ipchakra/services/warp_service.dart';

/// Polls until the controller reaches [want] (native stop calls in
/// the test environment complete only after the mocked plugins'
/// internal waits, so a fixed sleep is not enough).
Future<void> waitForState(VpnController vpn, VpnState want) async {
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (vpn.state != want && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // Stand-ins for the three engine plugins' method channels, so
    // controller disconnects (which stop all engines) complete
    // instead of dying on a missing native side. The OpenVPN plugin
    // in particular fires its disconnect call unawaited, so an
    // unhandled channel would surface as an unhandled async error.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'id.laskarmedia.openvpn_flutter/vpncontrol',
      'billion.group.wireguard_flutter/wgcontrol',
      'flutter_v2ray_client',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(name),
        (call) async => null,
      );
    }
  });

  group('autoShouldContinue (stealth search session token)', () {
    test('a loop continues only while its session is current', () {
      expect(autoShouldContinue(session: 3, currentSession: 3), isTrue);
      expect(autoShouldContinue(session: 3, currentSession: 4), isFalse);
      expect(autoShouldContinue(session: 5, currentSession: 4), isFalse);
      expect(autoShouldContinue(session: 0, currentSession: 1), isFalse);
    });

    test('disconnect and connect both move the token on', () async {
      final vpn = VpnController(WarpService());
      final before = vpn.debugAutoSession;
      await vpn.disconnect();
      expect(vpn.debugAutoSession, greaterThan(before));
      expect(
        autoShouldContinue(
          session: before,
          currentSession: vpn.debugAutoSession,
        ),
        isFalse,
      );
    });
  });

  test(
    'user disconnect during a Stealth Auto search aborts the search',
    () async {
      // Regression (v2.1.0, Shiv's S25): in Stealth the app kept
      // reconnecting after a disconnect tap — the combination search
      // loop could not tell a user disconnect from an attempt
      // failure, waited out its deadline and started the next
      // combination. With the session token, the loop must end
      // silently right after the disconnect: state stays
      // disconnected, no error is written, no server is selected.
      final vpn = VpnController(WarpService());
      const server = VpnServer(
        id: 'auto-abort-1',
        name: 'Auto Abort',
        protocol: 'v2ray',
        source: 'v2ray',
        shareLink:
            'ss://YWVzLTI1Ni1nY206cGFzcw==@203.0.113.9:8388#AutoAbort',
        tier: 'Shadowsocks',
      );
      final search = vpn.connectStealthAuto([server]);
      // The search gets underway synchronously (its first phase is
      // the DNS measurement, which takes about a second).
      expect(vpn.debugAutoRunning, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await vpn.disconnect();
      // The search must finish promptly after the disconnect — not
      // after trying its combinations — and must not write any
      // state of its own afterwards.
      await search.timeout(const Duration(seconds: 30));
      expect(vpn.state, VpnState.disconnected);
      expect(vpn.errorMsg, isNull);
      expect(vpn.currentServer, isNull);
      expect(vpn.statusNote, isNull);
      expect(vpn.debugAutoRunning, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  group('shouldHonorEngineEvent (engine-scoped callbacks)', () {
    test('only the active engine may change the state', () {
      expect(shouldHonorEngineEvent('v2ray', 'v2ray'), isTrue);
      expect(shouldHonorEngineEvent('openvpn', 'openvpn'), isTrue);
      expect(shouldHonorEngineEvent('wireguard', 'wireguard'), isTrue);
    });

    test('events from other engines are ignored', () {
      // The WARP bug: a V2Ray/OpenVPN stop event landing during a
      // WireGuard attempt must not fail it.
      expect(shouldHonorEngineEvent('wireguard', 'v2ray'), isFalse);
      expect(shouldHonorEngineEvent('wireguard', 'openvpn'), isFalse);
      expect(shouldHonorEngineEvent('v2ray', 'wireguard'), isFalse);
      expect(shouldHonorEngineEvent('v2ray', 'openvpn'), isFalse);
      expect(shouldHonorEngineEvent('openvpn', 'v2ray'), isFalse);
      expect(shouldHonorEngineEvent('openvpn', 'wireguard'), isFalse);
    });

    test('with no active engine every state event is ignored', () {
      expect(shouldHonorEngineEvent(null, 'v2ray'), isFalse);
      expect(shouldHonorEngineEvent(null, 'openvpn'), isFalse);
      expect(shouldHonorEngineEvent(null, 'wireguard'), isFalse);
    });
  });

  test('toggleShouldReset: a tap in the error state resets', () {
    expect(toggleShouldReset(VpnState.error), isTrue);
    expect(toggleShouldReset(VpnState.disconnected), isFalse);
    expect(toggleShouldReset(VpnState.connected), isFalse);
    expect(toggleShouldReset(VpnState.connecting), isFalse);
    expect(toggleShouldReset(VpnState.disconnecting), isFalse);
  });

  group('stealth cache schema', () {
    test('only the current schema keeps the cached list', () {
      expect(V2RayService.cacheSchemaMatches(null), isFalse);
      expect(V2RayService.cacheSchemaMatches(1), isFalse);
      expect(V2RayService.cacheSchemaMatches(2), isFalse);
      expect(
        V2RayService.cacheSchemaMatches(V2RayService.cacheSchemaVersion),
        isTrue,
      );
      expect(
        V2RayService.cacheSchemaMatches(V2RayService.cacheSchemaVersion + 1),
        isFalse,
      );
    });

    test('the current schema is the attributed multi-feed one (4)', () {
      // Was 3 in the v2.1.1–v2.2.0 releases (the Hysteria2-capable
      // schema); v2.3.0 bumped it to 4 for per-feed attribution and
      // the five new feeds, so v3 caches are discarded once.
      expect(V2RayService.cacheSchemaVersion, 4);
    });
  });

  group('isNativeStopEvent (Issue 5: notification / native stop)', () {
    test('connected is always a native stop', () {
      expect(
        isNativeStopEvent(state: VpnState.connected, searchRunning: false),
        isTrue,
      );
      expect(
        isNativeStopEvent(state: VpnState.connected, searchRunning: true),
        isTrue,
      );
    });

    test('connecting is a native stop only while a search runs', () {
      expect(
        isNativeStopEvent(state: VpnState.connecting, searchRunning: true),
        isTrue,
      );
      expect(
        isNativeStopEvent(state: VpnState.connecting, searchRunning: false),
        isFalse,
      );
    });

    test('all other states keep the existing semantics', () {
      for (final s in [
        VpnState.disconnected,
        VpnState.disconnecting,
        VpnState.error,
      ]) {
        expect(isNativeStopEvent(state: s, searchRunning: true), isFalse);
        expect(isNativeStopEvent(state: s, searchRunning: false), isFalse);
      }
    });
  });

  test('a native stop while connected tears the session down', () async {
    // Issue 5 (Shiv's S25): stopping the VPN from the notification
    // did not work. When the active engine reports its stop while
    // connected, the controller must honour it exactly like an
    // in-app disconnect: session fields cleared, token moved, state
    // disconnected — never an error.
    final vpn = VpnController(WarpService());
    const server = VpnServer(
      id: 'native-stop-1',
      name: 'Native Stop',
      protocol: 'v2ray',
      source: 'v2ray',
      shareLink: 'ss://YWVzLTI1Ni1nY206cGFzcw==@203.0.113.10:8388#NativeStop',
      tier: 'Shadowsocks',
    );
    vpn.debugSetActiveEngine('v2ray');
    vpn.currentServer = server;
    vpn.currentIp = '203.0.113.10';
    vpn.connectedAt = DateTime.now();
    vpn.state = VpnState.connected;
    final sessionBefore = vpn.debugAutoSession;
    vpn.debugNativeDisconnected('v2ray');
    // The teardown is asynchronous (it stops the other engines).
    await waitForState(vpn, VpnState.disconnected);
    expect(vpn.state, VpnState.disconnected);
    expect(vpn.currentServer, isNull);
    expect(vpn.currentIp, isNull);
    expect(vpn.connectedAt, isNull);
    expect(vpn.errorMsg, isNull);
    expect(vpn.debugAutoSession, greaterThan(sessionBefore));
  });

  test(
    'a native stop mid-search cancels the search like a disconnect',
    () async {
      // Issue 5 + Issue 1: a stop from the notification while the
      // Stealth Auto combination search is running must abort the
      // search — zero further combinations, no error, no reconnect.
      final vpn = VpnController(WarpService());
      const server = VpnServer(
        id: 'native-stop-search',
        name: 'Native Stop Search',
        protocol: 'v2ray',
        source: 'v2ray',
        shareLink:
            'ss://YWVzLTI1Ni1nY206cGFzcw==@203.0.113.11:8388#NativeStopSearch',
        tier: 'Shadowsocks',
      );
      final search = vpn.connectStealthAuto([server]);
      expect(vpn.debugAutoRunning, isTrue);
      // Arrange the in-flight attempt exactly as the search's first
      // combination leaves it: v2ray claimed, state connecting.
      vpn.debugSetActiveEngine('v2ray');
      vpn.state = VpnState.connecting;
      vpn.currentServer = server;
      final sessionWhileSearching = vpn.debugAutoSession;
      // The user stops the VPN from the notification.
      vpn.debugNativeDisconnected('v2ray');
      await search.timeout(const Duration(seconds: 30));
      await waitForState(vpn, VpnState.disconnected);
      expect(vpn.debugAutoSession, greaterThan(sessionWhileSearching));
      expect(vpn.state, VpnState.disconnected);
      expect(vpn.errorMsg, isNull);
      expect(vpn.currentServer, isNull);
      expect(vpn.debugAutoRunning, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('a stop during a manual connect keeps failure semantics', () async {
    // Distinction: with no search running, a DISCONNECTED during a
    // single manual connect is an attempt failure — the user must
    // still see why the server did not connect.
    final vpn = VpnController(WarpService());
    vpn.debugSetActiveEngine('v2ray');
    vpn.state = VpnState.connecting;
    vpn.debugNativeDisconnected('v2ray');
    expect(vpn.state, VpnState.error);
    expect(vpn.errorMsg, 'debug failure message');
  });

  group('isFirstLaunchAfterUpgrade', () {
    test('a build change (or fresh install) forces one refresh', () {
      expect(isFirstLaunchAfterUpgrade(null, kAppBuildNumber), isTrue);
      expect(isFirstLaunchAfterUpgrade(5, 6), isTrue);
      expect(isFirstLaunchAfterUpgrade(7, 6), isTrue);
    });

    test('the same build is a normal launch', () {
      expect(isFirstLaunchAfterUpgrade(6, 6), isFalse);
      expect(
        isFirstLaunchAfterUpgrade(kAppBuildNumber, kAppBuildNumber),
        isFalse,
      );
    });

    test('the recorded build matches this release', () {
      expect(kAppVersionName, '2.3.4');
      expect(kAppBuildNumber, 16);
    });
  });
}
