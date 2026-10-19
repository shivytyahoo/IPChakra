import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'counting_dns.dart';
import 'dns_service.dart';

/// Parse the bundled hosts JSON into its map form. Top-level so it
/// can run in a background isolate via [compute] — see
/// [AdShieldService._loadLists]. A non-object payload yields an
/// empty map (sessions then simply carry no list-based blocking).
Map<String, String> _parseHostsJson(String text) {
  final decoded = jsonDecode(text);
  if (decoded is! Map) return const {};
  return Map<String, String>.fromEntries(
    decoded.entries.map(
      (e) => MapEntry(e.key.toString(), e.value.toString()),
    ),
  );
}

/// AdShield embedded: ad-blocking at the VPN tunnel's DNS, with no
/// local socket and no second VPN profile.
///
/// Why this shape: Android allows only ONE VpnService at a time and
/// IPChakra already owns it (WireGuard / OpenVPN / V2Ray), and
/// stock Android forbids binding ports below 1024 — so an in-app
/// filter cannot answer DNS on port 53 the way the standalone
/// AdShield (a full VpnService of its own) does. Instead the
/// blocking moves into the tunnel configurations themselves:
///
/// - **V2Ray / Xray:** the bundled domain list (~218k entries,
///   generated from the standalone AdShield v0.6.1 EXTREME lists by
///   tools/gen_adshield_xray.py) is injected into the core's DNS
///   as `dns.hosts` entries (`"domain:<d>": "0.0.0.0"`), a `dns`
///   protocol outbound (`dns-out`) is added, and two routing rules
///   steer lookups: app DNS on port 53 goes to `dns-out` (whose
///   internal DNS consults `hosts` first and forwards the rest to
///   the attempt's upstream servers), while the internal client's
///   own upstream queries — tagged with the dns object's tag —
///   ride the proxy tunnel instead of looping back into `dns-out`.
///   See [injectXrayHosts]; it covers the Tier-3 default-DNS
///   attempt too (a stripped config gets a fresh dns object).
/// - **WireGuard / OpenVPN:** the tunnel's DNS is switched to an
///   ad-blocking public provider (see [adBlockingServers]) — the
///   provider does the filtering; the app's list cannot be
///   injected into those engines.
///
/// There is deliberately NO live blocked-query counter: nothing in
/// this architecture can measure it, and the UI must never show a
/// number it cannot prove. The Home card instead shows the
/// bundled list's size from [meta.json] — the number of ad domains
/// blocked at DNS for V2Ray sessions.
///
/// Lifecycle: [init] loads the persisted switch, then the bundled
/// lists in the background (startup never stalls). The switch
/// applies to the NEXT connection — repointing a live tunnel's DNS
/// is not possible without reconnecting.
class AdShieldService extends ChangeNotifier {
  static const prefsKey = 'adshield_enabled';

  static const _assetHosts = 'assets/adshield/xray_hosts.json';
  static const _assetMeta = 'assets/adshield/meta.json';

  /// Tag given to the dns object when the config has none, and to
  /// the dns-protocol outbound every injected config carries.
  static const dnsTag = 'adshield-dns';
  static const dnsOutboundTag = 'dns-out';

  bool _enabled = true;

  /// The user's switch: AdShield applies to the next VPN session.
  bool get enabled => _enabled;

  /// The bundled hosts map (`domain:<d>` -> `0.0.0.0`), loaded in
  /// the background. Empty until the asset finishes loading.
  Map<String, String> _hosts = const {};
  Map<String, String> get hosts => _hosts;

  /// Domains in the bundled list, from meta.json (0 until loaded).
  int _domainCount = 0;
  int get domainCount => _domainCount;

  /// List provenance, e.g. "AdShield v0.6.1 EXTREME".
  String _source = '';
  String get source => _source;

  /// Whether the bundled lists have finished loading.
  bool _listsLoaded = false;
  bool get listsLoaded => _listsLoaded;

  // ── Live counting (Stealth sessions only) ─────────────────────
  //
  // The counting forwarder (see counting_dns.dart) IS the session's
  // DNS upstream for stealth connects, so its counters are real
  // measurements, not estimates. WireGuard/OpenVPN sessions never
  // pass DNS through the app and keep no counters — the UI says so
  // instead of showing invented numbers.

  CountingDnsForwarder? _forwarder;

