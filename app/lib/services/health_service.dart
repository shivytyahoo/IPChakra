import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_server.dart';
import 'stealth_link.dart';

/// Health check for every free server: which are working, which are
/// dead, and how fast each working server answers.
///
/// Every server gets a short TCP probe (1.5 s timeout) against its
/// host:port. The result lands in `status[serverId]`: true = working,
/// false = dead, missing = unchecked. Successful TCP probes also record
/// their round-trip time in [latencyMs], which drives fastest-first
/// ordering. The UI updates progressively — badges flip as each batch
/// completes.
class HealthService extends ChangeNotifier {
  static const _kMirrorTargets = 'health_mirror_targets';

  /// Probe timeout for a single TCP connect.
  static const probeTimeout = Duration(milliseconds: 1500);

  /// Servers probed concurrently in one batch.
  static const batchSize = 30;

  /// serverId -> working?
  final Map<String, bool> status = {};

  /// serverId -> measured TCP connect latency in milliseconds.
  /// Only present for servers whose probe succeeded over TCP; WARP
  /// (never probed) and UDP-only servers carry no latency.
  final Map<String, int> latencyMs = {};

  /// Abhi check ho rahe server ids.
  final Set<String> checkingIds = {};

  bool checking = false;
  DateTime? lastChecked;

  /// mirror serverId -> "host:port" (config download se bachta hai)
  final Map<String, String> _mirrorTargets = {};
  bool _mirrorCacheLoaded = false;

  bool? isWorking(String id) => status[id];
  bool isChecking(String id) => checkingIds.contains(id);

  /// Measured latency for [id], or null when it was never measured
  /// (WARP, UDP-only servers, unchecked or dead servers).
  int? latencyOf(String id) => latencyMs[id];

  int get workingCount => status.values.where((v) => v).length;
  int get deadCount => status.values.where((v) => !v).length;

  /// Full re-check of every server in [servers] (manual refresh).
  Future<void> checkAll(List<VpnServer> servers) async {
    if (checking) return;
    checking = true;
    notifyListeners();
    try {
      for (var i = 0; i < servers.length; i += batchSize) {
        final batch = servers.skip(i).take(batchSize).toList();
        await Future.wait(batch.map(_checkOne));
        notifyListeners(); // progressive UI
      }
      lastChecked = DateTime.now();
    } finally {
      checking = false;
      checkingIds.clear();
      notifyListeners();
    }
  }

  /// The currently running [checkMissing] pass chain, if any.
  Future<void>? _missingRun;

  /// Incremental check: probe only the servers in [servers] that have
  /// no health result yet. Safe to call repeatedly and concurrently —
  /// calls made while a run is in flight wait for it and then re-scan,
  /// so servers that arrive late (for example a stealth feed landing
  /// after the WARP list) are still picked up instead of staying
  /// "unchecked" forever. At most two passes run per call chain.
  Future<void> checkMissing(List<VpnServer> servers) {
    final active = _missingRun;
    if (active != null) {
      return active.then((_) => checkMissing(servers));
    }
    late final Future<void> run;
    run = _runMissingPasses(servers).whenComplete(() {
      if (identical(_missingRun, run)) _missingRun = null;
    });
    _missingRun = run;
    return run;
  }

  Future<void> _runMissingPasses(List<VpnServer> servers) async {
    try {
      for (var pass = 0; pass < 2; pass++) {
        final missing = servers
            .where(
              (s) => !status.containsKey(s.id) && !checkingIds.contains(s.id),
            )
            .toList();
        if (missing.isEmpty) return;
        for (var i = 0; i < missing.length; i += batchSize) {
          final batch = missing.skip(i).take(batchSize).toList();
          await Future.wait(batch.map(_checkOne));
          notifyListeners(); // progressive UI
        }
        lastChecked = DateTime.now();
        notifyListeners();
      }
    } catch (_) {
      // Probing is best-effort; individual failures are recorded as
      // "dead" by _checkOne itself.
    }
  }

