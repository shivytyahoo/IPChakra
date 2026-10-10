import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One free public DNS resolver the user can pick.
///
/// [tag] is one of: 'Fast', 'Ad blocking', 'Family',
/// 'Malware blocking', 'Unfiltered'. [note] is a short region or
/// behaviour note shown under the addresses.
class DnsProvider {
  final String id;
  final String name;
  final String tag;
  final String primary;
  final String? secondary;
  final String note;

  const DnsProvider({
    required this.id,
    required this.name,
    required this.tag,
    required this.primary,
    this.secondary,
    this.note = '',
  });

  /// The DNS server addresses to apply, primary first.
  List<String> get servers => [primary, ?secondary];

  /// "1.1.1.1 / 1.0.0.1" style display string.
  String get displayServers =>
      secondary == null ? primary : '$primary / $secondary';
}

/// Selectable public DNS providers, a real per-provider speed test,
/// and helpers to apply the choice to VPN tunnel configurations.
///
/// Every address below was verified against the provider's own
/// documentation before being shipped (October 2026). One requested
/// provider is deliberately absent: Mullvad's public DNS answers
/// DNS-over-HTTPS/TLS only — its documentation states the IPs do not
/// serve plain DNS over UDP/TCP port 53, which is what VPN tunnel
/// configs (and this speed test) use, so it could never work here.
///
/// The selection persists in SharedPreferences under
/// [DnsService.prefsKey] and is read at connect time, so changing it
/// needs no restart — the next connection uses the new resolver.
class DnsService extends ChangeNotifier {
  static const prefsKey = 'dns_provider_id';
  static const defaultProviderId = 'cloudflare';

  /// Hostname resolved by the speed test. A benign, universally
  /// allowed name, so filtering resolvers answer it too.
  static const testHostname = 'example.com';

  /// Per-provider timeout for the speed test.
  static const testTimeout = Duration(milliseconds: 1200);

