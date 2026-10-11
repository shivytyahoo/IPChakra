import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_server.dart';
import 'country_table.dart';
import 'hysteria_config.dart';
import 'stealth_link.dart';

/// One share link from a public feed, together with the key of the
/// feed that supplied it ('snsub', 'au1rxx', 'epodonios', …). The
/// attribution is what the server list shows as the server's source,
/// and it survives the on-disk cache so a cached list attributes
/// exactly like a freshly fetched one.
class StealthFeedLink {
  final String link;
  final String source;
  const StealthFeedLink(this.link, this.source);
}

/// A user-added subscription: their own name for it (which doubles
/// as the source label on its servers) and the URL it is fetched
/// from. The user supplies both — IPChakra ships no subscription
/// URLs of its own.
class StealthSubscription {
  final String name;
  final String url;
  const StealthSubscription({required this.name, required this.url});

  Map<String, dynamic> toJson() => {'name': name, 'url': url};

  static StealthSubscription? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final url = raw['url'];
    if (name is! String || url is! String) return null;
    if (name.isEmpty || url.isEmpty) return null;
    return StealthSubscription(name: name, url: url);
  }
}

/// Traffic/expiry figures from a subscription's
/// `subscription-userinfo` response header, e.g.
/// `upload=1024; download=2048; total=107374182400; expire=1893456000`.
/// Every field is optional: providers send what they send, and the
/// app displays only what actually arrived — nothing is invented.
class SubscriptionUserinfo {
  final int? uploadBytes;
  final int? downloadBytes;
  final int? totalBytes;
  final int? expireEpochSeconds;

  const SubscriptionUserinfo({
    this.uploadBytes,
    this.downloadBytes,
    this.totalBytes,
    this.expireEpochSeconds,
  });

  /// Upload + download, when at least one of them was reported.
  int? get usedBytes {
    if (uploadBytes == null && downloadBytes == null) return null;
    return (uploadBytes ?? 0) + (downloadBytes ?? 0);
  }

  bool get isEmpty =>
      uploadBytes == null &&
      downloadBytes == null &&
      totalBytes == null &&
      expireEpochSeconds == null;

  /// Parse a `subscription-userinfo` header value. Returns null
  /// when the header is absent or carries no usable figure.
  static SubscriptionUserinfo? parse(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    int? field(String key) {
      for (final part in header.split(';')) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        if (part.substring(0, eq).trim().toLowerCase() != key) continue;
        return int.tryParse(part.substring(eq + 1).trim());
      }
      return null;
    }

    final info = SubscriptionUserinfo(
      uploadBytes: field('upload'),
      downloadBytes: field('download'),
      totalBytes: field('total'),
      expireEpochSeconds: field('expire'),
    );
    return info.isEmpty ? null : info;
  }

  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// One honest line for the subscription's row, e.g.
  /// "12.4 GB of 100 GB used • Expires 5 Dec 2026". Only the parts
  /// the header actually carried appear; empty when there is
  /// nothing to say.
  String describe() {
    final parts = <String>[];
    final used = usedBytes;
    if (totalBytes != null && used != null) {
      parts.add('${formatBytes(used)} of ${formatBytes(totalBytes!)} used');
    } else if (used != null) {
      parts.add('${formatBytes(used)} used');
    }
    final expire = expireEpochSeconds;
    if (expire != null) {
      final d = DateTime.fromMillisecondsSinceEpoch(expire * 1000);
      parts.add('Expires ${d.day} ${_monthNames[d.month - 1]} ${d.year}');
    }
    return parts.join(' • ');
  }

  /// "1.5 GB"-style formatting for a byte count.
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB', 'TB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    final text = value >= 100
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '${text.endsWith('.0') ? text.substring(0, text.length - 2) : text} '
        '${units[unit]}';
  }

  Map<String, dynamic> toJson() => {
        if (uploadBytes != null) 'upload': uploadBytes,
        if (downloadBytes != null) 'download': downloadBytes,
        if (totalBytes != null) 'total': totalBytes,
        if (expireEpochSeconds != null) 'expire': expireEpochSeconds,
      };

  static SubscriptionUserinfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    int? field(String key) {
      final v = raw[key];
      return v is num ? v.toInt() : null;
    }

    final info = SubscriptionUserinfo(
      uploadBytes: field('upload'),
      downloadBytes: field('download'),
      totalBytes: field('total'),
      expireEpochSeconds: field('expire'),
    );
    return info.isEmpty ? null : info;
  }
}

