import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Cloudflare WARP ka free WireGuard config.
///
/// Pehli baar connect karne pe app WARP ke public client API se ek free
/// identity register karti hai (sirf ek baar), phir usi se WireGuard
/// tunnel banta hai. Koi password/signup nahi - poori tarah free.
class WarpConfig {
  final String privateKey; // base64, hamari local key
  final String addressV4; // jaise 172.16.0.2/32
  final String peerPublicKey; // Cloudflare ka peer
  final String endpoint; // jaise 162.159.192.1:2408
  WarpConfig({
    required this.privateKey,
    required this.addressV4,
    required this.peerPublicKey,
    required this.endpoint,
  });
}

class WarpService {
  static const _regUrl = 'https://api.cloudflareclient.com/v0a2223/reg';
  static const _kPriv = 'warp_priv';
  static const _kAddr = 'warp_addr';
  static const _kPeer = 'warp_peer';
  static const _kEndpoint = 'warp_endpoint';

  /// Pehle se registered identity hai to wahi, warna nayi register karo.
  Future<WarpConfig> ensureRegistered() async {
    final prefs = await SharedPreferences.getInstance();
    final priv = prefs.getString(_kPriv);
    final addr = prefs.getString(_kAddr);
    final peer = prefs.getString(_kPeer);
    if (priv != null && addr != null && peer != null) {
      return WarpConfig(
        privateKey: priv,
        addressV4: addr,
        peerPublicKey: peer,
        endpoint: prefs.getString(_kEndpoint) ?? '162.159.192.1:2408',
      );
    }
    return register();
  }

  /// Nayi free WARP identity register karo.
  Future<WarpConfig> register() async {
    final alg = X25519();
    final keyPair = await alg.newKeyPair();
    final pubKey = await keyPair.extractPublicKey();
    final privBytes = await keyPair.extractPrivateKeyBytes();
    final pubB64 = base64Encode(pubKey.bytes);
    final privB64 = base64Encode(privBytes);
    final installId = const Uuid().v4();

    final resp = await http
        .post(
          Uri.parse(_regUrl),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent': 'okhttp/3.12.1',
          },
          body: jsonEncode({
            'install_id': installId,
            'tos': DateTime.now().toUtc().toIso8601String(),
            'key': pubB64,
            'fcm_token': '',
            'type': 'Android',
            'locale': 'en_US',
          }),
        )
        .timeout(const Duration(seconds: 30));

    if (resp.statusCode != 200) {
      throw Exception(
          'Free identity register nahi hui (HTTP ${resp.statusCode}). Thodi der me dobara try karo.');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    final peers = (j['config']?['peers'] as List?) ?? [];
    if (peers.isEmpty) {
      throw Exception('WARP config me peer nahi mila. Dobara try karo.');
    }
    final peerPub = peers[0]['public_key']?.toString() ?? '';
    String endpoint = '162.159.192.1:2408';
    final ep = peers[0]['endpoint'];
    if (ep is Map && ep['v4'] != null) endpoint = ep['v4'].toString();
    final addr =
        j['config']?['interface']?['addresses']?['v4']?.toString() ??
            '172.16.0.2/32';
    if (peerPub.isEmpty) {
      throw Exception('WARP peer key nahi mila. Dobara try karo.');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPriv, privB64);
    await prefs.setString(_kAddr, addr);
    await prefs.setString(_kPeer, peerPub);
    await prefs.setString(_kEndpoint, endpoint);
    return WarpConfig(
      privateKey: privB64,
      addressV4: addr,
      peerPublicKey: peerPub,
      endpoint: endpoint,
    );
  }

  /// wireguard_flutter ke liye wg-quick config text.
  String buildQuickConfig(WarpConfig w, String endpoint) {
    return '[Interface]\n'
        'PrivateKey = ${w.privateKey}\n'
        'Address = ${w.addressV4}\n'
        'DNS = 1.1.1.1, 1.0.0.1\n'
        '\n'
        '[Peer]\n'
        'PublicKey = ${w.peerPublicKey}\n'
        'AllowedIPs = 0.0.0.0/0\n'
        'Endpoint = $endpoint\n';
  }

  /// Free identity bhool jao (nayi banane ke liye).
  Future<void> resetIdentity() async {
    final prefs = await SharedPreferences.getInstance();
    for (final k in [_kPriv, _kAddr, _kPeer, _kEndpoint]) {
      await prefs.remove(k);
    }
  }
}