  /// DNS queries the forwarder has received this session.
  int sessionQueries = 0;

  /// Of those, how many it answered from the blocklist.
  int sessionBlocked = 0;

  /// Whether the forwarder is live for the current session.
  bool get countingActive => _forwarder?.running ?? false;

  Timer? _counterNotifyTimer;

  /// Start (or re-point) the counting forwarder for a stealth
  /// attempt whose upstream resolvers are [upstreams]. Returns the
  /// loopback port the Xray config must use as its only DNS
  /// server, or null when counting could not start — the caller
  /// then falls back to the hosts-injection treatment.
  ///
  /// A fresh session (forwarder not running) resets the counters;
  /// re-pointing a running forwarder (the connect ladder's next
  /// attempt) only updates its upstreams, so a session's counts
  /// survive its own DNS escalation.
  Future<int?> startCounting(List<String> upstreams) async {
    if (_hosts.isEmpty) return null; // nothing to count against yet
    var forwarder = _forwarder;
    if (forwarder == null || !forwarder.running) {
      sessionQueries = 0;
      sessionBlocked = 0;
      forwarder = CountingDnsForwarder(
        hosts: _hosts,
        onQuery: () {
          sessionQueries++;
          _notifyCounter();
        },
        onBlocked: () {
          sessionBlocked++;
          _notifyCounter();
        },
      );
      _forwarder = forwarder;
    }
    final port = await forwarder.start(upstreams);
    if (port == null) {
      _forwarder = null;
      return null;
    }
    forwarder.updateUpstreams(upstreams);
    notifyListeners();
    return port;
  }

  /// Stop the forwarder (the session ended). The counters stay as
  /// they are — the card keeps showing the finished session's real
  /// totals until the next session starts counting.
  Future<void> stopCounting() async {
    final forwarder = _forwarder;
    _forwarder = null;
    await forwarder?.stop();
    notifyListeners();
  }

  /// Counter changes can arrive many times a second while the user
  /// browses; the card needs at most two refreshes a second.
  void _notifyCounter() {
    if (_counterNotifyTimer?.isActive ?? false) return;
    _counterNotifyTimer = Timer(const Duration(milliseconds: 500), () {
      notifyListeners();
    });
  }