/// The last-known refresh outcome for one subscription: the
/// userinfo from its latest successful fetch and when the latest
/// success/failure happened. Persisted so the row can keep showing
/// honest state across launches.
class SubscriptionStatus {
  final SubscriptionUserinfo? userinfo;
  final DateTime? lastSuccess;
  final DateTime? lastFailure;

  const SubscriptionStatus({this.userinfo, this.lastSuccess, this.lastFailure});

  /// True when the most recent refresh attempt failed (or every
  /// attempt so far has) — the UI notes "last refresh failed" and
  /// the pool keeps serving the last good links.
  bool get refreshFailed =>
      lastFailure != null &&
      (lastSuccess == null || lastFailure!.isAfter(lastSuccess!));

  SubscriptionStatus copyWith({
    SubscriptionUserinfo? userinfo,
    DateTime? lastSuccess,
    DateTime? lastFailure,
  }) {
    return SubscriptionStatus(
      userinfo: userinfo ?? this.userinfo,
      lastSuccess: lastSuccess ?? this.lastSuccess,
      lastFailure: lastFailure ?? this.lastFailure,
    );
  }

  Map<String, dynamic> toJson() => {
        if (userinfo != null) 'userinfo': userinfo!.toJson(),
        if (lastSuccess != null)
          'lastSuccess': lastSuccess!.millisecondsSinceEpoch,
        if (lastFailure != null)
          'lastFailure': lastFailure!.millisecondsSinceEpoch,
      };

  static SubscriptionStatus fromJson(Object? raw) {
    if (raw is! Map) return const SubscriptionStatus();
    DateTime? stamp(String key) {
      final v = raw[key];
      return v is num
          ? DateTime.fromMillisecondsSinceEpoch(v.toInt())
          : null;
    }

    return SubscriptionStatus(
      userinfo: SubscriptionUserinfo.fromJson(raw['userinfo']),
      lastSuccess: stamp('lastSuccess'),
      lastFailure: stamp('lastFailure'),
    );
  }
}