  /// The curated provider list, default first.
  static const providers = <DnsProvider>[
    DnsProvider(
      id: 'cloudflare',
      name: 'Cloudflare',
      tag: 'Fast',
      primary: '1.1.1.1',
      secondary: '1.0.0.1',
      note: 'Fast and private, global anycast',
    ),
    DnsProvider(
      id: 'cloudflare-malware',
      name: 'Cloudflare Malware Blocking',
      tag: 'Malware blocking',
      primary: '1.1.1.2',
      secondary: '1.0.0.2',
      note: 'Blocks malware domains only',
    ),
    DnsProvider(
      id: 'cloudflare-family',
      name: 'Cloudflare Family',
      tag: 'Family',
      primary: '1.1.1.3',
      secondary: '1.0.0.3',
      note: 'Blocks malware and adult content',
    ),
    DnsProvider(
      id: 'google',
      name: 'Google Public DNS',
      tag: 'Fast',
      primary: '8.8.8.8',
      secondary: '8.8.4.4',
      note: 'Global anycast, no filtering',
    ),
    DnsProvider(
      id: 'quad9',
      name: 'Quad9',
      tag: 'Malware blocking',
      primary: '9.9.9.9',
      secondary: '149.112.112.112',
      note: 'Blocks malicious domains, privacy-first',
    ),
    DnsProvider(
      id: 'quad9-unfiltered',
      name: 'Quad9 Unfiltered',
      tag: 'Unfiltered',
      primary: '9.9.9.10',
      secondary: '149.112.112.10',
      note: 'No blocking of any kind',
    ),
    DnsProvider(
      id: 'opendns',
      name: 'OpenDNS',
      tag: 'Unfiltered',
      primary: '208.67.222.222',
      secondary: '208.67.220.220',
      note: 'Cisco OpenDNS, global anycast',
    ),
    DnsProvider(
      id: 'opendns-family',
      name: 'OpenDNS Family Shield',
      tag: 'Family',
      primary: '208.67.222.123',
      secondary: '208.67.220.123',
      note: 'Pre-configured adult content blocking',
    ),
    DnsProvider(
      id: 'adguard',
      name: 'AdGuard DNS',
      tag: 'Ad blocking',
      primary: '94.140.14.14',
      secondary: '94.140.15.15',
      note: 'Blocks ads, trackers and phishing',
    ),
    DnsProvider(
      id: 'adguard-unfiltered',
      name: 'AdGuard Unfiltered',
      tag: 'Unfiltered',
      primary: '94.140.14.140',
      secondary: '94.140.14.141',
      note: 'No blocking of any kind',
    ),
    DnsProvider(
      id: 'adguard-family',
      name: 'AdGuard Family',
      tag: 'Family',
      primary: '94.140.14.15',
      secondary: '94.140.15.16',
      note: 'Ads, trackers, adult content, safe search',
    ),
    DnsProvider(
      id: 'controld-unfiltered',
      name: 'Control D Unfiltered',
      tag: 'Unfiltered',
      primary: '76.76.2.0',
      secondary: '76.76.10.0',
      note: 'No blocking, no query logging',
    ),
    DnsProvider(
      id: 'controld-ads',
      name: 'Control D Malware + Ads',
      tag: 'Ad blocking',
      primary: '76.76.2.2',
      secondary: '76.76.10.2',
      note: 'Blocks malware, trackers and ads',
    ),
    DnsProvider(
      id: 'cleanbrowsing-family',
      name: 'CleanBrowsing Family',
      tag: 'Family',
      primary: '185.228.168.168',
      secondary: '185.228.169.168',
      note: 'Strictest filter, enforces SafeSearch',
    ),
    DnsProvider(
      id: 'cleanbrowsing-adult',
      name: 'CleanBrowsing Adult Filter',
      tag: 'Family',
      primary: '185.228.168.10',
      secondary: '185.228.169.11',
      note: 'Blocks adult content and security threats',
    ),
    DnsProvider(
      id: 'cleanbrowsing-security',
      name: 'CleanBrowsing Security',
      tag: 'Malware blocking',
      primary: '185.228.168.9',
      secondary: '185.228.169.9',
      note: 'Malware, phishing and cryptomining only',
    ),
    DnsProvider(
      id: 'alternate-dns',
      name: 'Alternate DNS',
      tag: 'Ad blocking',
      primary: '76.76.19.19',
      secondary: '76.223.122.150',
      note: 'Blocks ads network-wide',
    ),
    DnsProvider(
      id: 'dnswatch',
      name: 'DNS.WATCH',
      tag: 'Unfiltered',
      primary: '84.200.69.80',
      secondary: '84.200.70.40',
      note: 'Uncensored, no logging, Germany',
    ),
    DnsProvider(
      id: 'verisign',
      name: 'Verisign',
      tag: 'Unfiltered',
      primary: '64.6.64.6',
      secondary: '64.6.65.6',
      note: 'Stability-focused, no filtering',
    ),
    DnsProvider(
      id: 'comodo',
      name: 'Comodo Secure DNS',
      tag: 'Malware blocking',
      primary: '8.26.56.26',
      secondary: '8.20.247.20',
      note: 'Blocks malicious and phishing sites',
    ),
    DnsProvider(
      id: 'yandex-basic',
      name: 'Yandex Basic',
      tag: 'Unfiltered',
      primary: '77.88.8.8',
      secondary: '77.88.8.1',
      note: 'Russia / CIS, no filtering',
    ),
    DnsProvider(
      id: 'yandex-family',
      name: 'Yandex Family',
      tag: 'Family',
      primary: '77.88.8.7',
      secondary: '77.88.8.3',
      note: 'Russia / CIS, blocks adult content',
    ),
    DnsProvider(
      id: 'uncensoreddns',
      name: 'UncensoredDNS',
      tag: 'Unfiltered',
      primary: '91.239.100.100',
      secondary: '89.233.43.71',
      note: 'Anti-censorship, Denmark',
    ),
    DnsProvider(
      id: 'safedns',
      name: 'SafeDNS',
      tag: 'Family',
      primary: '195.46.39.39',
      secondary: '195.46.39.40',
      note: 'Filtering resolver, global anycast',
    ),
    DnsProvider(
      id: 'quad101',
      name: 'Quad101',
      tag: 'Unfiltered',
      primary: '101.101.101.101',
      secondary: '101.102.103.104',
      note: 'TWNIC, Taiwan',
    ),
    DnsProvider(
      id: 'alidns',
      name: 'AliDNS',
      tag: 'Fast',
      primary: '223.5.5.5',
      secondary: '223.6.6.6',
      note: 'Alibaba, China anycast',
    ),
    DnsProvider(
      id: 'dns114',
      name: '114DNS',
      tag: 'Unfiltered',
      primary: '114.114.114.114',
      secondary: '114.114.115.115',
      note: 'China public resolver',
    ),
  ];

