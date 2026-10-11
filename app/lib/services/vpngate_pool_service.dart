import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_server.dart';
import 'vpngate_service.dart';

/// The VPNGate rolling pool: a community mirror (GeorgeXie2333 on
/// GitHub) whose hourly bot accumulates the rotating subsets the
/// official VPNGate API returns, so the whole network — thousands
/// of volunteer relays — becomes fetchable as one index.
///
/// Cost model: a ~1 KB change index (`pool/latest.json`) carries
/// the SHA-256 of the ~7 MB pool index (`pool/servers.json`). The
/// app polls the small file and downloads the big one only when
/// that hash actually changed. Individual OpenVPN configs are
/// fetched on demand, one per server the user (or the health
/// checker) actually touches — never in bulk.
///
/// The same service also fetches the independent liveness registry
/// (G1010yzd10/vpngate-monitor), which tests VPNGate servers with
/// real OpenVPN handshakes every few hours. It carries no configs;
/// its alive set is exposed as [verifiedAliveKeys] and applied to
/// the merged OpenVPN database as a "verified" hint. The app's own
/// health checks remain the final arbiter — the registry can never
/// mark a server working, and a server the app found dead stays
/// dead (see the merge in openvpn_database.dart and the ordering in
/// health_service.dart).

/// Base of the pool repository on the jsDelivr CDN.
const String _cdnBase =
    'https://cdn.jsdelivr.net/gh/GeorgeXie2333/vpngate-list-mirror@latest';

/// The ~1 KB change index for the pool.
const String poolIndexUrl = '$_cdnBase/pool/latest.json';

/// The ~7 MB pool index (downloaded only when the change index
/// says its SHA-256 moved).
const String poolServersUrl = '$_cdnBase/pool/servers.json';

/// The liveness registry's latest results (fixed raw URL).
const String monitorLatestUrl =
    'https://raw.githubusercontent.com/G1010yzd10/vpngate-monitor/main/data/latest.json';

/// Extract the change marker for `pool/servers.json` from the
/// change index body: the file's SHA-256 as published by the bot.
/// Returns null when the body is not the expected index document.
String? poolIndexMarker(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return null;
    final files = decoded['files'];
    if (files is! Map) return null;
    final entry = files['pool/servers.json'];
    if (entry is! Map) return null;
    final sha = entry['sha256']?.toString();
    return (sha == null || sha.isEmpty) ? null : sha;
  } catch (_) {
    return null;
  }
}

/// Whether the pool index must be (re)downloaded: only when the
/// freshly polled marker differs from the stored one. A failed poll
/// (null marker) never triggers a download and never discards the
/// cached pool.
bool poolIndexChanged(String? storedMarker, String? polledMarker) =>
    polledMarker != null && polledMarker != storedMarker;

/// Parse the pool index body into compact entry maps (the form the
/// app caches — a fraction of the source document's size, with the
/// raw probe bookkeeping dropped). An entry is kept when it carries
/// everything needed to list and later fetch its config: an IP, a
/// country and a config path. The endpoint port comes from the
/// entry's probe target; UDP entries carry no probe target (a TCP
/// probe cannot judge them), so their port stays null and is
/// resolved from the config itself when needed.
///
/// Pure and top-level so it can run in a background isolate via
/// [compute] and be unit-tested directly.
List<Map<String, dynamic>> parsePoolIndex(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) return [];
  final rawServers = decoded['servers'];
  if (rawServers is! List) return [];
  final out = <Map<String, dynamic>>[];
  for (final raw in rawServers) {
    if (raw is! Map) continue;
    final ip = raw['ip']?.toString() ?? '';
    final config = raw['config'];
    final cfgPath = config is Map ? config['path']?.toString() ?? '' : '';
    final country = raw['country_name']?.toString() ?? '';
    if (ip.isEmpty || cfgPath.isEmpty || country.isEmpty) continue;
    int? port;
    final targets = raw['probe_targets'];
    if (targets is List && targets.isNotEmpty) {
      final first = targets.first;
      if (first is Map) port = (first['port'] as num?)?.toInt();
    }
    final speedBps = (raw['speed_bps'] as num?)?.toInt() ?? 0;
    out.add({
      'ip': ip,
      'h': raw['hostname']?.toString() ?? '',
      'p': port,
      'u': raw['probe_reason']?.toString() == 'udp' ? 1 : 0,
      'c': country,
      'cc': raw['country_code']?.toString() ?? '',
      'ping': (raw['ping_ms'] as num?)?.toInt(),
      'mbps': speedBps ~/ 1000000,
      'sess': (raw['num_vpn_sessions'] as num?)?.toInt() ?? 0,
      'cfg': cfgPath,
      'sha': raw['openvpn_config_sha256']?.toString() ?? '',
      'bytes': (raw['openvpn_config_bytes'] as num?)?.toInt() ?? 0,
    });
  }
  return out;
}

