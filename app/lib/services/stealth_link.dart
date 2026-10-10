import 'dart:convert';

/// Parsed information about a single stealth (V2Ray/Xray) share link.
///
/// Produced by [StealthLink.parse]. Pure data — no Flutter, no I/O — so it
/// can be unit-tested directly.
class StealthLinkInfo {
  /// Link scheme: 'ss' | 'vless' | 'trojan' | 'vmess' | 'hysteria2'.
  /// Both hysteria2:// and hy2:// links normalise to 'hysteria2'.
  final String scheme;

  /// Server host name, IP address, or IPv6 address (without brackets).
  final String host;

  /// Server port.
  final int port;

  /// Display remark: the decoded URI fragment, or the vmess 'ps' field.
  /// Empty when the link carries no remark.
  final String remark;

  /// Stealth tier:
  /// 'Reality' | 'Hysteria2' | 'TLS' | 'Shadowsocks' | 'VMess'.
  final String tier;

  /// Hysteria2 only: the authentication password (the link's userinfo,
  /// percent-decoded). Empty for every other scheme.
  final String auth;

  /// Hysteria2 only: TLS server name from the 'sni' parameter.
  final String? sni;

  /// Hysteria2 only: true when the link sets insecure=1 (accept a
  /// self-signed / mismatched server certificate).
  final bool allowInsecure;

  /// Hysteria2 only: obfuscation type from the 'obfs' parameter
  /// (lower-cased), e.g. 'salamander'.
  final String? obfsType;

  /// Hysteria2 only: obfuscation password from 'obfs-password'.
  final String? obfsPassword;

  /// Hysteria2 only: ALPN list from the 'alpn' parameter.
  final List<String>? alpn;

  /// Hysteria2 only: pinned peer certificate SHA-256 from
  /// 'pinSHA256' (or its 'pcs' alias).
  final String? pinSha256;

  /// Hysteria2 only: port-hopping expression (e.g. '20000-30000' or
  /// '443,8443') from the 'mport' parameter or a port range/list in
  /// the link authority. [port] always holds the first concrete port.
  final String? portHop;

  /// Hysteria2 only: UDP idle timeout in seconds, when the link
  /// carries one.
  final int? udpIdleTimeout;

  /// Hysteria2 only: the raw FinalMask object decoded from the 'fm'
  /// parameter, when present and valid JSON.
  final Map<String, dynamic>? finalmask;

  const StealthLinkInfo({
    required this.scheme,
    required this.host,
    required this.port,
    required this.remark,
    required this.tier,
    this.auth = '',
    this.sni,
    this.allowInsecure = false,
    this.obfsType,
    this.obfsPassword,
    this.alpn,
    this.pinSha256,
    this.portHop,
    this.udpIdleTimeout,
    this.finalmask,
  });

  /// Preference order for stealth tiers — lower is tried/listed first.
  /// Reality hides best from deep packet inspection, plain VMess least.
  int get tierRank {
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

  @override
  String toString() =>
      'StealthLinkInfo($scheme, $host:$port, tier: $tier, remark: $remark)';
}

/// Parser for stealth share links:
/// ss://, vless://, trojan://, vmess://, hysteria2:// and hy2://.
///
/// Pure Dart (only `dart:convert`) so it stays unit-testable without the
/// Flutter engine or the Xray plugin. Every parse is defensive: any
/// malformed input returns null instead of throwing.
class StealthLink {
  StealthLink._();

  static const supportedSchemes = {
    'ss',
    'vless',
    'trojan',
    'vmess',
    'hysteria2',
    'hy2',
  };

  /// True when [link] is a supported, valid stealth share link.
  static bool isSupported(String link) => parse(link) != null;

  /// Parse [link] into a [StealthLinkInfo], or return null when the link
  /// is not a supported scheme or is structurally invalid.
  static StealthLinkInfo? parse(String link) {
    try {
      return _parse(link.trim());
    } catch (_) {
      return null;
    }
  }