  /// Id of the built-in "default DNS" choice (see [defaultDns]).
  static const defaultDnsId = 'dns-default';

  /// The built-in default-DNS choice: not a selectable provider and
  /// deliberately NOT part of the [providers] catalogue (so it can
  /// never be picked in Settings or returned by a speed ranking).
  /// It names the last-resort DNS treatment a stealth connect falls
  /// back to when neither the selected provider nor any measured
  /// provider works with the chosen server: the configuration is
  /// handed to the V2Ray core with NO custom DNS object at all (see
  /// [defaultDnsConfig]), and the plugin's own default treatment
  /// applies — resolvers 1.1.1.1 / 8.8.8.8 on the tunnel interface
  /// and in the core, resolved the default way. The record exists so
  /// the attempt, its verification (which probes the primary
  /// default resolver through the tunnel) and the status display
  /// can all name the choice exactly like any provider.
  static const DnsProvider defaultDns = DnsProvider(
    id: defaultDnsId,
    name: 'Default DNS',
    tag: 'Default',
    primary: '1.1.1.1',
    secondary: '8.8.8.8',
    note: 'Built-in resolver defaults, no custom DNS',
  );

  /// Whether [provider] is the built-in default-DNS choice.
  static bool isDefaultDns(DnsProvider provider) =>
      provider.id == defaultDnsId;

  /// Look a provider up by [id]; unknown ids fall back to the default.
  static DnsProvider byId(String? id) {
    for (final p in providers) {
      if (p.id == id) return p;
    }
    return providers.firstWhere((p) => p.id == defaultProviderId);
  }