/// Parse the liveness registry body into the set of endpoint keys
/// (`ip:port:proto`) whose latest real OpenVPN handshake test
/// succeeded. Dead and untested entries contribute nothing.
///
/// Pure and top-level, for the same isolate/test reasons as
/// [parsePoolIndex].
List<String> parseMonitorAliveKeys(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! List) return [];
  final out = <String>[];
  for (final raw in decoded) {
    if (raw is! Map) continue;
    final test = raw['test'];
    if (test is! Map || test['alive'] != true) continue;
    final via = test['via']?.toString() ?? '';
    final cut = via.lastIndexOf(':');
    final ip = cut > 0 ? via.substring(0, cut) : (raw['IP']?.toString() ?? '');
    final port = cut > 0 ? via.substring(cut + 1) : '';
    if (ip.isEmpty || port.isEmpty) continue;
    final proto = (test['proto']?.toString() ?? 'tcp').toLowerCase();
    out.add('$ip:$port:$proto');
  }
  return out;
}

/// Build the listable server for one compact pool [entry]. The
/// config itself is NOT downloaded here — [configFetcher] runs only
/// when the user connects or the health checker needs the endpoint
/// of a UDP entry whose port the index does not carry.
VpnServer poolEntryToServer(
  Map<String, dynamic> e, {
  required Future<String> Function(Map<String, dynamic>) configFetcher,
}) {
  final ip = e['ip']?.toString() ?? '';
  final port = (e['p'] as num?)?.toInt();
  final udp = e['u'] == 1;
  final country = e['c']?.toString() ?? '';
  final hostname = e['h']?.toString() ?? '';
  final ping = (e['ping'] as num?)?.toInt();
  final segments = <String>[
    udp ? 'UDP' : 'TCP',
    if (port != null) '$port',
    if (ping != null && ping > 0) '$ping ms',
    '${(e['mbps'] as num?)?.toInt() ?? 0} Mbps',
    '${(e['sess'] as num?)?.toInt() ?? 0} users',
  ];
  return VpnServer(
    id: 'pool-$ip-${port ?? 'x'}-${udp ? 'udp' : 'tcp'}',
    name: '$country ${hostname.isNotEmpty ? hostname : ip}',
    country: country,
    flag: VpnGateService.flagFor(e['cc']?.toString() ?? ''),
    type: 'free',
    protocol: 'openvpn',
    note: segments.join(' • '),
    pingMs: ping,
    source: 'vpngate-pool',
    authUsername: VpnGateService.username,
    authPassword: VpnGateService.password,
    probeHost: ip,
    probePort: port,
    probeUdp: udp,
    configLoader: () => configFetcher(e),
  );
}

class VpnGatePoolService extends ChangeNotifier {
  static const _kEntries = 'pool_entries_v1';
  static const _kMarker = 'pool_servers_sha';
  static const _kPollTime = 'pool_poll_time';
  static const _kOverlay = 'pool_overlay_v1';
  static const _kOverlayTime = 'pool_overlay_time';

  /// How stale the change-index poll / liveness overlay may get
  /// before the app refreshes them on its own. The pool bot commits
  /// hourly and the registry retests every ~6 hours, so 6 hours
  /// loses nothing.
  static const staleMs = 6 * 3600 * 1000;

  List<VpnServer> servers = [];
  bool loading = false;
  String source = 'none'; // remote | cache | none
  String? error;

  /// Endpoint keys (`ip:port:proto`) the liveness registry verified
  /// alive with a real OpenVPN handshake. Replaced (never mutated)
  /// on every successful overlay refresh, so consumers can detect a
  /// change by identity.
  Set<String> verifiedAliveKeys = const {};

  List<Map<String, dynamic>> _entries = [];
  String? _marker;

  /// Recently fetched configs, keyed by config path — a reconnect
  /// or a health probe never downloads the same config twice.
  final Map<String, String> _configCache = {};

