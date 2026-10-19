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
///
/// Verdicts are PERSISTED (see [loadPersisted]) and stay fresh for
/// [freshFor]: reopening the app shows the last-known badges and
/// ordering instantly and only re-probes what is missing or stale,
/// instead of re-probing ~5,800 servers from zero on every launch —
/// the "checking goes on forever" device complaint. A manual
/// refresh (checkAll) always re-probes everything.
class HealthService extends ChangeNotifier {
  static const _kMirrorTargets = 'health_mirror_targets';
  static const _kPersisted = 'health_results_v1';

  /// Probe timeout for a single TCP connect.
  static const probeTimeout = Duration(milliseconds: 1500);

  /// Servers probed concurrently in one batch.
  static const batchSize = 60;

  /// How long a recorded verdict counts as fresh: incremental
  /// checks skip fresh servers and only re-probe missing or stale
  /// ones.
  static const freshFor = Duration(minutes: 30);

  /// serverId -> epoch milliseconds of its last completed probe.
  final Map<String, int> _checkedAtMs = {};

  Timer? _persistTimer;

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

  /// Load the persisted verdicts written by earlier launches, so
  /// the lists open with their last-known badges and ordering
  /// instead of a blank "unchecked" slate. Never throws.
  Future<void> loadPersisted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kPersisted);
      if (raw == null) return;
      final doc = jsonDecode(raw);
      if (doc is! Map) return;
      for (final e in doc.entries) {
        final v = e.value;
        if (v is List && v.length == 3) {
          final id = e.key.toString();
          status[id] = (v[0] as num) != 0;
          final lat = (v[1] as num).toInt();
          if (lat >= 0) latencyMs[id] = lat;
          _checkedAtMs[id] = (v[2] as num).toInt();
        }
      }
      notifyListeners();
    } catch (_) {
      // A malformed store just means a cold start.
    }
  }

  /// Persist the current verdicts, debounced: probing records
  /// results batch by batch, and the store is rewritten once the
  /// results settle instead of thousands of times.
  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(_persistNow());
    });
  }

  Future<void> _persistNow() async {
    try {
      final doc = <String, List<int>>{
        for (final e in status.entries)
          e.key: [
            e.value ? 1 : 0,
            latencyMs[e.key] ?? -1,
            _checkedAtMs[e.key] ?? 0,
          ],
      };
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPersisted, jsonEncode(doc));
    } catch (_) {
      // Persistence is an optimisation; losing it costs a re-probe,
      // never correctness.
    }
  }

  /// Whether [s] needs a probe in an incremental pass right now:
  /// it has no verdict yet, or its verdict is older than [freshFor].
  /// A verdict recorded outside the probe path (tests seed [status]
  /// directly, with no timestamp) counts as fresh — the seeding is
  /// deliberate.
  bool _needsCheck(VpnServer s, int nowMs) {
    if (checkingIds.contains(s.id)) return false;
    final ts = _checkedAtMs[s.id];
    if (ts == null) return !status.containsKey(s.id);
    return nowMs - ts > freshFor.inMilliseconds;
  }

  /// Whether an incremental pass should defer [s] to a manual
  /// refresh: a port-less pool UDP entry's probe target can only be
  /// learned by downloading its config (a network fetch of up to
  /// 15 s inside a health check). The background auto-check must
  /// never pay that per server — with ~1,000 such entries it alone
  /// kept checking busy for many minutes. Entries whose target is
  /// already cached probe normally, and a manual checkAll resolves
  /// the rest.
  bool _deferredForIncremental(VpnServer s) =>
      s.source == 'vpngate-pool' &&
      s.probeHost == null &&
      !_mirrorTargets.containsKey(s.id);

  /// The currently running [checkMissing] pass chain, if any.
  Future<void>? _missingRun;

  /// Incremental check: probe only the servers in [servers] that
  /// have no fresh health result. Safe to call repeatedly and
  /// concurrently — calls made while a run is in flight wait for it
  /// and then re-scan, so servers that arrive late (for example a
  /// stealth feed landing after the WARP list) are still picked up
  /// instead of staying "unchecked" forever. At most two passes run
  /// per call chain.
  ///
  /// With [priority] the pass runs IMMEDIATELY, in parallel with
  /// any background run, instead of queueing behind it: the
  /// connect paths use this for the bounded batch they are about
  /// to choose from, because a user's Connect tap must never wait
  /// for a background sweep of thousands of unrelated servers.
  /// Per-server probing stays single-flight via [checkingIds], so
  /// parallel passes can never probe the same server twice at once.
  Future<void> checkMissing(List<VpnServer> servers,
      {bool priority = false}) {
    if (priority) return _runMissingPasses(servers);
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
      await _loadMirrorCacheOnce();
      for (var pass = 0; pass < 2; pass++) {
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final missing = servers
            .where(
              (s) => _needsCheck(s, nowMs) && !_deferredForIncremental(s),
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
        _recordResult(s.id, true);
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
          _recordResult(s.id, true);
        } else {
          // No verdict — but the probe DID happen: stamp it, so
          // the freshness window applies and back-to-back passes
          // do not immediately re-probe the same unreachable host.
          status.remove(s.id);
          latencyMs.remove(s.id);
          _checkedAtMs[s.id] = DateTime.now().millisecondsSinceEpoch;
          _schedulePersist();
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
  /// Every outcome is timestamped (the freshness window incremental
  /// checks honour) and the persisted store is updated, debounced.
  void _recordResult(String id, bool working, {int? latency}) {
    status[id] = working;
    if (working && latency != null) {
      latencyMs[id] = latency;
    } else if (!working) {
      latencyMs.remove(id);
    }
    _checkedAtMs[id] = DateTime.now().millisecondsSinceEpoch;
    _schedulePersist();
  }

  /// Server ka (host, port, isUdp) nikalo — source ke hisaab se.
  Future<(String, int, bool)?> _resolveTarget(VpnServer s) async {
    // Sources that publish their endpoint up front (the VPNGate
    // API and rolling pool, the VPNBook variants) carry the probe
    // target on the server itself — no config download is needed
    // to health-check them.
    if (s.probeHost != null && s.probePort != null) {
      return (s.probeHost!, s.probePort!, s.probeUdp);
    }
    // Pool UDP entries are the one exception: the pool index
    // carries no port for them (a TCP probe cannot judge a UDP
    // server), so resolve the target from the config once and
    // cache it — the same trick the mirror entries use.
    if (s.source == 'vpngate-pool') {
      return _mirrorTarget(s);
    }
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
      case 'snsub':
      case 'au1rxx':
      case 'epodonios':
      case 'eternity':
      case 'submerge':
      case 'pawdroid':
      case 'matin':
      case 'nomorewalls':
      case 'barryfar':
      case 'custom':
      case 'private':
        // Stealth links (the public feeds, user-imported 'custom'
        // and private-feed 'private') can be any scheme — ss, vless,
        // trojan or vmess — so resolve the probe target with the
        // general stealth parser.
        final t = _parseLinkTarget(s.shareLink);
        return t == null ? null : (t.$1, t.$2, false);
      default:
        // Any other source that carries a share link — the user's
        // own subscriptions (v2.3.1), whose source is the name they
        // chose — resolves exactly like the enumerated stealth
        // sources. Sources without a link stay unresolvable.
        final t = _parseLinkTarget(s.shareLink);
        return t == null ? null : (t.$1, t.$2, false);
    }
  }

  /// Load the persisted mirror/pool probe targets once.
  Future<void> _loadMirrorCacheOnce() async {
    if (_mirrorCacheLoaded) return;
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

  /// Mirror ka (host, port, udp) — pehli baar config se parse, phir cache.
  Future<(String, int, bool)?> _mirrorTarget(VpnServer s) async {
    await _loadMirrorCacheOnce();
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
    _checkedAtMs.clear();
    checking = false;
    lastChecked = null;
    _schedulePersist();
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
/// 3. Unchecked servers — externally verified ones (a liveness
///    registry's real handshake test) before plain unchecked ones,
///    then their input order (tier order for stealth lists, API
///    order for OpenVPN sources).
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

  // The overlay sub-rank, meaningful only inside the unchecked
  // rank: a server an independent registry verified alive with a
  // real handshake test ([VpnServer.externalVerified]) is a better
  // first try than a completely untested one. It can never lift a
  // server out of the rank the app's own checks put it in — a
  // server the app found dead stays in the dead rank, verified or
  // not.
  int subRankOf(VpnServer s) =>
      (rankOf(s) == 2 && s.externalVerified) ? 0 : 1;

  final decorated = <(int, int, int?, int, VpnServer)>[
    for (var i = 0; i < servers.length; i++)
      (
        rankOf(servers[i]),
        subRankOf(servers[i]),
        speedOf(servers[i]),
        i,
        servers[i],
      ),
  ];
  decorated.sort((a, b) {
    final byRank = a.$1.compareTo(b.$1);
    if (byRank != 0) return byRank;
    final bySubRank = a.$2.compareTo(b.$2);
    if (bySubRank != 0) return bySubRank;
    final sa = a.$3;
    final sb = b.$3;
    if (sa != null && sb != null) {
      final bySpeed = sa.compareTo(sb);
      if (bySpeed != 0) return bySpeed;
    }
    return a.$4.compareTo(b.$4);
  });
  return [for (final e in decorated) e.$5];
}

/// The fastest server in [servers] according to [health]: the
/// working server with the lowest speed (measured probe latency,
/// falling back to the source-reported ping — the same ordering
/// [sortByHealthAndLatency] uses). A working server with no speed
/// information is only ever the fallback when no measured working
/// server exists. Returns null when no server in the group is
/// known to be working (unchecked and dead servers do not count).
/// Pure — unit-tested.
VpnServer? pickFastestInGroup(List<VpnServer> servers, HealthService health) {
  VpnServer? bestMeasured;
  int? bestSpeed;
  VpnServer? bestUnmeasured;
  for (final s in servers) {
    if (health.isWorking(s.id) != true) continue;
    final speed = health.latencyOf(s.id) ?? s.pingMs;
    if (speed == null) {
      bestUnmeasured ??= s;
      continue;
    }
    if (bestSpeed == null || speed < bestSpeed) {
      bestSpeed = speed;
      bestMeasured = s;
    }
  }
  return bestMeasured ?? bestUnmeasured;
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

/// Only the servers [health] has verified working — the membership
/// of the lists' "Working" filter. Input order is preserved; the
/// callers apply [sortByHealthAndLatency] and country grouping on
/// top, so the filter shows working servers fastest-first per
/// country and fills live as verdicts land.
List<VpnServer> workingServers(List<VpnServer> servers, HealthService health) {
  return servers.where((s) => health.isWorking(s.id) == true).toList();
}