  static StealthLinkInfo? _parse(String link) {
    if (link.isEmpty) return null;
    final schemeEnd = link.indexOf('://');
    if (schemeEnd <= 0) return null;
    final scheme = link.substring(0, schemeEnd).toLowerCase();
    if (!supportedSchemes.contains(scheme)) return null;
    switch (scheme) {
      case 'ss':
        return _parseShadowsocks(link);
      case 'vless':
      case 'trojan':
        return _parseUriLink(link, scheme);
      case 'vmess':
        return _parseVmess(link);
      case 'hysteria2':
      case 'hy2':
        return _parseHysteria2(link);
      default:
        return null;
    }
  }

  // ── Shadowsocks ─────────────────────────────────────────────────

  /// ss://BASE64(method:password)@host:port#remark (legacy + SIP002
  /// base64 userinfo), ss://method:password@host:port (SIP002 plain
  /// userinfo), and the fully-base64 legacy form
  /// ss://BASE64(method:password@host:port).
  /// In every form the host:port part follows the LAST '@'.
  static StealthLinkInfo? _parseShadowsocks(String link) {
    var rest = link.substring(link.indexOf('://') + 3);

    // Fragment = remark (percent-encoded).
    var remark = '';
    final hashIdx = rest.indexOf('#');
    if (hashIdx >= 0) {
      remark = _safeDecode(rest.substring(hashIdx + 1));
      rest = rest.substring(0, hashIdx);
    }
    // Query (SIP002 plugin options) is not part of host:port.
    final queryIdx = rest.indexOf('?');
    if (queryIdx >= 0) rest = rest.substring(0, queryIdx);
    // Trailing path separator some generators append.
    if (rest.endsWith('/')) rest = rest.substring(0, rest.length - 1);
    if (rest.isEmpty) return null;

    final atIdx = rest.lastIndexOf('@');
    if (atIdx < 0) {
      // Fully-base64 legacy form: decode, then split userinfo@host:port.
      final decoded = _decodeBase64Text(rest);
      if (decoded == null) return null;
      final innerAt = decoded.lastIndexOf('@');
      if (innerAt <= 0) return null;
      if (!_isValidUserInfo(decoded.substring(0, innerAt))) return null;
      final hp = _parseHostPort(decoded.substring(innerAt + 1));
      if (hp == null) return null;
      return StealthLinkInfo(
        scheme: 'ss',
        host: hp.$1,
        port: hp.$2,
        remark: remark,
        tier: 'Shadowsocks',
      );
    }

    final userInfo = rest.substring(0, atIdx);
    if (!_isValidUserInfo(userInfo)) return null;
    final hp = _parseHostPort(rest.substring(atIdx + 1));
    if (hp == null) return null;
    return StealthLinkInfo(
      scheme: 'ss',
      host: hp.$1,
      port: hp.$2,
      remark: remark,
      tier: 'Shadowsocks',
    );
  }

  /// Shadowsocks userinfo is either plain `method:password` (possibly
  /// percent-encoded) or base64 of the same — both contain a ':'.
  static bool _isValidUserInfo(String userInfo) {
    if (userInfo.isEmpty) return false;
    if (_safeDecode(userInfo).contains(':')) return true;
    final decoded = _decodeBase64Text(userInfo);
    return decoded != null && decoded.contains(':');
  }

  // ── VLESS / Trojan (plain URIs) ─────────────────────────────────

  /// vless://uuid@host:port?params#remark
  /// trojan://password@host:port?params#remark
  /// Default port is 443 when the URI has none.
  static StealthLinkInfo? _parseUriLink(String link, String scheme) {
    final uri = Uri.tryParse(link);
    if (uri == null) return null;
    final host = uri.host;
    if (host.isEmpty) return null;
    if (uri.userInfo.isEmpty) return null;
    final port = uri.hasPort ? uri.port : 443;
    if (port < 1 || port > 65535) return null;
    final remark = _safeDecode(uri.fragment);
    final params = uri.queryParameters;
    final String tier;
    if (scheme == 'trojan') {
      // Trojan always runs over TLS.
      tier = 'TLS';
    } else if (params['security']?.toLowerCase() == 'reality') {
      tier = 'Reality';
    } else if (params['security']?.toLowerCase() == 'tls') {
      tier = 'TLS';
    } else {
      // VLESS without an explicit security value: the overwhelming
      // majority of public VLESS links use TLS, so rank it there.
      tier = 'TLS';
    }
    return StealthLinkInfo(
      scheme: scheme,
      host: host,
      port: port,
      remark: remark,
      tier: tier,
    );
  }

