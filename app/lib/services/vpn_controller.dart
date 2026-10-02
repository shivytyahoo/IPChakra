import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';
import 'package:wireguard_flutter/wireguard_flutter.dart';
import '../core/net.dart';
import '../models/vpn_server.dart';
import 'vpngate_service.dart';
import 'warp_service.dart';

enum VpnState { disconnected, connecting, connected, disconnecting, error }

enum AppMode { free, chakra }

/// Poore app ka VPN brain: connect/disconnect + state.
///
/// Teen engine:
/// - WireGuard (WARP free + custom) — Android, TV, Windows
/// - OpenVPN (VPNGate, VPNBook, Mirror) — Android, TV
/// - V2Ray/Xray (free ss links) — Android, TV
///
/// Hang-proof design:
/// - har native call pe timeout (koi await kabhi infinite nahi)
/// - generation counter: purana attempt naya aate hi cancel
/// - watchdog: callback na aaye to native poll + IP-change se verify
class VpnController extends ChangeNotifier {
  final _wg = WireGuardFlutter.instance;
  late final OpenVPN _ovpn;
  late final V2ray _v2ray;
  final WarpService warp;

  VpnState state = VpnState.disconnected;
  AppMode mode = AppMode.free;
  VpnServer? currentServer;
  String? currentIp;
  String? errorMsg;
  DateTime? connectedAt;

  /// Kaunsa engine chal raha hai: 'wireguard' | 'openvpn' | 'v2ray' | null
  String? _activeEngine;

  /// Har connect/disconnect pe badhta hai; purane async kaam isse
  /// check karke khud cancel ho jaate hain.
  int _attempt = 0;
  bool _isCurrent(int a) => a == _attempt;

  static const _opTimeout = Duration(seconds: 30);
  static const _settleTimeout = Duration(seconds: 40);

  /// UI ke liye chhote naam.
  VpnServer? get server => currentServer;
  String? get exitIp => currentIp;
  String? get lastError => errorMsg;

  void setMode(AppMode m) {
    mode = m;
    notifyListeners();
  }

  /// Custom server ke liye bani local public key - ise apne VPS pe
  /// peer ke roop me add karna hota hai (Settings me dikhegi).
  String? customClientPubKey;

  bool _inited = false;

  VpnController(this.warp) {
    _ovpn = OpenVPN(onVpnStageChanged: _onOvpnStage);
    _v2ray = V2ray(onStatusChanged: _onV2rayStatus);
  }

  Future<void> _init() async {
    if (_inited) return;
    await _wg.initialize(interfaceName: 'ipchakra0');
    _wg.vpnStageSnapshot.listen(_onStage);
    if (Platform.isAndroid) {
      // Dono VPN plugins Android pe hain; Windows pe sirf WireGuard.
      await _ovpn.initialize(
        providerBundleIdentifier: 'com.ipchakra.app',
        localizedDescription: 'IPChakra',
        groupIdentifier: 'group.com.ipchakra.app',
      );
      await _v2ray.initialize(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_launcher',
      );
    }
    _inited = true;
  }

  // ── native callbacks ────────────────────────────────────────────

  /// V2Ray engine ke status events (state: CONNECTED / CONNECTING / DISCONNECTED).
  void _onV2rayStatus(V2RayStatus status) {
    switch (status.state.toUpperCase()) {
      case 'CONNECTED':
        _markConnected();
        break;
      case 'CONNECTING':
      case 'STARTING':
        // connected ke baad aaye stale event se wapas mat jao
        if (state != VpnState.connected) _setState(VpnState.connecting);
        break;
      case 'DISCONNECTED':
      case 'STOPPED':
        if (state == VpnState.connecting) {
          _fail('V2Ray server se connect nahi ho paya.');
        } else if (state != VpnState.error) {
          _setState(VpnState.disconnected);
        }
        break;
      default:
        break;
    }
  }

