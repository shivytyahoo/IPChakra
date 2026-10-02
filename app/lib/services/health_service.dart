import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_server.dart';

/// Saare free servers ka health check — kaun working, kaun dead.
///
/// Har server ke host:port pe chhota TCP probe (2s timeout). Result
/// `status[serverId]` me: true = working, false = dead, missing = unchecked.
/// UI progressive update hota hai — batch complete hote hi badges flip hote hain.
class HealthService extends ChangeNotifier {
  static const _kMirrorTargets = 'health_mirror_targets';

  /// serverId -> working?
  final Map<String, bool> status = {};

  /// Abhi check ho rahe server ids.
  final Set<String> checkingIds = {};

  bool checking = false;
  DateTime? lastChecked;

  /// mirror serverId -> "host:port" (config download se bachta hai)
  final Map<String, String> _mirrorTargets = {};
  bool _mirrorCacheLoaded = false;

  bool? isWorking(String id) => status[id];
  bool isChecking(String id) => checkingIds.contains(id);

  int get workingCount => status.values.where((v) => v).length;
  int get deadCount => status.values.where((v) => !v).length;

  Future<void> checkAll(List<VpnServer> servers) async {
    if (checking) return;
    checking = true;
    notifyListeners();
    try {
      const batchSize = 20;
      for (var i = 0; i < servers.length; i += batchSize) {
        final batch = servers.skip(i).take(batchSize).toList();
        await Future.wait(batch.map(_checkOne));
        notifyListeners(); // progressive UI
      }
      lastChecked = DateTime.now();
    } finally {
      checking = false;
      checkingIds.clear();
      notifyListeners();
    }
  }

  Future<void> _checkOne(VpnServer s) async {
    checkingIds.add(s.id);
    try {
      // WARP Cloudflare ka anycast network hai — single server nahi, isliye
      // "dead" ka concept hi nahi. Hamesha working.
      if (s.source == 'warp' || s.warp) {
        status[s.id] = true;
        return;
      }
      final target = await _resolveTarget(s);
      if (target == null) {
        status[s.id] = false;
      } else if (!target.$3) {
        status[s.id] = await _tcpProbe(target.$1, target.$2);
      } else {
        status[s.id] = await _udpHostProbe(target.$1, target.$2);
      }
    } catch (_) {
      status[s.id] = false;
    } finally {
      checkingIds.remove(s.id);
    }
  }

  /// Server ka (host, port, isUdp) nikalo — source ke hisaab se.
  Future<(String, int, bool)?> _resolveTarget(VpnServer s) async {
    switch (s.source) {
      case 'vpngate':
        return _parseOvpnTarget(s.ovpnConfig);
      case 'vpnbook':
        final host = s.id.replaceFirst('vpnbook-', '');
        if (host.isEmpty) return null;
        return (host, 443, false);
      case 'mirror':
        return _mirrorTarget(s);
      case 'v2ray':
        final t = _parseSsTarget(s.shareLink);
        return t == null ? null : (t.$1, t.$2, false);
      default:
        return null;
    }
  }

  /// Mirror ka (host, port, udp) — pehli baar config se parse, phir cache.
  Future<(String, int, bool)?> _mirrorTarget(VpnServer s) async {
    if (!_mirrorCacheLoaded) {
      _mirrorCacheLoaded = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_kMirrorTargets);
        if (raw != null) {
          final map = jsonDecode(raw) as Map<String, dynamic>;
          for (final e in map.entries) {
            _mirrorTargets[e.key] = e.value.toString();
          }
        }
      } catch (_) {}
    }
    final cached = _mirrorTargets[s.id];
    if (cached != null) {
      final parts = cached.split(':');
      if (parts.length >= 2) {
        final port = int.tryParse(parts[1]);
        if (port != null) {
          final udp = parts.length >= 3 && parts[2] == 'udp';
          return (parts[0], port, udp);
        }
      }
    }
    final loader = s.configLoader;
    if (loader == null) return null;
    try {
      final cfg = await loader().timeout(const Duration(seconds: 15));
      final t = _parseOvpnTarget(cfg);
      if (t != null) {
        _mirrorTargets[s.id] = '${t.$1}:${t.$2}:${t.$3 ? 'udp' : 'tcp'}';
        unawaited(_saveMirrorCache());
      }
      return t;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveMirrorCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kMirrorTargets, jsonEncode(_mirrorTargets));
    } catch (_) {}
  }

  /// OpenVPN config se "remote HOST PORT" + proto (tcp/udp).
  (String, int, bool)? _parseOvpnTarget(String? config) {
    if (config == null) return null;
    final m = RegExp(r'^remote\s+(\S+)\s+(\d+)', multiLine: true)
        .firstMatch(config);
    if (m == null) return null;
    final port = int.tryParse(m.group(2)!);
    if (port == null) return null;
    final protoM =
        RegExp(r'^proto\s+(\S+)', multiLine: true).firstMatch(config);
    final proto = protoM?.group(1)?.toLowerCase() ?? 'tcp';
    return (m.group(1)!, port, proto.contains('udp'));
  }

  /// UDP OpenVPN server: VPN port pe TCP try karo (kuch dono sunte hain),
  /// phir host ke 443/80 — koi bhi khula to host up hai.
  Future<bool> _udpHostProbe(String host, int port) async {
    if (await _tcpProbe(host, port)) return true;
    if (port != 443 && await _tcpProbe(host, 443)) return true;
    if (port != 80 && await _tcpProbe(host, 80)) return true;
    return false;
  }

  /// ss://BASE64@host:port se host:port.
  (String, int)? _parseSsTarget(String? link) {
    if (link == null || !link.startsWith('ss://')) return null;
    try {
      final atIdx = link.indexOf('@');
      if (atIdx < 0) return null;
      final after = link.substring(atIdx + 1);
      final endIdx = after.indexOf(RegExp(r'[#/?]'));
      final hostPort = endIdx > 0 ? after.substring(0, endIdx) : after;
      // IPv6 [::1]:port bhi sambhalo
      final m = RegExp(r'^\[([^\]]+)\]:(\d+)$').firstMatch(hostPort) ??
          RegExp(r'^([^:]+):(\d+)$').firstMatch(hostPort);
      if (m == null) return null;
      final port = int.tryParse(m.group(2)!);
      if (port == null) return null;
      return (m.group(1)!, port);
    } catch (_) {
      return null;
    }
  }

  /// Chhota TCP handshake — server reachable hai ya nahi.
  Future<bool> _tcpProbe(String host, int port) async {
    try {
      final socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 2));
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  void reset() {
    status.clear();
    checkingIds.clear();
    checking = false;
    lastChecked = null;
    notifyListeners();
  }

  /// Sirf test ke liye.
  @visibleForTesting
  (String, int, bool)? debugParseRemote(String c) => _parseOvpnTarget(c);

  /// Sirf test ke liye.
  @visibleForTesting
  (String, int)? debugParseSs(String? l) => _parseSsTarget(l);
}
