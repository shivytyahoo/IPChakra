import 'dart:convert';

import 'stealth_link.dart';

/// Builds a complete Xray configuration for a Hysteria2 share link.
///
/// The V2Ray plugin's own URL parsers produce configs whose overall
/// shape this builder mirrors exactly — the same log block, the same
/// socks inbound (tag 'in_proxy', port 10807), the same helper
/// outbounds ('direct' freedom, 'blackhole') and the same routing
/// defaults — with the proxy outbound replaced by a Hysteria2 one.
/// The plugin's Android wrapper injects its own TUN inbound into
/// whatever config it is handed, so this shape is all it needs.
///
/// The Hysteria2 outbound mapping follows the Xray documentation:
///   outbound.settings       { version: 2, address, port }
///   streamSettings.network  'hysteria', security 'tls'
///   tlsSettings             { serverName, alpn: ['h3'],
///                             pinnedPeerCertSha256 }
///   hysteriaSettings        { version: 2, auth, udpIdleTimeout }
///   finalmask.udp[]         salamander obfuscation (from obfs /
///                           obfs-password), finalmask.quicParams
///                           .udpHop for port hopping (mport)
///
/// One deliberate omission: tlsSettings.allowInsecure is NEVER
/// emitted. The Xray core generation bundled with the plugin (and
/// every current desktop release) has removed that feature —
/// a config carrying "allowInsecure": true fails to load at all
/// ("The feature \"allowInsecure\" has been removed"), which would
/// take every Hysteria2 server down with it, not just the insecure
/// ones. A link's pinSHA256 is passed through instead: pinning is
/// the core's supported way to trust a self-signed server
/// certificate. Links that ask for insecure=1 without a pin keep
/// full certificate verification, exactly as the core mandates.
///
/// Pure function of the link text and the DNS server list — no
/// Flutter, no I/O — so it is unit-tested directly and can be driven
/// from a plain Dart script for validation against the desktop
/// Xray binary. Returns null when [link] is not a valid Hysteria2
/// share link.
String? buildHysteria2Config(String link, List<String> dnsServers) {
  final info = StealthLink.parse(link);
  if (info == null || info.scheme != 'hysteria2') return null;

  final tlsSettings = <String, dynamic>{
    'serverName': info.sni ?? info.host,
    'alpn': info.alpn ?? const ['h3'],
    if (info.pinSha256 != null) 'pinnedPeerCertSha256': info.pinSha256,
  };
  // The core only accepts udpIdleTimeout in the range 2..600
  // seconds; an out-of-range link value falls back to the core
  // default (60) instead of failing the whole config.
  final idle = info.udpIdleTimeout;
  final hysteriaSettings = <String, dynamic>{
    'version': 2,
    'auth': info.auth,
    if (idle != null && idle >= 2 && idle <= 600) 'udpIdleTimeout': idle,
  };
  final streamSettings = <String, dynamic>{
    'network': 'hysteria',
    'security': 'tls',
    'tlsSettings': tlsSettings,
    'hysteriaSettings': hysteriaSettings,
  };
  final finalmask = _buildFinalmask(info);
  if (finalmask != null) streamSettings['finalmask'] = finalmask;

  final config = <String, dynamic>{
    'log': {
      'access': '',
      'error': '',
      'loglevel': 'error',
      'dnsLog': false,
    },
    'inbounds': [
      {
        'tag': 'in_proxy',
        'port': 10807,
        'protocol': 'socks',
        'listen': '127.0.0.1',
        'settings': {'auth': 'noauth', 'udp': true, 'userLevel': 8},
        'sniffing': {'enabled': false},
      },
    ],
    'outbounds': [
      {
        'tag': 'proxy',
        'protocol': 'hysteria',
        'settings': {'version': 2, 'address': info.host, 'port': info.port},
        'streamSettings': streamSettings,
        'mux': {'enabled': false},
      },
      {
        'tag': 'direct',
        'protocol': 'freedom',
        'streamSettings': {
          'sockopt': {'domainStrategy': 'UseIP'},
        },
      },
      {'tag': 'blackhole', 'protocol': 'blackhole'},
    ],
    // The same DNS treatment the plugin-parsed configurations get
    // from DnsService.applyStealthDns: the dns object (with the
    // UseIPv4 query strategy) and the port-853 routing rule that
    // keeps plain DNS inside the tunnel (see dns_service.dart for
    // why that rule matters). The controller additionally runs the
    // built configuration through applyStealthDns, which recognises
    // both pieces and leaves them as they are.
    'dns': {
      'servers': dnsServers.isEmpty
          ? const ['8.8.8.8', '8.8.4.4']
          : dnsServers,
      'queryStrategy': 'UseIPv4',
    },
    'routing': {
      'domainStrategy': 'UseIp',
      'rules': [
        {'type': 'field', 'port': '853', 'outboundTag': 'direct'},
      ],
    },
  };
  return jsonEncode(config);
}

/// The streamSettings.finalmask object for [info], or null when the
/// link needs no masking (no fm parameter, no salamander obfs, no
/// port hopping).
///
/// An explicit fm parameter is the base object (it already is a full
/// FinalMask). The standard obfs=salamander + obfs-password pair is
/// folded in as a udp salamander mask when the base does not already
/// carry one, and port hopping lands in quicParams.udpHop.
Map<String, dynamic>? _buildFinalmask(StealthLinkInfo info) {
  Map<String, dynamic>? mask;
  if (info.finalmask != null) {
    mask = Map<String, dynamic>.from(info.finalmask!);
  }

  if (info.obfsType == 'salamander') {
    mask ??= <String, dynamic>{};
    final udp = mask['udp'];
    final hasSalamander = udp is List &&
        udp.any((e) => e is Map && e['type'] == 'salamander');
    if (!hasSalamander) {
      final entries = udp is List ? List<dynamic>.from(udp) : <dynamic>[];
      entries.add({
        'type': 'salamander',
        'settings': {'password': info.obfsPassword ?? ''},
      });
      mask['udp'] = entries;
    }
  }

  final hop = info.portHop;
  if (hop != null && hop.isNotEmpty) {
    mask ??= <String, dynamic>{};
    final existing = mask['quicParams'];
    final quicParams = existing is Map
        ? Map<String, dynamic>.from(existing)
        : <String, dynamic>{};
    quicParams['udpHop'] = {'ports': hop, 'interval': '30'};
    mask['quicParams'] = quicParams;
  }

  return (mask == null || mask.isEmpty) ? null : mask;
}
