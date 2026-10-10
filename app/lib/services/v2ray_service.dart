import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_server.dart';
import 'hysteria_config.dart';
import 'stealth_link.dart';
import 'vpngate_service.dart';

/// Stealth servers: free V2Ray/Xray share links (VLESS, Trojan,
/// Shadowsocks, VMess, Hysteria2) plus links the user imports by hand.
///
/// Sources (public aggregators on GitHub, updated daily):
/// - Eternity.txt — plain-text list of share links.
/// - sub_merge_base64.txt — a base64 subscription whose decoded body is
///   also a list of share links.
/// - Epodonios All_Configs_Sub.txt — plain-text list; the first source
///   that carries VLESS+Reality links in bulk.
/// - Pawdroid Free-servers sub — a base64 subscription (a plain-text
///   body is also accepted, for robustness).
///
/// Plus the private IPChakra feed (stealth.json in the IPChakra repo):
/// links Shiv publishes there are validated like any other link, tagged
/// with source 'private' and listed ahead of the public feeds. The file
/// not existing yet (HTTP 404) is a silent no-op.
///
/// Links carry their own credentials, so no separate login is needed.
/// Connections run through flutter_v2ray_client (Xray core). Servers are
/// ordered by stealth tier (Reality first) and the public feed is capped;
/// user-imported and private servers are always kept and listed first.
class V2RayService extends ChangeNotifier {
  static const _eternityUrl =
      'https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/Eternity.txt';
  static const _subMergeUrl =
      'https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/sub_merge_base64.txt';
  static const _epodoniosUrl =
      'https://raw.githubusercontent.com/Epodonios/v2ray-configs/main/All_Configs_Sub.txt';
  static const _pawdroidUrl =
      'https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub';
  static const _stealthJsonUrl =
      'https://raw.githubusercontent.com/shivytyahoo/IPChakra/main/stealth.json';
  static const _kList = 'v2ray_list';
  static const _kTime = 'v2ray_time';
  static const _kCustom = 'stealth_custom_links';
  static const _kPrivate = 'stealth_private_links';
  static const _kCacheSchema = 'v2ray_cache_schema';

  /// Schema version of the cached stealth link list. Bump this
  /// whenever the extraction rules change which links are kept.
  /// Version 3: Hysteria2 schemes are extracted and the private
  /// stealth.json feed exists. A cache written under an older schema
  /// can silently lack whole protocol families — the v2.1.0 device
  /// bug, where a list cached by v2.0.2 (whose parser rejected
  /// Hysteria2 links) was reused until it aged out and Hysteria2
  /// showed a single stray server — so a mismatched cache is
  /// discarded once and refetched.
  static const cacheSchemaVersion = 3;

  /// Whether a stored cache schema matches the current one.
  static bool cacheSchemaMatches(int? stored) =>
      stored == cacheSchemaVersion;

  /// Maximum number of feed servers kept after tier ordering.
  static const maxFeedServers = 450;

  static const _schemes = [
    'ss://',
    'vless://',
    'trojan://',
    'vmess://',
    'hysteria2://',
    'hy2://',
  ];

  List<VpnServer> servers = [];
  bool loading = false;
  String? error;

  /// Raw user-imported links, mirrored from SharedPreferences.
  List<String> _customLinks = [];

  /// Raw private-feed (stealth.json) links, mirrored from
  /// SharedPreferences.
  List<String> _privateLinks = [];

  /// Number of visible servers per stealth tier, e.g. {'Reality': 12}.
  Map<String, int> get tierCounts {
    final counts = <String, int>{};
    for (final s in servers) {
      if (s.tier.isEmpty) continue;
      counts[s.tier] = (counts[s.tier] ?? 0) + 1;
    }
    return counts;
  }