  void _onStage(dynamic event) {
    // wireguard_flutter VpnStage enum bhejta hai, jaise 'VpnStage.connected'.
    final raw = event.toString();
    final s = raw.contains('.') ? raw.split('.').last : raw;
    switch (s) {
      case 'connected':
        _markConnected();
        break;
      case 'connecting':
      case 'preparing':
      case 'authenticating':
      case 'waitingConnection':
      case 'reconnect':
        if (state != VpnState.connected) _setState(VpnState.connecting);
        break;
      case 'disconnecting':
        _setState(VpnState.disconnecting);
        break;
      case 'denied':
        _fail('System ne VPN permission deny kar di.');
        break;
      case 'disconnected':
      case 'noConnection':
      case 'exiting':
        if (state == VpnState.connecting) {
          _fail('WireGuard tunnel establish nahi hua.');
        } else if (state != VpnState.error) {
          _setState(VpnState.disconnected);
        }
        break;
      default:
        break;
    }
  }

  /// OpenVPN engine ke stage events.
  void _onOvpnStage(VPNStage stage, String rawStage) {
    switch (stage) {
      case VPNStage.connected:
        _markConnected();
        break;
      case VPNStage.connecting:
      case VPNStage.prepare:
      case VPNStage.authenticating:
      case VPNStage.authentication:
      case VPNStage.wait_connection:
      case VPNStage.vpn_generate_config:
      case VPNStage.get_config:
      case VPNStage.tcp_connect:
      case VPNStage.udp_connect:
      case VPNStage.assign_ip:
      case VPNStage.resolve:
        // connected ke baad aaye stale/transitional event ko ignore karo
        if (state != VpnState.connected) _setState(VpnState.connecting);
        break;
      case VPNStage.disconnecting:
        _setState(VpnState.disconnecting);
        break;
      case VPNStage.denied:
        _fail('System ne VPN permission deny kar di.');
        break;
      case VPNStage.error:
        _fail('OpenVPN connect nahi ho paya. Koi aur server try karo.');
        break;
      case VPNStage.disconnected:
        if (state == VpnState.connecting) {
          _fail('Server ne connection kaat di. Koi aur server try karo.');
        } else if (state != VpnState.error) {
          _setState(VpnState.disconnected);
        }
        break;
      default:
        break;
    }
  }

  void _setState(VpnState s) {
    state = s;
    notifyListeners();
  }

  /// Kahin se bhi "connected" aaye — timer + state ek saath set karo.
  /// (Pehle callback se connected hota tha par connectedAt null rehta tha,
  /// isliye session timer "—" dikhata tha.)
  void _markConnected() {
    connectedAt ??= DateTime.now();
    _setState(VpnState.connected);
    unawaited(_refreshIp());
  }

  void _fail(String msg) {
    errorMsg = msg;
    _setState(VpnState.error);
  }

  String _short(Object e) {
    if (e is TimeoutException) return 'Server se jawab nahi aaya (timeout).';
    final s = e.toString().replaceFirst('Exception: ', '');
    return s.length > 140 ? '${s.substring(0, 140)}…' : s;
  }

  // ── connect / disconnect ────────────────────────────────────────

  Future<void> connect(VpnServer server) async {
    final myAttempt = ++_attempt;
    try {
      await _init().timeout(const Duration(seconds: 20));
    } catch (e) {
      if (_isCurrent(myAttempt)) _fail('VPN engine start nahi hua: ${_short(e)}');
      return;
    }
    if (!_isCurrent(myAttempt)) return;

    // Pichla tunnel (agar aadha-adhoora hai) bina hang ke band karo.
    _setState(VpnState.disconnecting);
    await _stopAllEngines();
    if (!_isCurrent(myAttempt)) return;

    currentServer = server;
    errorMsg = null;
    customClientPubKey = null;
    connectedAt = null;
    _setState(VpnState.connecting);

    // Verify ke liye connect se pehle wala IP.
    final ipBefore = await _safeIp();

    try {
      await _startEngine(server).timeout(_opTimeout);
    } catch (e) {
      await _stopAllEngines();
      if (_isCurrent(myAttempt)) {
        _fail('Connect nahi ho paya: ${_short(e)} Doosra server try karo.');
      }
      return;
    }
    if (!_isCurrent(myAttempt)) return;

    // WireGuard (WARP): startVpn return == tunnel up (purana working behavior,
    // instant). OpenVPN/V2Ray: callback / poll / IP-verify ka intezaar.
    if (_activeEngine == 'wireguard') {
      _markConnected();
      return;
    }

    final ok = await _waitForConnected(myAttempt, ipBefore);
    if (!_isCurrent(myAttempt)) return;
    if (ok) {
      _markConnected();
    } else {
      await _stopAllEngines();
      if (_isCurrent(myAttempt)) {
        _fail('Server se connect nahi ho paya. Doosra server try karo.');
      }
    }
  }

