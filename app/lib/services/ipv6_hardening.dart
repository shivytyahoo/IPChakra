import 'dart:convert';

/// IPv6 leak hardening at the configuration-generation level, one
/// helper per engine. The honest scope: these helpers shape the
/// configurations the app itself generates or wraps, so IPv6
/// traffic is either carried inside the tunnel or has no way
/// around it. They cannot change operating-system behaviour — the
/// system-wide guarantee remains Android's "Block connections
/// without VPN" lockdown (see the Settings privacy section).

/// The AllowedIPs value every WireGuard configuration this app
/// generates carries. `::/0` alongside `0.0.0.0/0` means IPv6 is
/// routed into the tunnel exactly like IPv4: with an interface
/// IPv6 address (a dual-stack WARP identity) it is tunnelled end
/// to end; without one, IPv6 packets enter the tunnel and die
/// there instead of leaving over the phone's native IPv6, which
/// is what a v4-only AllowedIPs silently allowed before.
const String kWireGuardAllowedIps = '0.0.0.0/0, ::/0';

/// Add OpenVPN's `block-ipv6` directive to a configuration the
/// app is about to hand to the plugin. The bundled OpenVPN core
/// (ics-openvpn) implements the directive: while the tunnel is up,
/// IPv6 is blocked outright instead of bypassing an IPv4-only
/// tunnel — the classic silent leak with VPNGate-style configs,
/// which rarely push a working IPv6 route. Idempotent: a config
/// that already carries the directive (any casing) is returned
/// unchanged. Pure — unit-tested.
String hardenOpenVpnConfig(String config) {
  final hasBlock = RegExp(
    r'^\s*block-ipv6\b',
    multiLine: true,
    caseSensitive: false,
  ).hasMatch(config);
  if (hasBlock) return config;
  return '# IPChakra: block IPv6 so it cannot bypass the tunnel.\n'
      'block-ipv6\n'
      '$config';
}

/// Point an OpenVPN configuration at an ad-blocking DNS provider
/// (AdShield, v2.3.4 rework): strip any `dhcp-option DNS` lines the
/// config already carries (server-bundled or previously injected),
/// then add a `pull-filter` that ignores server-pushed DNS options
/// and one `dhcp-option DNS <ip>` per address in [servers]. Without
/// the pull-filter, a server pushing its own DNS would silently
/// route name resolution around the override. `dhcp-option DNS6`
/// lines are not the filter's business and are left alone.
/// Idempotent: applying twice leaves exactly one copy of each added
/// line. Pure — unit-tested.
String applyAdShieldOpenVpnDns(String config, List<String> servers) {
  final kept = <String>[];
  for (final line in config.split('\n')) {
    final t = line.trimLeft();
    // Our own previously added lines are re-added below, exactly
    // once — this keeps the transform idempotent.
    if (t.startsWith('# IPChakra: AdShield')) continue;
    if (RegExp(r'^dhcp-option\s+DNS\b', caseSensitive: false)
        .hasMatch(t)) {
      continue; // re-added below, exactly once
    }
    if (RegExp(r'^pull-filter\s+ignore\s+"dhcp-option DNS"',
            caseSensitive: false)
        .hasMatch(t)) {
      continue; // re-added below, exactly once
    }
    kept.add(line);
  }
  final buf = StringBuffer(kept.join('\n'));
  if (!buf.toString().endsWith('\n')) buf.writeln();
  buf.writeln(
      '# IPChakra: AdShield DNS — the tunnel uses an ad-blocking '
      'DNS provider.');
  buf.writeln('pull-filter ignore "dhcp-option DNS"');
  for (final server in servers) {
    final ip = server.trim();
    if (ip.isNotEmpty) buf.writeln('dhcp-option DNS $ip');
  }
  return buf.toString();
}

/// Pin an Xray configuration's direct egress to IPv4.
///
/// What the bundled core does by default, from the configuration
/// builders' own evidence: the plugin's template (and the app's
/// hand-built Hysteria2 shape, which mirrors it) gives the freedom
/// ("direct") outbound `sockopt.domainStrategy: "UseIP"`, so any
/// traffic the configuration routes direct — DNS-over-TLS on port
/// 853 is the standing example — may leave over the phone's native
/// IPv6 whenever the network offers it. This transform rewrites
/// every freedom outbound's sockopt domain strategy to `UseIPv4`,
/// and pins the DNS object's query strategy to `UseIPv4` when a
/// DNS object is present (the app's own DNS injection already sets
/// it; this keeps hand-built and stripped variants identical).
///
/// The tunnel interface itself is not configured here: the
/// plugin's VPN service already gives it a ULA IPv6 address and a
/// `::/0` route (an IPv6 sinkhole), so app IPv6 traffic enters the
/// tunnel rather than the native network; what this transform
/// governs is the core's own direct egress once traffic is inside.
/// A malformed (non-JSON) input is returned unchanged, so this can
/// never break a connect. Pure — unit-tested.
String hardenXrayConfig(String configJson) {
  try {
    final decoded = jsonDecode(configJson);
    if (decoded is! Map<String, dynamic>) return configJson;
    final outbounds = decoded['outbounds'];
    if (outbounds is List) {
      for (final outbound in outbounds) {
        if (outbound is! Map<String, dynamic>) continue;
        if (outbound['protocol'] != 'freedom') continue;
        final stream = outbound['streamSettings'];
        final streamMap = stream is Map<String, dynamic>
            ? stream
            : <String, dynamic>{};
        final sockopt = streamMap['sockopt'];
        final sockoptMap = sockopt is Map<String, dynamic>
            ? sockopt
            : <String, dynamic>{};
        sockoptMap['domainStrategy'] = 'UseIPv4';
        streamMap['sockopt'] = sockoptMap;
        outbound['streamSettings'] = streamMap;
      }
    }
    final dns = decoded['dns'];
    if (dns is Map<String, dynamic>) {
      dns['queryStrategy'] = 'UseIPv4';
    }
    return jsonEncode(decoded);
  } catch (_) {
    return configJson;
  }
}