  /// Load the persisted switch state, then the bundled lists in
  /// the background — startup never waits for an ~8 MB asset.
  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(prefsKey) ?? true;
      notifyListeners();
    } catch (_) {
      // The default (on) still applies for this launch.
    }
    unawaited(_loadLists());
  }

  /// Persist the user's switch. The change applies to the NEXT
  /// connection: repointing a live tunnel's DNS is not possible
  /// without reconnecting.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKey, value);
    } catch (_) {
      // The in-memory switch still applies for this launch.
    }
  }

  Future<void> _loadLists() async {
    try {
      final text = await rootBundle.loadString(_assetHosts);
      // The bundled list is ~8 MB of JSON: decoding it and building
      // the ~218k-entry map on the UI isolate would stall the app
      // shortly after launch, worst on low-end phones — so the
      // parse runs in a background isolate (the same rule the
      // OpenVPN pool index parse follows).
      _hosts = await compute(_parseHostsJson, text);
    } catch (_) {
      // The hosts stay empty; sessions still connect with normal
      // DNS behaviour — never break DNS to keep blocking on.
    }
    try {
      final text = await rootBundle.loadString(_assetMeta);
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final n = decoded['domains'];
        _domainCount = n is num ? n.toInt() : _hosts.length;
        final s = decoded['source'];
        if (s != null) _source = s.toString();
      } else {
        _domainCount = _hosts.length;
      }
    } catch (_) {
      _domainCount = _hosts.length;
    }
    _listsLoaded = true;
    notifyListeners();
  }

  // ── pure config transforms (unit-tested) ─────────────────────

  /// Inject the AdShield hosts into a stealth Xray configuration.
  ///
  /// What changes, in order:
  /// 1. The `dns` object is ensured (created with [serversFallback]
  ///    and `queryStrategy: UseIPv4` when missing, as on the Tier-3
  ///    default-DNS attempt); an existing `dns.tag` is preserved,
  ///    otherwise it becomes [dnsTag].
  /// 2. `dns.hosts` is set to [hosts] — the same map reference,
  ///    never mutated afterwards.
  /// 3. A `{"protocol": "dns", "tag": "dns-out"}` outbound is added
  ///    when not already present (matched by tag).
  /// 4. Three routing rules are front-inserted (deduped by exact
  ///    shape, so applying twice changes nothing), ordered so the
  ///    DNS plumbing cannot loop:
  ///    - `inboundTag: [<dns tag>]` + loopback destination ->
  ///      direct: the internal DNS client's queries to a loopback
  ///      upstream (the counting forwarder) stay on the device.
  ///    - `inboundTag: [<dns tag>]` -> the first outbound (the
  ///      main proxy): its queries to real upstreams ride the
  ///      tunnel instead of looping into dns-out.
  ///    - `port: 53` from the TUN inbound only -> `dns-out`: app
  ///      DNS through the TUN hits the internal DNS, which
  ///      consults `hosts` (AdShield list -> 0.0.0.0) and forwards
  ///      the rest upstream. Scoped to the TUN so SOCKS-inbound
  ///      sessions (the counting forwarder's own relays) are
  ///      never captured by it.
  /// 5. [DnsService.dnsRoutingRule] (port 853 -> direct) is ensured
  ///    once, so the plugin wrapper does not prepend its own DNS
  ///    rules that would bypass the tunnel.
  ///
  /// A non-JSON-object input, or any failure, returns the input
  /// unchanged — a connect can never break on this injection.
  static String injectXrayHosts(
    String configJson,
    Map<String, String> hosts, {
    List<String> serversFallback = const ['1.1.1.1', '8.8.8.8'],
    int? countingPort,
  }) {
    try {
      final decoded = jsonDecode(configJson);
      if (decoded is! Map<String, dynamic>) return configJson;

      final dns = decoded['dns'];
      final dnsMap = dns is Map<String, dynamic>
          ? dns
          : <String, dynamic>{
              'servers': serversFallback,
              'queryStrategy': 'UseIPv4',
            };
      if (dns is! Map<String, dynamic>) decoded['dns'] = dnsMap;
      if (dnsMap['tag'] == null) dnsMap['tag'] = dnsTag;
      final routeTag = dnsMap['tag'].toString();
      if (countingPort != null) {
        // Counting mode: the forwarder owns the blocklist (it must
        // SEE every query to count it — a hosts entry would be
        // answered inside the core and never counted). The core's
        // only upstream becomes the forwarder on loopback.
        dnsMap.remove('hosts');
        dnsMap['servers'] = [
          {'address': '127.0.0.1', 'port': countingPort},
        ];
      } else {
        dnsMap['hosts'] = hosts;
      }

      final outbounds = decoded['outbounds'];
      final outboundList =
          outbounds is List ? outbounds : <dynamic>[];
      if (outbounds is! List) decoded['outbounds'] = outboundList;
      final hasDnsOut = outboundList.any((o) =>
          o is Map && o['protocol'] == 'dns' && o['tag'] == dnsOutboundTag);
      if (!hasDnsOut) {
        outboundList.add({'protocol': 'dns', 'tag': dnsOutboundTag});
      }
      var firstProxy = 'proxy';
      if (outboundList.isNotEmpty && outboundList.first is Map) {
        final tag = (outboundList.first as Map)['tag'];
        if (tag != null && tag.toString().isNotEmpty) {
          firstProxy = tag.toString();
        }
      }

      final routing = decoded['routing'];
      final routingMap = routing is Map<String, dynamic>
          ? routing
          : <String, dynamic>{};
      if (routing is! Map<String, dynamic>) {
        decoded['routing'] = routingMap;
      }
      final rules = routingMap['rules'];
      final ruleList =
          rules is List ? List<dynamic>.from(rules) : <dynamic>[];

      // Front-insert in reverse so the final order is
      // [DNS-client loopback rule, DNS-client proxy rule,
      // port-53 rule, ...existing]. The order is what keeps the
      // DNS plumbing loop-free:
      // - The internal DNS client's own queries to a loopback
      //   upstream (the counting forwarder) go DIRECT. Routed
      //   into the tunnel instead, they land on the server's own
      //   loopback and die — and every lookup dies with them.
      // - Its queries to real upstreams ride the proxy.
      // - App DNS (port 53) goes to dns-out, but ONLY from the
      //   TUN inbound: unscoped, the rule also captured the
      //   counting forwarder's own relay sessions (they enter
      //   through the SOCKS inbound asking for a resolver on port
      //   53) and looped them back into the internal DNS — with
      //   AdShield on, no name ever resolved.
      _frontInsertRule(ruleList, {
        'type': 'field',
        'port': '53',
        'inboundTag': ['tun'],
        'outboundTag': dnsOutboundTag,
      });
      _frontInsertRule(ruleList, {
        'type': 'field',
        'inboundTag': [routeTag],
        'outboundTag': firstProxy,
      });
      _frontInsertRule(ruleList, {
        'type': 'field',
        'inboundTag': [routeTag],
        'ip': ['127.0.0.0/8'],
        'outboundTag': 'direct',
      });

      // The port-853 rule (DoT stays direct) must exist exactly
      // once; applyStealthDns may already have appended it.
      final has853 = ruleList.any((r) =>
          r is Map &&
          r['outboundTag'] == 'direct' &&
          '${r['port']}' == '853');
      if (!has853) ruleList.add(DnsService.dnsRoutingRule());

      routingMap['rules'] = ruleList;
      return jsonEncode(decoded);
    } catch (_) {
      return configJson;
    }
  }

  /// Insert [rule] at the front of [rules] unless an exactly
  /// equivalent rule (same type, tags, ports) is already present.
  static void _frontInsertRule(List<dynamic> rules, Map<String, dynamic> rule) {
    final duplicate = rules.any((r) => r is Map && _sameRule(r, rule));
    if (!duplicate) rules.insert(0, rule);
  }

  /// Whether two routing rules have the same matching shape: same
  /// type, same inbound/outbound tags and same port list.
  static bool _sameRule(Map a, Map b) {
    if (a['type'] != b['type']) return false;
    if ('${a['outboundTag']}' != '${b['outboundTag']}') return false;
    if ('${a['inboundTag'] ?? ''}' != '${b['inboundTag'] ?? ''}') {
      // inboundTag is a list; compare element-wise as strings.
      final ai = a['inboundTag'];
      final bi = b['inboundTag'];
      if (ai is List && bi is List) {
        if (ai.length != bi.length) return false;
        for (var i = 0; i < ai.length; i++) {
          if ('${ai[i]}' != '${bi[i]}') return false;
        }
      } else {
        return false;
      }
    }
    if ('${a['port'] ?? ''}' != '${b['port'] ?? ''}') return false;
    // The ip list distinguishes the DNS client's loopback rule
    // from its proxy rule (same tags, different destinations).
    final aIp = a['ip'];
    final bIp = b['ip'];
    if (aIp is List && bIp is List) {
      if (aIp.length != bIp.length) return false;
      for (var i = 0; i < aIp.length; i++) {
        if ('${aIp[i]}' != '${bIp[i]}') return false;
      }
    } else if ('${aIp ?? ''}' != '${bIp ?? ''}') {
      return false;
    }
    return true;
  }

  /// The ad-blocking DNS provider for a session: [selected] itself
  /// when its tag is already 'Ad blocking', otherwise the first
  /// 'Ad blocking' provider in the catalogue (AdGuard DNS). When
  /// the catalogue carries none, [selected] is returned — the
  /// session then keeps the user's own choice rather than breaking.
  static DnsProvider adBlockingProvider(DnsProvider selected) =>
      _adBlockingProvider(DnsService.providers, selected);

  /// The resolver addresses [adBlockingProvider] resolves to.
  static List<String> adBlockingServers(DnsProvider selected) =>
      adBlockingProvider(selected).servers;

  static DnsProvider _adBlockingProvider(
    List<DnsProvider> catalogue,
    DnsProvider selected,
  ) {
    if (selected.tag == 'Ad blocking') return selected;
    return catalogue.firstWhere(
      (p) => p.tag == 'Ad blocking',
      orElse: () => selected,
    );
  }

  /// Test-only seam for the catalogue lookup with a
  /// caller-supplied list (the built-in catalogue always carries
  /// 'Ad blocking' providers, so the no-provider fallback is only
  /// reachable this way).
  @visibleForTesting
  static DnsProvider debugAdBlockingProvider(
    List<DnsProvider> catalogue,
    DnsProvider selected,
  ) =>
      _adBlockingProvider(catalogue, selected);
}