  Future<void> _checkOne(VpnServer s) async {
    // Never probe the same server twice at once, however many checks
    // (full, incremental, concurrent) are running.
    if (!checkingIds.add(s.id)) return;
    try {
      // WARP is Cloudflare's anycast network, not a single server, so
      // the notion of "dead" does not apply — and WireGuard runs over
      // UDP, so a TCP probe would report a working tunnel as dead.
      // Always working, never probed, no latency.
      if (s.source == 'warp' || s.warp) {
        status[s.id] = true;
        return;
      }
      // Hysteria2 runs over UDP/QUIC: its port will usually refuse a
      // TCP probe even when the server is perfectly healthy, so a
      // failed probe must NEVER mark it dead. Use host-level
      // reachability instead (any TCP answer on its port, else on
      // 443/80, like the UDP OpenVPN fallback): reachable means
      // working (with no latency — QUIC speed is not measurable this
      // way), unreachable means "leave it unchecked", never dead.
      if (s.tier == 'Hysteria2') {
        final t = _parseLinkTarget(s.shareLink);
        if (t == null) return;
        if (await _udpHostProbe(t.$1, t.$2)) {
          status[s.id] = true;
        } else {
          status.remove(s.id);
          latencyMs.remove(s.id);
        }
        return;
      }
      final target = await _resolveTarget(s);
      if (target == null) {
        _recordResult(s.id, false);
      } else if (!target.$3) {
        final ms = await _tcpProbe(target.$1, target.$2);
        _recordResult(s.id, ms != null, latency: ms);
      } else {
        _recordResult(s.id, await _udpHostProbe(target.$1, target.$2));
      }
    } catch (_) {
      _recordResult(s.id, false);
    } finally {
      checkingIds.remove(s.id);
    }
  }

  /// Store one probe outcome. A dead verdict clears any stale latency
  /// so fastest-first ordering never trusts an old measurement.
  void _recordResult(String id, bool working, {int? latency}) {
    status[id] = working;
    if (working && latency != null) {
      latencyMs[id] = latency;
    } else if (!working) {
      latencyMs.remove(id);
    }
  }

  /// Server ka (host, port, isUdp) nikalo — source ke hisaab se.
  Future<(String, int, bool)?> _resolveTarget(VpnServer s) async {
    switch (s.source) {
      case 'vpngate':
        return _parseOvpnTarget(s.ovpnConfig);
      case 'vpnbook':
        final host = s.id.replaceFirst('vpnbook-', '');
        if (host.isEmpty) return null;
        return (host, 443, false);
      case 'mirror':
        return _mirrorTarget(s);
      case 'v2ray':
      case 'custom':
      case 'private':
        // Stealth links (public feed 'v2ray', user-imported 'custom'
        // and private-feed 'private') can be any scheme — ss, vless,
        // trojan or vmess — so resolve the probe target with the
        // general stealth parser.
        final t = _parseLinkTarget(s.shareLink);
        return t == null ? null : (t.$1, t.$2, false);
      default:
        return null;
    }
  }