  // ── VMess (base64 JSON) ─────────────────────────────────────────

  /// vmess://BASE64(JSON) where the JSON carries add/port/ps/tls fields.
  static StealthLinkInfo? _parseVmess(String link) {
    var payload = link.substring(link.indexOf('://') + 3);
    // Tolerate a trailing fragment/query even though 'ps' is canonical.
    final hashIdx = payload.indexOf('#');
    if (hashIdx >= 0) payload = payload.substring(0, hashIdx);
    final queryIdx = payload.indexOf('?');
    if (queryIdx >= 0) payload = payload.substring(0, queryIdx);

    final text = _decodeBase64Text(payload);
    if (text == null) return null;
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    final host = decoded['add']?.toString().trim() ?? '';
    if (host.isEmpty) return null;
    final port = int.tryParse(decoded['port']?.toString() ?? '');
    if (port == null || port < 1 || port > 65535) return null;
    final remark = decoded['ps']?.toString() ?? '';
    final tlsField = decoded['tls']?.toString().toLowerCase() ?? '';
    final securityField =
        decoded['security']?.toString().toLowerCase() ?? '';
    final tier =
        (tlsField == 'tls' || securityField == 'tls') ? 'TLS' : 'VMess';
    return StealthLinkInfo(
      scheme: 'vmess',
      host: host,
      port: port,
      remark: remark,
      tier: tier,
    );
  }

  // ── Hysteria2 (hysteria2:// and hy2://) ─────────────────────────

  /// hysteria2://password@host:port?params#remark
  /// hy2://password@host:port?params#remark
  ///
  /// Parsed by hand instead of via [Uri] because real-world links use
  /// authority forms Dart's Uri rejects or mangles: port ranges and
  /// port lists (`host:20000-30000`, `host:443,8443`) for port
  /// hopping, and percent-encoded or '@'-carrying auth strings.
  /// The authority's LAST '@' separates the auth from the host (an
  /// auth string may itself contain an '@'; a host never does).
  static StealthLinkInfo? _parseHysteria2(String link) {
    var rest = link.substring(link.indexOf('://') + 3);

    // Fragment = remark (percent-encoded).
    var remark = '';
    final hashIdx = rest.indexOf('#');
    if (hashIdx >= 0) {
      remark = _safeDecode(rest.substring(hashIdx + 1));
      rest = rest.substring(0, hashIdx);
    }
    // Query parameters.
    var params = <String, String>{};
    final queryIdx = rest.indexOf('?');
    if (queryIdx >= 0) {
      params = _parseQuery(rest.substring(queryIdx + 1));
      rest = rest.substring(0, queryIdx);
    }
    // Drop any path segment after the authority.
    final slashIdx = rest.indexOf('/');
    if (slashIdx >= 0) rest = rest.substring(0, slashIdx);
    if (rest.isEmpty) return null;

    final atIdx = rest.lastIndexOf('@');
    if (atIdx < 0) return null;
    final auth = _safeDecode(rest.substring(0, atIdx));
    if (auth.isEmpty) return null;
    final hostPort = rest.substring(atIdx + 1);

    final String host;
    String? portExpr;
    if (hostPort.startsWith('[')) {
      final close = hostPort.indexOf(']');
      if (close < 0) return null;
      host = hostPort.substring(1, close);
      final tail = hostPort.substring(close + 1);
      if (tail.isNotEmpty) {
        if (!tail.startsWith(':')) return null;
        portExpr = tail.substring(1);
      }
    } else {
      final idx = hostPort.lastIndexOf(':');
      if (idx >= 0) {
        host = hostPort.substring(0, idx);
        portExpr = hostPort.substring(idx + 1);
      } else {
        host = hostPort;
      }
    }
    if (host.isEmpty) return null;

    // The concrete port: the first number of the authority's port
    // expression, else of the mport expression, else the hy2
    // default 443.
    final mport = params['mport'];
    final port = _firstPort(portExpr) ?? _firstPort(mport) ?? 443;
    if (port < 1 || port > 65535) return null;

    // Port hopping applies when a port range/list is present — in the
    // mport parameter (the common feed form) or in the authority.
    String? portHop;
    if (mport != null && mport.isNotEmpty) {
      portHop = mport;
    } else if (portExpr != null &&
        (portExpr.contains('-') || portExpr.contains(','))) {
      portHop = portExpr;
    }

    final insecureRaw =
        (params['insecure'] ?? params['allowInsecure'] ?? '').toLowerCase();
    final alpnRaw = params['alpn'];
    final alpn = (alpnRaw == null || alpnRaw.isEmpty)
        ? null
        : alpnRaw
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
    final idleRaw = params['udpIdleTimeout'] ?? params['udp_idle_timeout'];
    final sniRaw = params['sni'];
    final obfsRaw = params['obfs'];
    final pinRaw = params['pinSHA256'] ?? params['pcs'];

    Map<String, dynamic>? finalmask;
    final fm = params['fm'];
    if (fm != null && fm.isNotEmpty) {
      try {
        final decoded = jsonDecode(fm);
        if (decoded is Map<String, dynamic>) finalmask = decoded;
      } catch (_) {
        // A malformed fm parameter is ignored, not fatal.
      }
    }

    return StealthLinkInfo(
      scheme: 'hysteria2',
      host: host,
      port: port,
      remark: remark,
      tier: 'Hysteria2',
      auth: auth,
      sni: (sniRaw == null || sniRaw.isEmpty) ? null : sniRaw,
      allowInsecure: insecureRaw == '1' || insecureRaw == 'true',
      obfsType: (obfsRaw == null || obfsRaw.isEmpty)
          ? null
          : obfsRaw.toLowerCase(),
      obfsPassword: params['obfs-password'],
      alpn: (alpn == null || alpn.isEmpty) ? null : alpn,
      pinSha256: (pinRaw == null || pinRaw.isEmpty) ? null : pinRaw,
      portHop: portHop,
      udpIdleTimeout: idleRaw == null ? null : int.tryParse(idleRaw),
      finalmask: finalmask,
    );
  }