  Future<void> load({bool forceRefresh = false}) async {
    if (loading) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      _customLinks = prefs.getStringList(_kCustom) ?? [];
      _privateLinks = prefs.getStringList(_kPrivate) ?? [];
      if (!cacheSchemaMatches(prefs.getInt(_kCacheSchema))) {
        // One-time invalidation: discard the cached list and its
        // timestamp so this load must refetch. Custom and private
        // links are kept. The schema is stamped now, so a failed
        // fetch does not repeat the discard on every launch.
        await prefs.remove(_kList);
        await prefs.remove(_kTime);
        await prefs.setInt(_kCacheSchema, cacheSchemaVersion);
      }
      final lastFetch = prefs.getInt(_kTime) ?? 0;
      final stale =
          DateTime.now().millisecondsSinceEpoch - lastFetch > 12 * 3600 * 1000;

      List<String>? links;
      if (forceRefresh || stale) {
        final fetched = await _fetchAllLinks();
        if (fetched.isNotEmpty) {
          links = fetched;
          await prefs.setStringList(_kList, links);
          await prefs.setInt(
              _kTime, DateTime.now().millisecondsSinceEpoch);
        }
        // The private feed refreshes on the same cycle. Any failure
        // (including the expected 404 until the file is published)
        // keeps the cached links and stays silent.
        final privateFetched = await _fetchStealthJsonLinks();
        if (privateFetched != null) {
          _privateLinks = privateFetched;
          await prefs.setStringList(_kPrivate, _privateLinks);
        }
      }
      links ??= prefs.getStringList(_kList);
      _rebuild(links ?? const []);
      if (servers.isEmpty) {
        error = 'Could not load the stealth server list. Pull to refresh.';
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Fetch every public source and merge their links (deduplicated
  /// across all feeds by the full link string).
  Future<List<String>> _fetchAllLinks() async {
    final out = <String>{};
    out.addAll(await _fetchPlainFeed(_eternityUrl));
    out.addAll(await _fetchPlainFeed(_epodoniosUrl));
    out.addAll(await _fetchSubscriptionFeed(_subMergeUrl));
    out.addAll(await _fetchSubscriptionFeed(_pawdroidUrl));
    return out.toList();
  }

  /// One plain-text feed: a list of share links, one per line.
  Future<List<String>> _fetchPlainFeed(String url) async {
    try {
      final r = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode == 200) return _extractLinks(r.body);
    } catch (_) {
      // Other sources / the cache may still succeed.
    }
    return const [];
  }

  /// One subscription feed: the body is expected to be base64, but a
  /// plain-text body is accepted too (some mirrors serve it decoded).
  Future<List<String>> _fetchSubscriptionFeed(String url) async {
    try {
      final r = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode == 200) return _extractFromSubscriptionBody(r.body);
    } catch (_) {
      // Other sources / the cache may still succeed.
    }
    return const [];
  }

  /// Links from a subscription body: decode base64 first; when the
  /// decoded body yields nothing, fall back to reading the body as
  /// plain text.
  static List<String> _extractFromSubscriptionBody(String body) {
    final decoded = _decodeBase64Text(body);
    final fromDecoded =
        decoded == null ? const <String>[] : _extractLinks(decoded);
    if (fromDecoded.isNotEmpty) return fromDecoded;
    return _extractLinks(body);
  }

  /// Fetch the private stealth.json feed. Returns the validated links,
  /// or null when the fetch failed in any way (offline, 404, invalid
  /// JSON) so the caller keeps the cached list untouched.
  Future<List<String>?> _fetchStealthJsonLinks() async {
    try {
      final r = await http
          .get(Uri.parse(_stealthJsonUrl))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return null;
      return parseStealthJson(r.body);
    } catch (_) {
      return null;
    }
  }

  /// Parse a stealth.json document:
  /// {"version": 1, "servers": ["vless://…", …]}.
  ///
  /// Returns the entries that are valid share links (each checked with
  /// [StealthLink.parse]), deduplicated. Returns null when the body is
  /// not valid JSON or has no usable "servers" list, so callers can
  /// tell "no valid document" apart from "a valid document with no
  /// servers".
  static List<String>? parseStealthJson(String body) {
    final Object? doc;
    try {
      doc = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (doc is! Map) return null;
    final servers = doc['servers'];
    if (servers is! List) return null;
    final seen = <String>{};
    final out = <String>[];
    for (final entry in servers) {
      if (entry is! String) continue;
      final link = entry.trim();
      if (link.isEmpty || !seen.add(link)) continue;
      if (StealthLink.parse(link) == null) continue;
      out.add(link);
    }
    return out;
  }

  /// Extract valid share-link lines from a text body. A line counts when
  /// it starts with a supported scheme and [StealthLink.parse] accepts it.
  static List<String> _extractLinks(String text) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (!_schemes.any(line.startsWith)) continue;
      if (!seen.add(line)) continue;
      if (StealthLink.parse(line) == null) continue;
      out.add(line);
    }
    return out;
  }

