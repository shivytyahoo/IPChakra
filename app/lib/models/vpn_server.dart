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
  });

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