  /// Split a URI query string into decoded key/value pairs. Unlike
  /// form decoding, '+' is kept literal (share-link values such as
  /// obfs passwords may contain one).
  static Map<String, String> _parseQuery(String query) {
    final out = <String, String>{};
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq < 0) {
        out[_safeDecode(pair)] = '';
      } else {
        out[_safeDecode(pair.substring(0, eq))] =
            _safeDecode(pair.substring(eq + 1));
      }
    }
    return out;
  }

  /// First concrete port number of a port expression: '443' → 443,
  /// '20000-30000' → 20000, '443,8443' → 443. Null when the
  /// expression carries no leading number.
  static int? _firstPort(String? expr) {
    if (expr == null || expr.isEmpty) return null;
    final first = expr.split(',').first.split('-').first.trim();
    return int.tryParse(first);
  }

  // ── helpers ─────────────────────────────────────────────────────

  /// Parse `host:port`, including bracketed IPv6 `[2001:db8::1]:443`.
  static (String, int)? _parseHostPort(String hostPort) {
    final hp = hostPort.trim();
    if (hp.isEmpty) return null;
    final String host;
    final int? port;
    if (hp.startsWith('[')) {
      final close = hp.indexOf(']');
      if (close < 0) return null;
      host = hp.substring(1, close);
      final rest = hp.substring(close + 1);
      if (!rest.startsWith(':')) return null;
      port = int.tryParse(rest.substring(1));
    } else {
      final idx = hp.lastIndexOf(':');
      if (idx <= 0) return null;
      host = hp.substring(0, idx);
      port = int.tryParse(hp.substring(idx + 1));
    }
    if (host.isEmpty || port == null || port < 1 || port > 65535) {
      return null;
    }
    return (host, port);
  }

  /// Decode base64/base64url text, tolerating missing '=' padding and
  /// embedded whitespace. Returns null on any decode failure.
  static String? _decodeBase64Text(String input) {
    try {
      var s = input.replaceAll(RegExp(r'\s'), '');
      s = s.replaceAll('-', '+').replaceAll('_', '/');
      final remainder = s.length % 4;
      if (remainder == 1) return null; // impossible base64 length
      if (remainder > 0) s = s.padRight(s.length + (4 - remainder), '=');
      return utf8.decode(base64Decode(s));
    } catch (_) {
      return null;
    }
  }

  /// Percent-decode, keeping the raw text when it is not valid encoding.
  static String _safeDecode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }
}