  /// Mirror ka (host, port, udp) — pehli baar config se parse, phir cache.
  Future<(String, int, bool)?> _mirrorTarget(VpnServer s) async {
    if (!_mirrorCacheLoaded) {
      _mirrorCacheLoaded = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_kMirrorTargets);
        if (raw != null) {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          for (final e in map.entries) {
            _mirrorTargets[e.key] = e.value.toString();
          }
        }
      } catch (_) {}
    }
    final cached = _mirrorTargets[s.id];
    if (cached != null) {
      final parts = cached.split(':');
      if (parts.length >= 2) {
        final port = int.tryParse(parts[1]);
        if (port != null) {
          final udp = parts.length >= 3 && parts[2] == 'udp';
          return (parts[0], port, udp);
        }
      }
    }
    final loader = s.configLoader;
    if (loader == null) return null;
    try {
      final cfg = await loader().timeout(const Duration(seconds: 15));
      final t = _parseOvpnTarget(cfg);
      if (t != null) {
        _mirrorTargets[s.id] = '${t.$1}:${t.$2}:${t.$3 ? 'udp' : 'tcp'}';
        unawaited(_saveMirrorCache());
      }
      return t;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveMirrorCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kMirrorTargets, jsonEncode(_mirrorTargets));
    } catch (_) {}
  }

  /// OpenVPN config se "remote HOST PORT" + proto (tcp/udp).
  (String, int, bool)? _parseOvpnTarget(String? config) {
    if (config == null) return null;
    final m = RegExp(r'^remote\s+(\S+)\s+(\d+)', multiLine: true)
        .firstMatch(config);
    if (m == null) return null;
    final port = int.tryParse(m.group(2)!);
    if (port == null) return null;
    final protoM =
        RegExp(r'^proto\s+(\S+)', multiLine: true).firstMatch(config);
    final proto = protoM?.group(1)?.toLowerCase() ?? 'tcp';
    return (m.group(1)!, port, proto.contains('udp'));
  }

  /// UDP OpenVPN server: try TCP on the VPN port (some hosts listen on
  /// both), then on 443/80 — any open port means the host is up.
  Future<bool> _udpHostProbe(String host, int port) async {
    if (await _tcpProbe(host, port) != null) return true;
    if (port != 443 && await _tcpProbe(host, 443) != null) return true;
    if (port != 80 && await _tcpProbe(host, 80) != null) return true;
    return false;
  }

  /// Host and port for any stealth share link (ss/vless/trojan/vmess),
  /// resolved via [StealthLink]. Returns null for non-stealth links.
  (String, int)? _parseLinkTarget(String? link) {
    if (link == null) return null;
    final info = StealthLink.parse(link);
    if (info == null) return null;
    return (info.host, info.port);
  }

  /// ss://BASE64@host:port se host:port.
  (String, int)? _parseSsTarget(String? link) {
    if (link == null || !link.startsWith('ss://')) return null;
    try {
      final atIdx = link.indexOf('@');
      if (atIdx < 0) return null;
      final after = link.substring(atIdx + 1);
      final endIdx = after.indexOf(RegExp(r'[#/?]'));
      final hostPort = endIdx > 0 ? after.substring(0, endIdx) : after;
      // IPv6 [::1]:port bhi sambhalo
      final m = RegExp(r'^\[([^\]]+)\]:(\d+)$').firstMatch(hostPort) ??
          RegExp(r'^([^:]+):(\d+)$').firstMatch(hostPort);
      if (m == null) return null;
      final port = int.tryParse(m.group(2)!);
      if (port == null) return null;
      return (m.group(1)!, port);
    } catch (_) {
      return null;
    }
  }

  /// Short TCP handshake — returns the connect latency in
  /// milliseconds when the server answers, null when it does not.
  Future<int?> _tcpProbe(String host, int port) async {
    final watch = Stopwatch()..start();
    try {
      final socket = await Socket.connect(host, port, timeout: probeTimeout);
      watch.stop();
      socket.destroy();
      return watch.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  void reset() {
    status.clear();
    latencyMs.clear();
    checkingIds.clear();
    checking = false;
    lastChecked = null;
    notifyListeners();
  }

  /// Sirf test ke liye.
  @visibleForTesting
  (String, int, bool)? debugParseRemote(String c) => _parseOvpnTarget(c);

  /// Sirf test ke liye.
  @visibleForTesting
  (String, int)? debugParseSs(String? l) => _parseSsTarget(l);

  /// Test-only: host/port for any stealth share link scheme.
  @visibleForTesting
  (String, int)? debugParseLink(String? l) => _parseLinkTarget(l);
}

/// The one shared server ordering, used by the Home screen, the
/// Servers screen and Stealth Auto alike:
///
/// 1. Working servers with a known speed — fastest first. The speed is
///    the measured probe latency when present, otherwise the ping the
///    source API reported ([VpnServer.pingMs], e.g. VPNGate).
/// 2. Working servers with no speed information.
/// 3. Unchecked servers, keeping their input order (tier order for
///    stealth lists, API order for OpenVPN sources).
/// 4. Dead servers last.
///
/// The sort is stable: servers that compare equal keep input order.
List<VpnServer> sortByHealthAndLatency(
  List<VpnServer> servers,
  HealthService health,
) {
  int rankOf(VpnServer s) {
    final working = health.isWorking(s.id);
    if (working == true) {
      return (health.latencyOf(s.id) != null || s.pingMs != null) ? 0 : 1;
    }
    if (working == null) return 2;
    return 3;
  }

  int? speedOf(VpnServer s) => health.latencyOf(s.id) ?? s.pingMs;

  final decorated = <(int, int?, int, VpnServer)>[
    for (var i = 0; i < servers.length; i++)
      (rankOf(servers[i]), speedOf(servers[i]), i, servers[i]),
  ];
  decorated.sort((a, b) {
    final byRank = a.$1.compareTo(b.$1);
    if (byRank != 0) return byRank;
    final sa = a.$2;
    final sb = b.$2;
    if (sa != null && sb != null) {
      final bySpeed = sa.compareTo(sb);
      if (bySpeed != 0) return bySpeed;
    }
    return a.$3.compareTo(b.$3);
  });
  return [for (final e in decorated) e.$4];
}

/// Drop the servers [health] has marked dead — unless every server is
/// dead, in which case the full list is returned (trying a "dead"
/// server beats not trying at all; probes can be wrong).
List<VpnServer> aliveOrAll(List<VpnServer> servers, HealthService health) {
  final alive = servers
      .where((s) => health.isWorking(s.id) != false)
      .toList();
  return alive.isNotEmpty ? alive : servers;
}