  /// Decode a base64 / base64url body, tolerating whitespace and missing
  /// padding. Returns null when the body is not decodable base64.
  static String? _decodeBase64Text(String body) {
    try {
      var s = body.replaceAll(RegExp(r'\s'), '');
      s = s.replaceAll('-', '+').replaceAll('_', '/');
      final remainder = s.length % 4;
      if (remainder == 1) return null;
      if (remainder > 0) s = s.padRight(s.length + (4 - remainder), '=');
      return utf8.decode(base64Decode(s), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  // ── manual import ───────────────────────────────────────────────

  /// Validate and store a user-pasted share link.
  ///
  /// The link must parse with [StealthLink] AND be buildable into a
  /// configuration: Hysteria2 links are validated through the
  /// hand-built configuration path ([buildHysteria2Config]), because
  /// the Xray plugin's own parser does not know them; every other
  /// scheme must also pass the plugin's parser. On success the
  /// server is persisted, the list is rebuilt (custom servers first)
  /// and the new server is returned. Returns null on any failure.
  Future<VpnServer?> addCustomLink(String link) async {
    final trimmed = link.trim();
    if (trimmed.isEmpty) return null;
    final info = StealthLink.parse(trimmed);
    if (info == null) return null;
    if (info.scheme == 'hysteria2') {
      if (buildHysteria2Config(trimmed, const []) == null) return null;
    } else {
      try {
        V2ray.parseFromURL(trimmed);
      } catch (_) {
        return null;
      }
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_kCustom) ?? [];
      if (!stored.contains(trimmed)) {
        stored.add(trimmed);
        await prefs.setStringList(_kCustom, stored);
      }
      _customLinks = stored;
      _rebuild(prefs.getStringList(_kList) ?? const []);
      notifyListeners();
      for (final s in servers) {
        if (s.shareLink == trimmed && s.source == 'custom') return s;
      }
      return _toServer(trimmed, source: 'custom');
    } catch (_) {
      return null;
    }
  }

  /// Remove a previously imported server (matched by its share link).
  Future<void> removeCustomServer(VpnServer server) async {
    final link = server.shareLink;
    if (link == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_kCustom) ?? [];
      stored.remove(link);
      await prefs.setStringList(_kCustom, stored);
      _customLinks = stored;
      _rebuild(prefs.getStringList(_kList) ?? const []);
      notifyListeners();
    } catch (_) {
      // Nothing sensible to surface; the in-memory list stays as-is.
    }
  }

  // ── list building ───────────────────────────────────────────────

  /// Rebuild [servers]: custom servers (tier-sorted) first, then the
  /// private stealth.json servers (tier-sorted), then public feed
  /// servers (tier-sorted, capped at [maxFeedServers]). Links are
  /// deduplicated across all groups by their full string.
  void _rebuild(List<String> feedLinks) {
    final seen = <String>{};

    final custom = <VpnServer>[];
    for (final link in _customLinks) {
      if (!seen.add(link)) continue;
      final s = _toServer(link, source: 'custom');
      if (s != null) custom.add(s);
    }

    final private = <VpnServer>[];
    for (final link in _privateLinks) {
      if (!seen.add(link)) continue;
      final s = _toServer(link, source: 'private');
      if (s != null) private.add(s);
    }

    final feed = <VpnServer>[];
    for (final link in feedLinks) {
      if (!seen.add(link)) continue;
      final s = _toServer(link, source: 'v2ray');
      if (s != null) feed.add(s);
    }

    servers = [
      ..._sortByTier(custom),
      ..._sortByTier(private),
      ..._capByTier(_sortByTier(feed)),
    ];
  }

  /// Caps the feed list at [maxFeedServers] while guaranteeing every
  /// tier a share of the slots. A plain tier-sort + take() would let a
  /// flood of TLS links (the most common kind in public feeds) occupy
  /// the whole cap and starve out Shadowsocks/VMess entirely — but the
  /// Stealth Auto ladder needs every tier present. Unused quota slots
  /// are backfilled from the remaining servers in tier order, and the
  /// result stays grouped by tier for the ladder.
  static List<VpnServer> _capByTier(List<VpnServer> sorted) {
    if (sorted.length <= maxFeedServers) return sorted;
    const quotas = <String, int>{
      'Reality': 170,
      'Hysteria2': 50,
      'TLS': 100,
      'Shadowsocks': 80,
      'VMess': 50,
    };
    final byTier = <String, List<VpnServer>>{};
    for (final s in sorted) {
      byTier.putIfAbsent(s.tier, () => []).add(s);
    }
    final picked = <VpnServer>[];
    final leftovers = <VpnServer>[];
    for (final tier in quotas.keys) {
      final list = byTier[tier] ?? const <VpnServer>[];
      picked.addAll(list.take(quotas[tier]!));
      leftovers.addAll(list.skip(quotas[tier]!));
    }
    for (final entry in byTier.entries) {
      if (!quotas.containsKey(entry.key)) leftovers.addAll(entry.value);
    }
    if (picked.length < maxFeedServers) {
      picked.addAll(leftovers.take(maxFeedServers - picked.length));
    }
    return _sortByTier(picked);
  }

  /// Test-only access to the tier cap.
  @visibleForTesting
  static List<VpnServer> debugCapByTier(List<VpnServer> list) =>
      _capByTier(_sortByTier(list));

  /// Stable sort by stealth tier rank (Reality first).
  static List<VpnServer> _sortByTier(List<VpnServer> list) {
    final decorated = <(int, int, VpnServer)>[
      for (var i = 0; i < list.length; i++)
        (_tierRank(list[i].tier), i, list[i]),
    ];
    decorated.sort((a, b) {
      final byTier = a.$1.compareTo(b.$1);
      return byTier != 0 ? byTier : a.$2.compareTo(b.$2);
    });
    return [for (final e in decorated) e.$3];
  }

  static int _tierRank(String tier) {
    switch (tier) {
      case 'Reality':
        return 0;
      case 'Hysteria2':
        return 1;
      case 'TLS':
        return 2;
      case 'Shadowsocks':
        return 3;
      case 'VMess':
        return 4;
      default:
        return 4;
    }
  }

  VpnServer? _toServer(String link, {String source = 'v2ray'}) {
    final info = StealthLink.parse(link);
    if (info == null) return null;
    // Remark often looks like "CA-185.156.47.97-0424" — pull the
    // two-letter country code that precedes the first '-'.
    final codeMatch = RegExp(r'([A-Z]{2})-').firstMatch(info.remark);
    final code = codeMatch?.group(1) ?? '';
    final country = _countryName(code);
    final name =
        info.remark.isNotEmpty ? info.remark : '$country ${info.host}'.trim();
    return VpnServer(
      id: '$source-${stableLinkId(link)}',
      name: name,
      country: country,
      flag: VpnGateService.flagFor(code),
      type: source == 'custom' ? 'custom' : 'free',
      protocol: 'v2ray',
      note: 'Stealth • ${info.tier}',
      source: source,
      shareLink: link,
      tier: info.tier,
    );
  }

  static const _names = {
    'US': 'United States', 'CA': 'Canada', 'GB': 'United Kingdom',
    'DE': 'Germany', 'FR': 'France', 'NL': 'Netherlands',
    'SG': 'Singapore', 'JP': 'Japan', 'KR': 'South Korea',
    'AU': 'Australia', 'IN': 'India', 'BR': 'Brazil',
    'RU': 'Russia', 'TR': 'Turkey', 'AE': 'UAE',
    'IT': 'Italy', 'ES': 'Spain', 'PL': 'Poland',
    'SE': 'Sweden', 'CH': 'Switzerland', 'HK': 'Hong Kong',
    'TW': 'Taiwan', 'VN': 'Vietnam', 'TH': 'Thailand',
    'ID': 'Indonesia', 'MY': 'Malaysia', 'PH': 'Philippines',
    'ZA': 'South Africa', 'MX': 'Mexico', 'AR': 'Argentina',
    'CL': 'Chile', 'CO': 'Colombia', 'IR': 'Iran',
  };

  static String _countryName(String code) =>
      _names[code.toUpperCase()] ?? (code.isNotEmpty ? code : 'Unknown');

  /// Stable server id fragment for a share [link]: the FNV-1a 32-bit
  /// hash of the link's UTF-8 bytes, as zero-padded hex.
  ///
  /// This replaces String.hashCode, which Dart does not guarantee to
  /// be stable across runs — an unstable id breaks anything persisted
  /// against it (the remembered Stealth Auto winner, health results).
  /// The same link must always produce the same id, on every launch,
  /// on every device.
  static String stableLinkId(String link) {
    var hash = 0x811c9dc5; // FNV offset basis
    for (final byte in utf8.encode(link)) {
      hash ^= byte;
      hash = (hash * 0x01000193) & 0xffffffff; // FNV prime, 32-bit wrap
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// Test-only: build a feed server from a single link.
  @visibleForTesting
  VpnServer? debugToServer(String link) => _toServer(link);

  /// Test-only: build a server from a single link with an explicit
  /// source (for example 'private').
  @visibleForTesting
  VpnServer? debugToServerWithSource(String link, {required String source}) =>
      _toServer(link, source: source);

  /// Test-only: extract valid share-link lines from a text body.
  @visibleForTesting
  static List<String> debugExtractLinks(String text) => _extractLinks(text);

  /// Test-only: decode a base64 subscription body.
  @visibleForTesting
  static String? debugDecodeSubscription(String body) =>
      _decodeBase64Text(body);

  /// Test-only: links from a subscription body (base64 or plain).
  @visibleForTesting
  static List<String> debugExtractFromSubscriptionBody(String body) =>
      _extractFromSubscriptionBody(body);

  /// Test-only: parse a stealth.json document.
  @visibleForTesting
  static List<String>? debugParseStealthJson(String body) =>
      parseStealthJson(body);
}
