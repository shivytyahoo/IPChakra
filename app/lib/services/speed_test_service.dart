import 'dart:async';
import 'dart:io';

import '../models/vpn_server.dart';
import 'health_service.dart';
import 'tunnel_verifier.dart';
import 'vpn_controller.dart';

/// Measures REAL download speed through a live tunnel, one server
/// at a time — the "Fastest" filter's speed test.
///
/// Why a tunnel download, not a ping: a TCP probe answers in
/// milliseconds even on a relay that pushes 1 Mbps once loaded, and
/// the VPNGate ping is measured from VPNGate's side, not the user's
/// network. Only a file pulled through the tunnel itself ranks
/// servers by the download speed the user will actually get.
///
/// How the download reaches the tunnel depends on the engine:
///
/// - Stealth (V2Ray/Xray): the app is EXCLUDED from its own VPN
///   (V2rayVPNService adds its own package to the disallowed list),
///   so a direct download would measure the direct connection, not
///   the server. The file is therefore pulled through the core's
///   SOCKS inbound (127.0.0.1:10807) — the exact path user traffic
///   takes, and the same path the connect-time verifier uses.
/// - OpenVPN / WireGuard: neither engine excludes the app, so the
///   app's own sockets ARE routed through the tunnel, and a direct
///   HTTPS download measures the tunnel.
///
/// Each candidate costs one connect + one ~5 MB download, so a run
/// is bounded ([maxServers]) and explicit: the user taps "Test
/// speed" on a Fastest list, watches progress, and can cancel. The
/// session the user had before the test is restored afterwards.
class ServerSpeedTest {
  ServerSpeedTest({
    required this.connector,
    required this.health,
    this.debugDownload,
  });

  /// How many candidates one run measures (the latency-fastest
  /// working servers). Six keeps a run to a few minutes worst case:
  /// a stealth connect alone can take ~30 s on a slow combination.
  static const maxServers = 6;

  /// Per-candidate connect budget. The controller's own attempt
  /// timeout is 30 s; the extra 15 s covers the stealth
  /// combination search around it. A candidate that does not come
  /// up in time is skipped, not retried.
  static const connectBudget = Duration(seconds: 45);

  /// Per-candidate download budget. A server too slow to pull the
  /// 5 MB test file in time reports no speed instead of a
  /// misleading one — and stays ranked by latency.
  static const downloadBudget = Duration(seconds: 30);

  /// Direct-download test file (OpenVPN / WireGuard path): a
  /// cache-free 5 MB file from Cloudflare's speed-test endpoint.
  static const directTestUrl =
      'https://speed.cloudflare.com/__down?bytes=5000000';

  final SpeedTestConnector connector;
  final HealthService health;

  /// Test seam: replaces the real download (unit tests). When set,
  /// no network is touched for the download itself.
  final Future<double?> Function(VpnServer server)? debugDownload;

  /// Measure [candidates] (already in latency-fastest order) and
  /// record each measured speed in [health], fastest-first
  /// afterwards. [onProgress] fires as (measured, total, name);
  /// [isCancelled] is polled between candidates and aborts the run.
  /// The pre-test session is restored in all cases (see below).
  Future<void> testCandidates(
    List<VpnServer> candidates, {
    required void Function(int done, int total, String name) onProgress,
    required bool Function() isCancelled,
  }) async {
    final list = candidates.take(maxServers).toList();
    final prevServer = connector.currentServer;
    final wasConnected = connector.isConnected;
    var done = 0;
    try {
      for (final s in list) {
        if (isCancelled()) break;
        onProgress(done, list.length, s.name);
        final mbps = await _measureOne(s, isCancelled);
        if (mbps != null) health.recordSpeed(s.id, mbps);
        done++;
        onProgress(done, list.length, s.name);
      }
    } finally {
      // Restore the session the user had before the test, so a
      // speed run never silently leaves them disconnected. Best
      // effort: a restore that fails leaves them disconnected with
      // the speeds already recorded.
      if (wasConnected && prevServer != null) {
        try {
          if (connector.currentServer?.id != prevServer.id ||
              !connector.isConnected) {
            await connector
                .connect(prevServer)
                .timeout(const Duration(seconds: 60));
          }
        } catch (_) {}
      }
    }
  }

  /// Connect to [s] (unless already there), download the test file
  /// through the live tunnel, disconnect again. Returns the
  /// measured Mbps, or null when the server could not be measured.
  Future<double?> _measureOne(
    VpnServer s,
    bool Function() isCancelled,
  ) async {
    final alreadyThere =
        connector.isConnected && connector.currentServer?.id == s.id;
    if (!alreadyThere) {
      try {
        await connector.connect(s).timeout(connectBudget);
      } catch (_) {
        await _quietDisconnect();
        return null;
      }
      if (isCancelled()) {
        await _quietDisconnect();
        return null;
      }
      if (!connector.isConnected) {
        await _quietDisconnect();
        return null;
      }
    }
    double? mbps;
    try {
      mbps = debugDownload != null
          ? await debugDownload!(s)
          : await _downloadFor(s);
    } catch (_) {
      mbps = null;
    }
    if (!alreadyThere) await _quietDisconnect();
    return mbps;
  }

  Future<double?> _downloadFor(VpnServer s) async {
    if (s.isStealth) return TunnelVerifier.downloadSpeedMbps();
    return _directDownloadMbps();
  }

  /// Direct HTTPS download (OpenVPN / WireGuard path): the socket
  /// is routed through the system tunnel, so the bytes counted here
  /// crossed it.
  static Future<double?> _directDownloadMbps() async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final watch = Stopwatch()..start();
      final request =
          await client.getUrl(Uri.parse(directTestUrl)).timeout(
                const Duration(seconds: 10),
              );
      final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
      if (response.statusCode != 200) return null;
      var bytes = 0;
      // Total budget, not per-chunk: a trickling server must not
      // stretch the download past it one chunk at a time.
      await response
          .forEach((chunk) => bytes += chunk.length)
          .timeout(downloadBudget);
      watch.stop();
      final secs = watch.elapsedMilliseconds / 1000;
      if (secs <= 0 || bytes == 0) return null;
      return bytes * 8 / secs / 1e6;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _quietDisconnect() async {
    try {
      await connector.disconnect();
    } catch (_) {}
  }
}

/// The tunnel operations a speed run needs, behind a seam so unit
/// tests can drive the loop with a fake instead of real engines.
abstract class SpeedTestConnector {
  VpnServer? get currentServer;
  bool get isConnected;
  Future<void> connect(VpnServer server);
  Future<void> disconnect();
}

/// Production [SpeedTestConnector] over the app's [VpnController].
/// The mode switch mirrors the Servers screen's own connect path:
/// stealth servers run in stealth mode, WARP in free mode.
class VpnControllerConnector implements SpeedTestConnector {
  VpnControllerConnector(this.vpn);

  final VpnController vpn;

  @override
  VpnServer? get currentServer => vpn.server;

  @override
  bool get isConnected => vpn.state == VpnState.connected;

  @override
  Future<void> connect(VpnServer s) async {
    if (s.protocol == 'v2ray') {
      vpn.setMode(AppMode.stealth);
    } else if (s.protocol == 'wireguard' && s.warp) {
      vpn.setMode(AppMode.free);
    }
    await vpn.connect(s);
  }

  @override
  Future<void> disconnect() => vpn.disconnect();
}