  Future<void> load({bool forceRefresh = false}) async {
    if (loading) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_entries.isEmpty) {
        _entries = _readCachedEntries(prefs);
        _marker = prefs.getString(_kMarker);
        final cachedOverlay = prefs.getString(_kOverlay);
        if (cachedOverlay != null) {
          try {
            verifiedAliveKeys = Set.unmodifiable(
              (jsonDecode(cachedOverlay) as List)
                  .map((e) => e.toString()),
            );
          } catch (_) {
            // A corrupt overlay cache is dropped, never fatal.
          }
        }
        if (_entries.isNotEmpty) {
          _rebuildServers();
          source = 'cache';
        }
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final lastPoll = prefs.getInt(_kPollTime) ?? 0;
      if (forceRefresh || now - lastPoll > staleMs) {
        await _pollIndex(prefs);
      }
      final lastOverlay = prefs.getInt(_kOverlayTime) ?? 0;
      if (forceRefresh || now - lastOverlay > staleMs) {
        await _refreshOverlay(prefs);
      }
      if (_entries.isEmpty && verifiedAliveKeys.isEmpty) {
        error = 'The VPNGate pool could not be loaded. '
            'Check the internet and refresh.';
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Poll the ~1 KB change index; download the ~7 MB pool index
  /// only when its published SHA-256 actually moved. Every failure
  /// keeps the cached pool untouched.
  Future<void> _pollIndex(SharedPreferences prefs) async {
    String? marker;
    try {
      final r = await http
          .get(Uri.parse(poolIndexUrl), headers: {'User-Agent': 'IPChakra'})
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200) marker = poolIndexMarker(r.body);
    } catch (_) {
      return; // Poll failed — the cached pool stays authoritative.
    }
    if (marker == null) return;
    await prefs.setInt(
        _kPollTime, DateTime.now().millisecondsSinceEpoch);
    if (!poolIndexChanged(_marker, marker) && _entries.isNotEmpty) {
      return; // Nothing changed upstream — no big download.
    }
    try {
      final r = await http
          .get(Uri.parse(poolServersUrl),
              headers: {'User-Agent': 'IPChakra'})
          .timeout(const Duration(seconds: 120));
      if (r.statusCode != 200) return;
      final entries = await compute(parsePoolIndex, r.body);
      if (entries.isEmpty) return;
      _entries = entries;
      _marker = marker;
      await prefs.setString(_kEntries, jsonEncode(entries));
      await prefs.setString(_kMarker, marker);
      _rebuildServers();
      source = 'remote';
      notifyListeners();
    } catch (_) {
      // Download/parse failed — keep the last good pool.
    }
  }

  /// Refresh the liveness overlay on its own cadence. A failure (or
  /// an empty parse) keeps the previous alive set.
  Future<void> _refreshOverlay(SharedPreferences prefs) async {
    try {
      final r = await http
          .get(Uri.parse(monitorLatestUrl),
              headers: {'User-Agent': 'IPChakra'})
          .timeout(const Duration(seconds: 60));
      if (r.statusCode != 200) return;
      final keys = await compute(parseMonitorAliveKeys, r.body);
      if (keys.isEmpty) return;
      verifiedAliveKeys = Set.unmodifiable(keys.toSet());
      await prefs.setString(_kOverlay, jsonEncode(keys));
      await prefs.setInt(
          _kOverlayTime, DateTime.now().millisecondsSinceEpoch);
      notifyListeners();
    } catch (_) {
      // Overlay is an enhancement only — its absence changes
      // nothing about the list or the ordering.
    }
  }

  List<Map<String, dynamic>> _readCachedEntries(SharedPreferences prefs) {
    try {
      final raw = prefs.getString(_kEntries);
      if (raw == null) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final e in decoded)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    } catch (_) {
      return [];
    }
  }

  void _rebuildServers() {
    servers = [
      for (final e in _entries)
        poolEntryToServer(e, configFetcher: fetchConfig),
    ];
  }

  /// Download one server's OpenVPN config on demand and verify it
  /// against the byte count and SHA-256 the pool index published
  /// for it before trusting it.
  Future<String> fetchConfig(Map<String, dynamic> entry) async {
    final path = entry['cfg']?.toString() ?? '';
    if (path.isEmpty) throw Exception('This server has no config.');
    final cached = _configCache[path];
    if (cached != null) return cached;
    final r = await http
        .get(Uri.parse('$_cdnBase/$path'),
            headers: {'User-Agent': 'IPChakra'})
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw Exception('The server config could not be downloaded.');
    }
    final wrapper = jsonDecode(r.body);
    if (wrapper is! Map<String, dynamic>) {
      throw Exception('The server config is invalid.');
    }
    final b64 = wrapper['openvpn_config_base64']?.toString() ?? '';
    if (b64.isEmpty) throw Exception('The server config is empty.');
    final bytes = base64Decode(b64);
    final expectedBytes =
        (wrapper['openvpn_config_bytes'] as num?)?.toInt() ??
            (entry['bytes'] as num?)?.toInt();
    if (expectedBytes != null &&
        expectedBytes > 0 &&
        bytes.length != expectedBytes) {
      throw Exception('The server config failed verification.');
    }
    final expectedSha = (entry['sha']?.toString().isNotEmpty ?? false)
        ? entry['sha'].toString()
        : wrapper['openvpn_config_sha256']?.toString() ?? '';
    if (expectedSha.isNotEmpty) {
      final digest = await Sha256().hash(bytes);
      final hex = digest.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      if (hex != expectedSha) {
        throw Exception('The server config failed verification.');
      }
    }
    final config = utf8.decode(bytes);
    if (!config.contains('<ca>')) {
      throw Exception('The server config is invalid.');
    }
    if (_configCache.length >= 64) _configCache.clear();
    _configCache[path] = config;
    return config;
  }

  /// Test-only: build the listable servers for compact [entries]
  /// without any network or storage.
  @visibleForTesting
  List<VpnServer> debugServers(List<Map<String, dynamic>> entries) => [
        for (final e in entries)
          poolEntryToServer(e, configFetcher: fetchConfig),
      ];
}