  Future<void> disconnect() async {
    ++_attempt; // in-flight connect cancel ho jayega
    _setState(VpnState.disconnecting);
    await _stopAllEngines();
    _activeEngine = null;
    currentServer = null;
    currentIp = null;
    connectedAt = null;
    _setState(VpnState.disconnected);
  }

  /// Teeno engines ko roko. Har ek pe timeout hai — koi bhi native
  /// call kabhi hang nahi karegi, chahe engine aadhi state me ho.
  Future<void> _stopAllEngines() async {
    try {
      _ovpn.disconnect(); // void — fire and forget
    } catch (_) {}
    try {
      await _v2ray.stopV2Ray().timeout(const Duration(seconds: 6));
    } catch (_) {}
    try {
      await _wg.stopVpn().timeout(const Duration(seconds: 6));
    } catch (_) {}
    // native ko saans lene do
    await Future.delayed(const Duration(milliseconds: 400));
  }

  /// Tunnel up hua ya nahi — callback ka intezaar + backup verify.
  Future<bool> _waitForConnected(int myAttempt, String? ipBefore) async {
    final deadline = DateTime.now().add(_settleTimeout);
    var lastProbe = DateTime.now().subtract(const Duration(seconds: 30));
    while (_isCurrent(myAttempt)) {
      if (state == VpnState.connected) return true;
      if (state == VpnState.error || state == VpnState.disconnected) {
        return false;
      }
      if (DateTime.now().isAfter(deadline)) break;
      // Har ~8s me backup probe (callback miss ho gaya ho to).
      if (DateTime.now().difference(lastProbe).inSeconds >= 8) {
        lastProbe = DateTime.now();
        if (await _probeConnected(ipBefore)) return true;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    // Aakhri verify (bug: tunnel up hai par callback nahi aaya).
    return _isCurrent(myAttempt) && await _probeConnected(ipBefore);
  }

  /// Native se poochho: tunnel sach me up hai?
  Future<bool> _probeConnected(String? ipBefore) async {
    try {
      if (_activeEngine == 'openvpn') {
        if (await _ovpn.isConnected().timeout(const Duration(seconds: 5))) {
          return true;
        }
      }
      // WireGuard/V2Ray ke liye ground truth: exit IP badla ya nahi.
      final ip = await _safeIp();
      if (ip != null && ipBefore != null && ip != ipBefore) return true;
    } catch (_) {}
    return false;
  }

  Future<String?> _safeIp() async {
    try {
      return await fetchExitIp().timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  // ── engines ─────────────────────────────────────────────────────

  Future<void> _startEngine(VpnServer server) async {
    if (server.protocol == 'openvpn') {
      await _connectOvpn(server);
      return;
    }
    if (server.protocol == 'v2ray') {
      await _connectV2ray(server);
      return;
    }
    await _connectWireGuard(server);
  }

  /// VPNGate / VPNBook / Mirror se OpenVPN connect.
  ///
  /// IMPORTANT: openvpn_flutter ke native "connect" me result.success() call
  /// nahi hai — isliye iska Future kabhi complete nahi hota! Await karoge to
  /// hamesha hang. Fire-and-forget karo; success/failure stage callback +
  /// watchdog se aata hai.
  Future<void> _connectOvpn(VpnServer server) async {
    if (!Platform.isAndroid) {
      throw Exception(
          'OpenVPN servers Windows pe abhi supported nahi hain. Free Mode (WARP) use karo.');
    }
    var config = server.ovpnConfig;
    // VPNBook/Mirror ka config on-demand aata hai.
    config ??= await server.configLoader?.call();
    if (config == null || config.isEmpty || !config.contains('<ca>')) {
      throw Exception('Is server ka OpenVPN config nahi mila.');
    }
    _activeEngine = 'openvpn';
    // Credentials plugin ke documented username/password params se jaate hain.
    // VPNGate: vpn/vpn. VPNBook: vpnbook + weekly password (server object me).
    // Mirror: auth nahi chahiye. (VPNBook config me inline creds bhi embedded
    // hain — backup.)
    final isVpnGate = server.source == 'vpngate';
    try {
      // Await MAT karo — native result.success() kabhi nahi bhejta.
      unawaited(_ovpn
          .connect(
            config,
            'IPChakra',
            username: server.authUsername ??
                (isVpnGate ? VpnGateService.username : null),
            password: server.authPassword ??
                (isVpnGate ? VpnGateService.password : null),
            certIsRequired: true,
          )
          .then((_) {}, onError: (_) {
        // Late async error — stage callback isko report kar chuka hoga.
      }));
    } catch (e) {
      // Synchronous throw (jaise "not initialized")
      throw Exception('OpenVPN start nahi hua: ${_short(e)}');
    }
  }

  /// V2Ray/Xray se connect (free ss links).
  Future<void> _connectV2ray(VpnServer server) async {
    if (!Platform.isAndroid) {
      throw Exception(
          'V2Ray servers Windows pe abhi supported nahi hain. Free Mode (WARP) use karo.');
    }
    final link = server.shareLink;
    if (link == null || link.isEmpty) {
      throw Exception('Is server ka link nahi mila.');
    }
    final parser = V2ray.parseFromURL(link);
    final ok = await _v2ray.requestPermission().timeout(
          const Duration(seconds: 20),
          onTimeout: () => false,
        );
    if (!ok) {
      throw Exception('VPN permission nahi mili.');
    }
    _activeEngine = 'v2ray';
    await _v2ray.startV2Ray(
      remark: parser.remark.isEmpty ? server.name : parser.remark,
      config: parser.getFullConfiguration(),
      proxyOnly: false,
    );
  }

  Future<void> _connectWireGuard(VpnServer server) async {
    late final String conf;
    late final String endpoint;
    if (server.warp) {
      final w = await warp.ensureRegistered().timeout(
            const Duration(seconds: 25),
            onTimeout: () => throw TimeoutException('WARP register timeout'),
          );
      endpoint =
          (server.endpoint?.isNotEmpty ?? false) ? server.endpoint! : w.endpoint;
      conf = warp.buildQuickConfig(w, endpoint);
    } else if (server.type == 'custom') {
      if (server.peerPublicKey == null || server.endpoint == null) {
        throw Exception('Server config adhuri hai.');
      }
      final alg = X25519();
      final kp = await alg.newKeyPair();
      final pub = await kp.extractPublicKey();
      final privBytes = await kp.extractPrivateKeyBytes();
      customClientPubKey = base64Encode(pub.bytes);
      endpoint = server.endpoint!;
      conf = '[Interface]\n'
          'PrivateKey = ${base64Encode(privBytes)}\n'
          'Address = 10.8.0.2/32\n'
          'DNS = 1.1.1.1\n'
          '\n'
          '[Peer]\n'
          'PublicKey = ${server.peerPublicKey}\n'
          'AllowedIPs = 0.0.0.0/0\n'
          'Endpoint = $endpoint\n'
          'PersistentKeepalive = 25\n';
    } else {
      throw Exception('Ye server abhi available nahi hai.');
    }
    _activeEngine = 'wireguard';
    await _wg.startVpn(
      serverAddress: endpoint,
      wgQuickConfig: conf,
      providerBundleIdentifier: 'com.ipchakra.app',
    );
    // WireGuard ka stage callback jald aata hai; tab tak watchdog sambhalega.
  }

  Future<void> _refreshIp() async {
    try {
      currentIp = await fetchExitIp().timeout(const Duration(seconds: 10));
    } catch (_) {}
    notifyListeners();
  }

  String stateLabel() {
    switch (state) {
      case VpnState.disconnected:
        return 'Disconnected';
      case VpnState.connecting:
        return 'Connecting…';
      case VpnState.connected:
        return 'Connected';
      case VpnState.disconnecting:
        return 'Disconnecting…';
      case VpnState.error:
        return 'Error';
    }
  }
}