  /// Read the persisted selection without needing a service instance.
  /// Used by the VPN controller at connect time.
  static Future<DnsProvider> loadSelected() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return byId(prefs.getString(prefsKey));
    } catch (_) {
      return byId(null);
    }
  }

  DnsProvider _selected = byId(null);

  /// The currently selected provider.
  DnsProvider get selected => _selected;

  /// providerId -> measured round-trip time in milliseconds.
  /// A null value after a test run means the provider timed out.
  final Map<String, int?> results = {};

  bool testing = false;
  bool _testRunDone = false;

  /// True once at least one full speed test has completed.
  bool get hasResults => _testRunDone;

  /// Load the persisted selection (Cloudflare when nothing is stored).
  Future<void> load() async {
    _selected = await loadSelected();
    notifyListeners();
  }

  /// Select [provider] and persist the choice.
  Future<void> select(DnsProvider provider) async {
    _selected = provider;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, provider.id);
    } catch (_) {
      // The in-memory selection still applies for this session.
    }
  }

  /// Providers in display order: catalogue order normally, measured
  /// fastest-first after a speed test (timeouts, then untested, last).
  List<DnsProvider> get displayProviders {
    if (!_testRunDone) return providers;
    // Rank 0: answered (by speed, ascending). Rank 1: timed out.
    // Rank 2: not measured. Original order breaks all ties.
    final decorated = <(int, int, int, DnsProvider)>[
      for (var i = 0; i < providers.length; i++)
        (
          !results.containsKey(providers[i].id)
              ? 2
              : (results[providers[i].id] == null ? 1 : 0),
          results[providers[i].id] ?? 1 << 30,
          i,
          providers[i],
        ),
    ];
    decorated.sort((a, b) {
      final byRank = a.$1.compareTo(b.$1);
      if (byRank != 0) return byRank;
      final bySpeed = a.$2.compareTo(b.$2);
      if (bySpeed != 0) return bySpeed;
      return a.$3.compareTo(b.$3);
    });
    return [for (final e in decorated) e.$4];
  }

  /// Measure every provider's real DNS response time in parallel and
  /// record the results (null = timeout).
  Future<void> testAll() async {
    if (testing) return;
    testing = true;
    notifyListeners();
    try {
      results
        ..clear()
        ..addAll(await measureAllProviders());
      _testRunDone = true;
    } finally {
      testing = false;
      notifyListeners();
    }
  }

  /// Measure every provider in parallel (provider id -> round-trip
  /// milliseconds, null = no answer). Static so the VPN controller
  /// can rank providers at connect time without a service instance.
  static Future<Map<String, int?>> measureAllProviders() async {
    final measured = await Future.wait(
      providers.map((p) async => MapEntry(p.id, await measureProvider(p))),
    );
    return Map.fromEntries(measured);
  }

  /// Measure one provider: send a real A query for [testHostname] to
  /// its primary address over UDP/53 and time the matching response.
  /// Returns the round-trip time in milliseconds, or null when no
  /// valid response arrives within [testTimeout].
  Future<int?> measure(DnsProvider provider) => measureProvider(provider);

  /// Static core of [measure], shared by the settings speed test and
  /// the connect-time provider ranking.
  static Future<int?> measureProvider(DnsProvider provider) async {
    RawDatagramSocket? socket;
    StreamSubscription<RawSocketEvent>? sub;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final server = InternetAddress(provider.primary);
      final id = Random().nextInt(0x10000);
      final query = buildAQuery(testHostname, id);
      final done = Completer<int?>();
      final watch = Stopwatch()..start();
      sub = socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          final datagram = socket!.receive();
          if (datagram == null) return;
          if (datagram.address != server) return;
          if (!isValidResponse(datagram.data, id)) return;
          watch.stop();
          if (!done.isCompleted) done.complete(watch.elapsedMilliseconds);
        },
        onError: (_) {
          // A socket error (for example the send being refused on
          // this network) is delivered on the stream, outside the
          // try/catch. It simply means "no answer": swallow it and
          // let the timeout below return null instead of leaking an
          // unhandled async error.
        },
      );
      socket.send(query, server, 53);
      return await done.future.timeout(
        testTimeout,
        onTimeout: () => null,
      );
    } catch (_) {
      return null;
    } finally {
      await sub?.cancel();
      socket?.close();
    }
  }

  /// Build a minimal DNS query packet: an A-record query for
  /// [hostname] with 16-bit transaction [id] and the RD flag set.
  /// Pure function — unit-tested.
  static Uint8List buildAQuery(String hostname, int id) {
    final labels =
        hostname.split('.').where((part) => part.isNotEmpty).toList();
    var qnameLength = 1; // terminating root label
    for (final label in labels) {
      qnameLength += 1 + label.length;
    }
    final packet = Uint8List(12 + qnameLength + 4);
    final data = ByteData.view(packet.buffer);
    data.setUint16(0, id & 0xffff);
    data.setUint16(2, 0x0100); // RD (recursion desired)
    data.setUint16(4, 1); // QDCOUNT = 1
    var offset = 12;
    for (final label in labels) {
      packet[offset++] = label.length;
      for (final unit in label.codeUnits) {
        packet[offset++] = unit;
      }
    }
    packet[offset++] = 0; // root label
    data.setUint16(offset, 1); // QTYPE = A
    data.setUint16(offset + 2, 1); // QCLASS = IN
    return packet;
  }

  /// True when [packet] is a DNS response (QR bit set) echoing the
  /// transaction [id] we sent. Pure function — unit-tested.
  static bool isValidResponse(Uint8List packet, int id) {
    if (packet.length < 12) return false;
    final data =
        ByteData.view(packet.buffer, packet.offsetInBytes, packet.length);
    if (data.getUint16(0) != (id & 0xffff)) return false;
    final flags = data.getUint16(2);
    return (flags & 0x8000) != 0; // QR bit: message is a response
  }

  /// Inject [servers] into an Xray JSON configuration as its
  /// top-level `"dns"` object, replacing any existing one. The object
  /// also pins `"queryStrategy": "UseIPv4"` — the same preference the
  /// V2Ray plugin's Android wrapper adds when it is missing, made
  /// explicit here so the effective configuration is identical on
  /// every code path. Returns the re-encoded configuration. When the
  /// input is not a JSON object the original string is returned
  /// unchanged, so a malformed config can never break a connect.
  /// Pure function — unit-tested.
  static String injectDnsServers(String configJson, List<String> servers) {
    if (servers.isEmpty) return configJson;
    try {
      final decoded = jsonDecode(configJson);
      if (decoded is! Map<String, dynamic>) return configJson;
      decoded['dns'] = dnsObject(servers);
      return jsonEncode(decoded);
    } catch (_) {
      return configJson;
    }
  }

  /// The `"dns"` object every stealth configuration carries.
  static Map<String, dynamic> dnsObject(List<String> servers) => {
        'servers': servers,
        'queryStrategy': 'UseIPv4',
      };

  /// The routing rule every stealth configuration carries for DNS.
  ///
  /// Why this exact rule exists: the V2Ray plugin's Android wrapper
  /// inspects the configuration before starting, and when it finds NO
  /// routing rule that sends port 853 to the direct outbound, it
  /// prepends its own rules forcing ALL port 53/853 traffic (and the
  /// Cloudflare/Google resolver addresses) out the direct connection
  /// — DNS then bypasses the tunnel completely and is exercised over
  /// the phone's raw connection, where an ISP or router that filters
  /// port 53 (or one resolver in particular) silently kills browsing
  /// while the tunnel itself is healthy. Carrying this rule tells
  /// the wrapper the configuration already handles DNS, so nothing is
  /// prepended: DNS-over-TLS (853) still goes direct, while plain
  /// DNS (port 53) follows the default route — through the tunnel,
  /// where the selected resolver is reachable from the exit node.
  static Map<String, dynamic> dnsRoutingRule() => {
        'type': 'field',
        'port': '853',
        'outboundTag': 'direct',
      };

  /// Strip the app's DNS treatment from a stealth Xray
  /// configuration, producing the "default DNS" variant used by the
  /// last-resort (Tier-3) connect attempt: the top-level `"dns"`
  /// object is removed and the app-added port-853 routing rule
  /// ([dnsRoutingRule]) is removed with it.
  ///
  /// What remains is exactly what the core and plugin do by
  /// default. The plugin's Android wrapper, finding no `"dns"`
  /// object, sets the tunnel interface DNS servers to its built-in
  /// defaults (1.1.1.1, 8.8.8.8) and fills the core's DNS object
  /// with the same servers plus its own default routing — the
  /// treatment every tunnel received before this app had a DNS
  /// feature at all. No resolver address is invented here; the
  /// removal is the whole change. When the input is not a JSON
  /// object the original string is returned unchanged, so a
  /// malformed config can never break a connect. Pure function —
  /// unit-tested.
  static String defaultDnsConfig(String configJson) {
    try {
      final decoded = jsonDecode(configJson);
      if (decoded is! Map<String, dynamic>) return configJson;
      decoded.remove('dns');
      final routing = decoded['routing'];
      if (routing is Map<String, dynamic>) {
        final rules = routing['rules'];
        if (rules is List) {
          routing['rules'] = rules
              .where((r) => !(r is Map &&
                  r['outboundTag'] == 'direct' &&
                  '${r['port']}' == '853'))
              .toList();
        }
      }
      return jsonEncode(decoded);
    } catch (_) {
      return configJson;
    }
  }

  /// Apply the app's DNS treatment to a stealth Xray configuration:
  /// the `"dns"` object from [injectDnsServers] plus the routing
  /// rule from [dnsRoutingRule] (appended when not already present).
  /// Every stealth scheme goes through this one helper, so the DNS
  /// behaviour is identical for plugin-parsed and hand-built
  /// configurations. Pure function — unit-tested.
  static String applyStealthDns(String configJson, List<String> servers) {
    if (servers.isEmpty) return configJson;
    final withDns = injectDnsServers(configJson, servers);
    if (withDns == configJson) return configJson; // not a JSON object
    try {
      final decoded = jsonDecode(withDns);
      if (decoded is! Map<String, dynamic>) return configJson;
      final routing = decoded['routing'];
      final routingMap = routing is Map<String, dynamic>
          ? routing
          : <String, dynamic>{'domainStrategy': 'UseIp'};
      final rules = routingMap['rules'];
      final ruleList = rules is List ? List<dynamic>.from(rules) : <dynamic>[];
      final hasRule = ruleList.any(
        (r) =>
            r is Map &&
            r['outboundTag'] == 'direct' &&
            '${r['port']}'.contains('853'),
      );
      if (!hasRule) ruleList.add(dnsRoutingRule());
      routingMap['rules'] = ruleList;
      decoded['routing'] = routingMap;
      return jsonEncode(decoded);
    } catch (_) {
      return configJson;
    }
  }
}
