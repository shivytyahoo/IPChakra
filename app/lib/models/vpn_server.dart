/// Ek VPN server ka record. Ye list remote database (servers.json)
/// se aati hai, isliye app update kiye bina naye servers add ho sakte hain.
class VpnServer {
  final String id;
  final String name;
  final String country;
  final String flag;
  final String type; // 'free' | 'chakra' | 'custom'
  final String protocol; // 'wireguard'
  final bool warp; // true -> Cloudflare WARP se free identity
  final String? endpoint; // warp: preferred endpoint | custom: server endpoint
  final String? peerPublicKey; // custom servers ke liye
  final String note;
  final bool enabled;
  final int? pingMs;

  /// Runtime-only: VPNGate se aaya OpenVPN config text (servers.json me nahi).
  final String? ovpnConfig;

  /// Runtime-only: V2Ray share link (ss://, vmess:// ...).
  final String? shareLink;

  /// Stealth tier for V2Ray/Xray servers:
  /// 'Reality' | 'TLS' | 'Shadowsocks' | 'VMess' | '' (non-stealth).
  final String tier;

  /// Kahan se aaya: 'warp' | 'vpngate' | 'vpnbook' | 'mirror' | 'v2ray' | 'chakra' | 'custom'
  final String source;

  /// Runtime-only: config on-demand lane ke liye (jaise VPNBook API).
  final Future<String> Function()? configLoader;

  /// OpenVPN auth (jaise VPNBook: vpnbook + weekly password).
  /// Plugin ke username/password params me jaata hai.
  final String? authUsername;
  final String? authPassword;

  /// Runtime-only: direct health-probe target for sources whose
  /// configs are fetched on demand (the VPNGate rolling pool, the
  /// VPNBook protocol variants). When both are set, the health
  /// checker probes this endpoint directly instead of downloading
  /// the config first. [probePort] stays null when the source's
  /// index does not carry the port (the pool's UDP entries) — the
  /// health checker then resolves the target from the config once
  /// and caches it, exactly like it does for mirror entries.
  final String? probeHost;
  final int? probePort;

  /// Whether [probeHost]:[probePort] speaks UDP (OpenVPN over UDP
  /// needs the host-reachability probe, not a bare TCP connect).
  final bool probeUdp;

  /// True when an independent liveness registry (the VPNGate
  /// monitor's real OpenVPN handshake tests) verified this server
  /// alive. This is a hint for ordering and display only: the app's
  /// own health verdict always wins, so a server the app found dead
  /// stays dead even when this flag is set.
  final bool externalVerified;

  const VpnServer({
    required this.id,
    required this.name,
    this.country = '',
    this.flag = '🌐',
    this.type = 'free',
    this.protocol = 'wireguard',
    this.warp = false,
    this.endpoint,
    this.peerPublicKey,
    this.note = '',
    this.enabled = true,
    this.pingMs,
    this.ovpnConfig,
    this.shareLink,
    this.tier = '',
    this.source = 'custom',
    this.configLoader,
    this.authUsername,
    this.authPassword,
    this.probeHost,
    this.probePort,
    this.probeUdp = false,
    this.externalVerified = false,
  });

  /// A copy of this server with [externalVerified] set — used when
  /// the OpenVPN database merge learns from the liveness registry
  /// that this endpoint passed a real handshake test.
  VpnServer markVerified() {
    if (externalVerified) return this;
    return VpnServer(
      id: id,
      name: name,
      country: country,
      flag: flag,
      type: type,
      protocol: protocol,
      warp: warp,
      endpoint: endpoint,
      peerPublicKey: peerPublicKey,
      note: note,
      enabled: enabled,
      pingMs: pingMs,
      ovpnConfig: ovpnConfig,
      shareLink: shareLink,
      tier: tier,
      source: source,
      configLoader: configLoader,
      authUsername: authUsername,
      authPassword: authPassword,
      probeHost: probeHost,
      probePort: probePort,
      probeUdp: probeUdp,
      externalVerified: true,
    );
  }

  bool get isChakra => type == 'chakra';

  /// True for any V2Ray/Xray (stealth-capable) server.
  bool get isStealth => protocol == 'v2ray';

  /// Kya is server se abhi connect ho sakta hai?
  bool get connectable =>
      enabled && (warp || (peerPublicKey != null && endpoint != null));

  factory VpnServer.fromJson(Map<String, dynamic> j) {
    final isWarp = j['warp'] == true;
    return VpnServer(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? 'Server',
        country: j['country']?.toString() ?? '',
        flag: j['flag']?.toString() ?? '🌐',
        type: j['type']?.toString() ?? 'free',
        protocol: j['protocol']?.toString() ?? 'wireguard',
        warp: isWarp,
        endpoint: j['endpoint']?.toString(),
        peerPublicKey: j['peer_public_key']?.toString(),
        note: j['note']?.toString() ?? '',
        enabled: j['enabled'] != false,
        tier: j['tier']?.toString() ?? '',
        // warp servers carry no source in JSON — set it here
        source: j['source']?.toString() ?? (isWarp ? 'warp' : 'custom'),
      );
  }
}