/// Stealth servers: free V2Ray/Xray share links (VLESS, Trojan,
/// Shadowsocks, VMess, Hysteria2) plus links the user imports by hand.
///
/// Sources (public aggregators on GitHub, updated daily). The feeds
/// are merged in the order listed here, and that order is also the
/// attribution and selection priority: a link found in several feeds
/// is credited to the earliest one, and when the per-tier quotas
/// compete, earlier sources win the slots.
/// - sNSub best59 — a base64 subscription of nodes the operator
///   live-tests with Xray-core every few hours (pre-tested).
/// - Au1rxx v2ray-base64 — a base64 subscription whose nodes the
///   operator publishes only after real HTTP traffic passed through
///   them (pre-tested).
/// - Epodonios All_Configs_Sub.txt — plain-text list; the first source
///   that carries VLESS+Reality links in bulk.
/// - Eternity.txt — plain-text list of share links.
/// - sub_merge_base64.txt — a base64 subscription whose decoded body
///   is also a list of share links.
/// - Pawdroid Free-servers sub — a base64 subscription (a plain-text
///   body is also accepted, for robustness).
/// - MatinGhanbari v2ray-configs — per-protocol base64 subscription
///   files (VLESS, Hysteria2, VMess, Trojan, Shadowsocks).
/// - NoMoreWalls list_raw.txt — plain-text list from the largest
///   community aggregator (its base64 twin carries the same links).
/// - Barry-Far All_Configs_Sub.txt — plain-text list; a large
///   collection with heavy server-level overlap with Epodonios, so
///   exact-link deduplication decides what is new.
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
  static const _snsubUrl =
      'https://raw.githubusercontent.com/3000S-HTTP/sNSub/main/output/best59_base64.txt';
  static const _au1rxxUrl =
      'https://raw.githubusercontent.com/Au1rxx/free-vpn-subscriptions/main/output/v2ray-base64.txt';
  static const _matinBaseUrl =
      'https://raw.githubusercontent.com/MatinGhanbari/v2ray-configs/main/subscriptions/filtered/subs';
  static const _noMoreWallsUrl =
      'https://raw.githubusercontent.com/peasoft/NoMoreWalls/master/list_raw.txt';
  static const _barryFarUrl =
      'https://raw.githubusercontent.com/barry-far/V2ray-config/main/All_Configs_Sub.txt';
  static const _stealthJsonUrl =
      'https://raw.githubusercontent.com/shivytyahoo/IPChakra/main/stealth.json';

  /// The public feeds, in merge order (which is also the attribution
  /// and quota-selection priority — see the class doc). Each entry is
  /// a source key, its URLs, and whether the bodies are base64
  /// subscriptions (true) or plain-text link lists (false).
  /// MatinGhanbari publishes one subscription file per protocol, so
  /// it contributes five URLs under one source.
  static const _feeds = <(String, List<String>, bool)>[
    ('snsub', [_snsubUrl], true),
    ('au1rxx', [_au1rxxUrl], true),
    ('epodonios', [_epodoniosUrl], false),
    ('eternity', [_eternityUrl], false),
    ('submerge', [_subMergeUrl], true),
    ('pawdroid', [_pawdroidUrl], true),
    (
      'matin',
      [
        '$_matinBaseUrl/vless.txt',
        '$_matinBaseUrl/hysteria2.txt',
        '$_matinBaseUrl/vmess.txt',
        '$_matinBaseUrl/trojan.txt',
        '$_matinBaseUrl/ss.txt',
      ],
      true,
    ),
    ('nomorewalls', [_noMoreWallsUrl], false),
    ('barryfar', [_barryFarUrl], false),
  ];
  static const _kList = 'v2ray_list';
  static const _kTime = 'v2ray_time';
  static const _kCustom = 'stealth_custom_links';
  static const _kPrivate = 'stealth_private_links';
  static const _kSubscriptions = 'stealth_subscriptions';
  static const _kSubLinks = 'stealth_sub_links';
  static const _kSubStatus = 'stealth_sub_status';
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
  /// Version 4: five new public feeds (sNSub, Au1rxx, MatinGhanbari,
  /// NoMoreWalls, Barry-Far), every cached link now carries its feed
  /// attribution, and the pool cap grew to 600. A version 3 cache
  /// holds bare, unattributed links from the old four feeds only, so
  /// it is discarded once and refetched.
  static const cacheSchemaVersion = 4;

  /// Whether a stored cache schema matches the current one.
  static bool cacheSchemaMatches(int? stored) =>
      stored == cacheSchemaVersion;

  /// Maximum number of feed servers kept after tier ordering.
  static const maxFeedServers = 600;

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

  // ── user subscriptions (v2.3.1) ─────────────────────────────────

  /// The user's subscriptions, in the order they were added. Their
  /// names double as source labels, so they are validated against
  /// every built-in source key at add time.
  List<StealthSubscription> subscriptions = [];

  /// The last good link list per subscription URL.
  final Map<String, List<String>> _subLinks = {};

  /// The last refresh outcome per subscription name.
  final Map<String, SubscriptionStatus> _subStatus = {};

  /// The status of one subscription, or an empty status when it
  /// has never been refreshed (or does not exist).
  SubscriptionStatus statusOf(String name) =>
      _subStatus[name] ?? const SubscriptionStatus();

  /// How many visible servers one subscription currently supplies.
  int subscriptionServerCount(String name) =>
      servers.where((s) => s.source == name).length;

  /// Names a subscription may not take: every source key the app
  /// itself uses, so a subscription can never impersonate (or be
  /// confused with) a built-in source in the list.
  static final Set<String> _reservedSourceNames = {
    'custom',
    'private',
    'v2ray',
    'warp',
    'vpngate',
    'vpnbook',
    'mirror',
    'chakra',
    for (final feed in _feeds) feed.$1,
  };

  /// Test seam: when set, subscription fetches go through this
  /// function instead of the network (flutter_test's HttpClient
  /// answers 400 for everything, which would make the real path
  /// untestable). Production always leaves it null.
  @visibleForTesting
  Future<({List<String> links, SubscriptionUserinfo? userinfo})?> Function(
      String url)? debugSubscriptionFetcher;

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
      _loadSubscriptions(prefs);
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

      List<StealthFeedLink>? links;
      if (forceRefresh || stale) {
        final fetched = await _fetchAllLinks();
        if (fetched.isNotEmpty) {
          links = fetched;
          await prefs.setString(_kList, encodeCachedFeedLinks(links));
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
        // User subscriptions refresh on the same cycle too. Each
        // is independent: a failure keeps that subscription's last
        // good links and is noted on its own row only — it can
        // never break the built-in pool.
        for (final sub in subscriptions) {
          await _refreshOneSubscription(sub);
        }
        if (subscriptions.isNotEmpty) await _persistSubscriptions();
      }
      links ??= _cachedFeedLinks(prefs);
      _rebuild(links);
      if (servers.isEmpty) {
        error = 'Could not load the stealth server list. Pull to refresh.';
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// Fetch every public source and merge their links (deduplicated
  /// across all feeds by the full link string, attributed to the
  /// earliest feed in [_feeds] order that carried the link). A feed
  /// that fails or yields nothing contributes nothing — the other
  /// feeds and the cache are unaffected.
  Future<List<StealthFeedLink>> _fetchAllLinks() async {
    final perFeed = <(String, List<String>)>[];
    for (final (source, urls, subscription) in _feeds) {
      final links = <String>[];
      for (final url in urls) {
        links.addAll(subscription
            ? await _fetchSubscriptionFeed(url)
            : await _fetchPlainFeed(url));
      }
      perFeed.add((source, links));
    }
    return mergeFeedLinks(perFeed);
  }

  /// Merge per-feed link lists into one attributed list. [feeds] is
  /// in priority order: the first feed to carry a link owns its
  /// attribution, and the merged order (which the tier cap later
  /// picks from) follows that same priority.
  static List<StealthFeedLink> mergeFeedLinks(
      List<(String, List<String>)> feeds) {
    final seen = <String>{};
    final out = <StealthFeedLink>[];
    for (final (source, links) in feeds) {
      for (final link in links) {
        if (seen.add(link)) out.add(StealthFeedLink(link, source));
      }
    }
    return out;
  }

  /// Serialize the attributed feed list for the cache: a JSON array
  /// of [link, source] pairs.
  static String encodeCachedFeedLinks(List<StealthFeedLink> links) =>
      jsonEncode([for (final l in links) [l.link, l.source]]);

  /// The attributed feed list from the cache, or an empty list when
  /// there is none. Never throws: a pre-v4 cache stores a bare
  /// string list under the same key, and reading that as a string
  /// throws — it is treated as "no cache" here, and the schema
  /// check in [load] discards it so the next load refetches.
  List<StealthFeedLink> _cachedFeedLinks(SharedPreferences prefs) {
    try {
      return decodeCachedFeedLinks(prefs.getString(_kList));
    } catch (_) {
      return const [];
    }
  }

  /// Parse a cached feed list written by [encodeCachedFeedLinks].
  /// Any malformed content yields an empty list, never a throw.
  static List<StealthFeedLink> decodeCachedFeedLinks(String? raw) {
    if (raw == null) return const [];
    try {
      final doc = jsonDecode(raw);
      if (doc is! List) return const [];
      final out = <StealthFeedLink>[];
      for (final entry in doc) {
        if (entry is List &&
            entry.length == 2 &&
            entry[0] is String &&
            entry[1] is String) {
          out.add(StealthFeedLink(entry[0] as String, entry[1] as String));
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
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
      _rebuild(_cachedFeedLinks(prefs));
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
      _rebuild(_cachedFeedLinks(prefs));
      notifyListeners();
    } catch (_) {
      // Nothing sensible to surface; the in-memory list stays as-is.
    }
  }

  // ── user subscriptions ──────────────────────────────────────────

  /// Read the persisted subscriptions, their cached links and
  /// their refresh statuses into memory. Tolerant by construction:
  /// any malformed piece is treated as absent, never as an error.
  void _loadSubscriptions(SharedPreferences prefs) {
    subscriptions = [];
    _subLinks.clear();
    _subStatus.clear();
    try {
      final rawSubs = prefs.getString(_kSubscriptions);
      if (rawSubs != null) {
        final doc = jsonDecode(rawSubs);
        if (doc is List) {
          for (final entry in doc) {
            final sub = StealthSubscription.fromJson(entry);
            if (sub != null &&
                !subscriptions.any((s) => s.name == sub.name)) {
              subscriptions.add(sub);
            }
          }
        }
      }
      final rawLinks = prefs.getString(_kSubLinks);
      if (rawLinks != null) {
        final doc = jsonDecode(rawLinks);
        if (doc is Map) {
          for (final entry in doc.entries) {
            final value = entry.value;
            if (entry.key is String && value is List) {
              _subLinks[entry.key as String] =
                  value.whereType<String>().toList();
            }
          }
        }
      }
      final rawStatus = prefs.getString(_kSubStatus);
      if (rawStatus != null) {
        final doc = jsonDecode(rawStatus);
        if (doc is Map) {
          for (final entry in doc.entries) {
            if (entry.key is String) {
              _subStatus[entry.key as String] =
                  SubscriptionStatus.fromJson(entry.value);
            }
          }
        }
      }
    } catch (_) {
      // A corrupt store leaves the lists empty; the built-in pool
      // is unaffected either way.
    }
  }

  /// Persist the subscriptions, their cached links and statuses.
  Future<void> _persistSubscriptions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kSubscriptions,
      jsonEncode([for (final s in subscriptions) s.toJson()]),
    );
    await prefs.setString(_kSubLinks, jsonEncode(_subLinks));
    await prefs.setString(
      _kSubStatus,
      jsonEncode({
        for (final e in _subStatus.entries) e.key: e.value.toJson(),
      }),
    );
  }

  /// Fetch one subscription URL through the same machinery as the
  /// built-in subscription feeds (plain + base64 auto-detect, Xray
  /// link parsing), plus its `subscription-userinfo` header.
  /// Returns null on any failure (network, non-200).
  Future<({List<String> links, SubscriptionUserinfo? userinfo})?>
      _fetchSubscriptionUrl(String url) async {
    final seam = debugSubscriptionFetcher;
    if (seam != null) return seam(url);
    try {
      final r = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (r.statusCode != 200) return null;
      return (
        links: _extractFromSubscriptionBody(r.body),
        userinfo: SubscriptionUserinfo.parse(
          r.headers['subscription-userinfo'],
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// Refresh one subscription in place. Success replaces its links
  /// (and userinfo, when the response carried one) and stamps the
  /// success time. Failure — including a fetch that yields no links
  /// while a last good list exists — keeps the old links and stamps
  /// the failure, mirroring how the built-in feeds treat their
  /// cache. Never throws.
  Future<void> _refreshOneSubscription(StealthSubscription sub) async {
    final previous = _subStatus[sub.name] ?? const SubscriptionStatus();
    final result = await _fetchSubscriptionUrl(sub.url);
    if (result == null ||
        (result.links.isEmpty && (_subLinks[sub.url]?.isNotEmpty ?? false))) {
      _subStatus[sub.name] =
          previous.copyWith(lastFailure: DateTime.now());
      return;
    }
    _subLinks[sub.url] = result.links;
    _subStatus[sub.name] = SubscriptionStatus(
      userinfo: result.userinfo ?? previous.userinfo,
      lastSuccess: DateTime.now(),
      lastFailure: previous.lastFailure,
    );
  }

  /// Add a user subscription and fetch it immediately. Returns null
  /// on success, or a user-facing error string explaining what was
  /// wrong with the name or URL. A fetch that fails at add time is
  /// NOT an error here: the subscription is stored, its row shows
  /// the refresh-failure note, and the next refresh cycle retries —
  /// exactly like a built-in feed being unreachable.
  Future<String?> addSubscription({
    required String name,
    required String url,
  }) async {
    final trimmedName = name.trim();
    final trimmedUrl = url.trim();
    if (trimmedName.isEmpty) return 'Give the subscription a name.';
    if (trimmedName.length > 40) {
      return 'That name is too long (40 characters maximum).';
    }
    if (_reservedSourceNames.contains(trimmedName.toLowerCase())) {
      return 'That name is reserved for a built-in source. '
          'Please pick another.';
    }
    if (subscriptions
        .any((s) => s.name.toLowerCase() == trimmedName.toLowerCase())) {
      return 'A subscription with that name already exists.';
    }
    final uri = Uri.tryParse(trimmedUrl);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return 'That does not look like a valid subscription URL.';
    }
    if (subscriptions.any((s) => s.url == trimmedUrl)) {
      return 'That subscription URL has already been added.';
    }
    final sub = StealthSubscription(name: trimmedName, url: trimmedUrl);
    subscriptions = [...subscriptions, sub];
    try {
      await _persistSubscriptions();
      await _refreshOneSubscription(sub);
      await _persistSubscriptions();
      final prefs = await SharedPreferences.getInstance();
      _rebuild(_cachedFeedLinks(prefs));
    } catch (_) {
      subscriptions =
          subscriptions.where((s) => s.name != trimmedName).toList();
      return 'The subscription could not be saved. Please try again.';
    }
    notifyListeners();
    return null;
  }

  /// Remove a subscription by name. Its servers leave the pool
  /// immediately (the rebuild runs now, not at the next refresh).
  Future<void> removeSubscription(String name) async {
    StealthSubscription? sub;
    for (final s in subscriptions) {
      if (s.name == name) sub = s;
    }
    if (sub == null) return;
    subscriptions = subscriptions.where((s) => s.name != name).toList();
    _subLinks.remove(sub.url);
    _subStatus.remove(name);
    try {
      await _persistSubscriptions();
      final prefs = await SharedPreferences.getInstance();
      _rebuild(_cachedFeedLinks(prefs));
    } catch (_) {
      // The in-memory state is already correct for this session.
    }
    notifyListeners();
  }

  // ── list building ───────────────────────────────────────────────

  /// Rebuild [servers]: custom servers (tier-sorted) first, then the
  /// private stealth.json servers (tier-sorted), then the user's
  /// subscriptions (each tier-sorted, in the order added), then
  /// public feed servers (tier-sorted, capped at [maxFeedServers]).
  /// Links are deduplicated across all groups by their full string;
  /// a feed server keeps the source of the feed that supplied its
  /// link, and a subscription server keeps the subscription's name.
  void _rebuild(List<StealthFeedLink> feedLinks) {
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

    // The user's own subscriptions sit between the private feed
    // and the public feeds: they are the user's chosen source, so
    // they are never capped away, and their name is their label.
    final fromSubscriptions = <VpnServer>[];
    for (final sub in subscriptions) {
      final group = <VpnServer>[];
      for (final link in _subLinks[sub.url] ?? const <String>[]) {
        if (!seen.add(link)) continue;
        final s = _toServer(link, source: sub.name);
        if (s != null) group.add(s);
      }
      fromSubscriptions.addAll(_sortByTier(group));
    }

    final feed = <VpnServer>[];
    for (final feedLink in feedLinks) {
      if (!seen.add(feedLink.link)) continue;
      final s = _toServer(feedLink.link, source: feedLink.source);
      if (s != null) feed.add(s);
    }

    servers = [
      ..._sortByTier(custom),
      ..._sortByTier(private),
      ...fromSubscriptions,
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
    // v2.3.0 quotas (cap 600). The floors are deliberate: Reality
    // never drops below 175 and Hysteria2 never below 45 of the
    // shipped pool, no matter how the feeds flood the other tiers.
    // Within a tier, slots are taken in merged-feed order, so the
    // pre-tested sources (sNSub, Au1rxx) are picked first — with one
    // v2.3.3 refinement: servers whose country is known are picked
    // before servers whose remark states no country. The list is
    // grouped by country, and two of the largest feeds publish no
    // country metadata at all (Au1rxx remarks are programmatic ids,
    // Epodonios remarks are just the brand); letting them fill the
    // quotas first shipped a pool that was 600/600 "Unknown" on
    // 2026-10-11 — no country groups at all. Known-country servers
    // (in the same merged-feed order) now take each tier's slots
    // first; anonymous servers still fill whatever remains and the
    // backfill, so no tier or source is ever excluded.
    const quotas = <String, int>{
      'Reality': 200,
      'Hysteria2': 60,
      'TLS': 150,
      'Shadowsocks': 110,
      'VMess': 80,
    };
    final byTier = <String, List<VpnServer>>{};
    for (final s in sorted) {
      byTier.putIfAbsent(s.tier, () => []).add(s);
    }
    final picked = <VpnServer>[];
    final leftovers = <VpnServer>[];
    for (final tier in quotas.keys) {
      final list = byTier[tier] ?? const <VpnServer>[];
      // Endpoint diversity first: some feeds publish many links
      // that are mere credential/parameter variants of one server
      // (same host and port). A quota slot should buy a distinct
      // server before it buys a second variant of one already in,
      // so variants only fill a tier once its distinct endpoints
      // run out (and otherwise wait in the backfill like the rest).
      final seenEndpoints = <String>{};
      var taken = 0;

      // One picking pass over [candidates]: distinct endpoints up
      // to the quota, then endpoint variants while slots remain;
      // the overflow waits in the backfill.
      void pickFrom(List<VpnServer> candidates) {
        final variants = <VpnServer>[];
        for (final s in candidates) {
          if (taken >= quotas[tier]!) {
            leftovers.add(s);
            continue;
          }
          final info =
              s.shareLink == null ? null : StealthLink.parse(s.shareLink!);
          final endpoint =
              info == null ? s.id : '${info.host}:${info.port}';
          if (seenEndpoints.add(endpoint)) {
            picked.add(s);
            taken++;
          } else {
            variants.add(s);
          }
        }
        for (final s in variants) {
          if (taken >= quotas[tier]!) {
            leftovers.add(s);
          } else {
            picked.add(s);
            taken++;
          }
        }
      }

      pickFrom([
        for (final s in list)
          if (s.country != 'Unknown' && s.country.isNotEmpty) s,
      ]);
      pickFrom([
        for (final s in list)
          if (s.country == 'Unknown' || s.country.isEmpty) s,
      ]);
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
    // The country lives only in the remark, written in whichever
    // convention the feed chose (flag emoji, ISO code token,
    // English or Chinese name). countryCodeFromRemark reads all of
    // them and validates against the full ISO table; a remark that
    // states no country honestly stays 'Unknown'.
    final code = countryCodeFromRemark(info.remark) ?? '';
    final country =
        code.isEmpty ? 'Unknown' : (countryNameForCode(code) ?? 'Unknown');
    final name =
        info.remark.isNotEmpty ? info.remark : '$country ${info.host}'.trim();
    return VpnServer(
      id: '$source-${stableLinkId(link)}',
      name: name,
      country: country,
      flag: code.isEmpty ? '🌐' : flagEmojiForCode(code),
      type: source == 'custom' ? 'custom' : 'free',
      protocol: 'v2ray',
      note: 'Stealth • ${info.tier}',
      source: source,
      shareLink: link,
      tier: info.tier,
    );
  }

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

  /// Test-only: merge per-feed link lists with attribution.
  @visibleForTesting
  static List<StealthFeedLink> debugMergeFeedLinks(
          List<(String, List<String>)> feeds) =>
      mergeFeedLinks(feeds);

  /// Test-only: serialize the attributed feed list for the cache.
  @visibleForTesting
  static String debugEncodeCachedFeedLinks(List<StealthFeedLink> links) =>
      encodeCachedFeedLinks(links);

  /// Test-only: parse a cached attributed feed list.
  @visibleForTesting
  static List<StealthFeedLink> debugDecodeCachedFeedLinks(String? raw) =>
      decodeCachedFeedLinks(raw);
}
