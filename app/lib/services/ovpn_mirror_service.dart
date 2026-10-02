import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_server.dart';
import 'vpngate_service.dart';

/// Community-maintained free .ovpn mirror (GitHub).
///
/// 18 countries ke free OpenVPN configs — FOV (FreeOpenVPN) aur IPS (IPSpeed).
/// Inme alag se username/password nahi chahiye. File list GitHub API se,
/// config on-demand raw.githubusercontent.com se aati hai.
class OvpnMirrorService extends ChangeNotifier {
  static const _repo = 'aunghtetp/.ovpn';
  static const _branch = 'main';
  static const _kList = 'mirror_list';
  static const _kTime = 'mirror_time';

  /// dir -> [country name, code]
  static const _dirs = {
    'Canada': ['Canada', 'CA'],
    'Emirates': ['UAE', 'AE'],
    'France': ['France', 'FR'],
    'Germany': ['Germany', 'DE'],
    'India': ['India', 'IN'],
    'Indonesia': ['Indonesia', 'ID'],
    'Italy': ['Italy', 'IT'],
    'Japan': ['Japan', 'JP'],
    'Netherlands': ['Netherlands', 'NL'],
    'Poland': ['Poland', 'PL'],
    'Romania': ['Romania', 'RO'],
    'Russia': ['Russia', 'RU'],
    'South Korea': ['South Korea', 'KR'],
    'Sweden': ['Sweden', 'SE'],
    'Thailand': ['Thailand', 'TH'],
    'Turkey': ['Turkey', 'TR'],
    'UK': ['United Kingdom', 'GB'],
    'USA': ['United States', 'US'],
  };

  List<VpnServer> servers = [];
  bool loading = false;
  String? error;

  Future<void> load({bool forceRefresh = false}) async {
    if (loading) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastFetch = prefs.getInt(_kTime) ?? 0;
      final stale =
          DateTime.now().millisecondsSinceEpoch - lastFetch > 12 * 3600 * 1000;

      List<Map<String, String>>? files;
      if (forceRefresh || stale) {
        try {
          files = await _fetchFileList();
          if (files.isNotEmpty) {
            await prefs.setString(_kList, jsonEncode(files));
            await prefs.setInt(
                _kTime, DateTime.now().millisecondsSinceEpoch);
          }
        } catch (_) {
          // neeche cache
        }
      }
      files ??= (jsonDecode(prefs.getString(_kList) ?? '[]') as List)
          .map((e) => Map<String, String>.from(e as Map))
          .toList();
      if (files.isNotEmpty) {
        servers = files.map(_toServer).toList();
      } else {
        error = 'Mirror list nahi mili. Refresh karo.';
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  /// GitHub API se har country dir ki .ovpn file list.
  Future<List<Map<String, String>>> _fetchFileList() async {
    final out = <Map<String, String>>[];
    for (final dir in _dirs.keys) {
      try {
        final r = await http.get(
          Uri.parse(
              'https://api.github.com/repos/$_repo/contents/${Uri.encodeComponent(dir)}?ref=$_branch'),
          headers: {'User-Agent': 'IPChakra'},
        ).timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) continue;
        final items = jsonDecode(r.body) as List;
        for (final it in items) {
          final name = it['name']?.toString() ?? '';
          // FOV/IPS configs (VBK = VPNBook, wo alag service me hai)
          if (!name.endsWith('.ovpn')) continue;
          if (!(name.startsWith('FOV_') || name.startsWith('IPS_'))) continue;
          final proto = name.contains('_udp') ? 'UDP' : 'TCP';
          out.add({
            'dir': dir,
            'name': name,
            'proto': proto,
            'url':
                'https://raw.githubusercontent.com/$_repo/$_branch/${Uri.encodeComponent(dir)}/${Uri.encodeComponent(name)}',
          });
        }
      } catch (_) {
        continue;
      }
      // GitHub API rate limit se bachne ke liye halka gap
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return out;
  }

  VpnServer _toServer(Map<String, String> f) {
    final dir = f['dir']!;
    final info = _dirs[dir] ?? [dir, ''];
    final country = info[0];
    final code = info[1];
    final name = f['name']!;
    // FOV_USA_174.51.166.85_tcp.ovpn -> "174.51.166.85"
    final ip = RegExp(r'(\d+\.\d+\.\d+\.\d+)').firstMatch(name)?.group(1) ?? '';
    return VpnServer(
      id: 'mirror-$dir-$name',
      name: '$country ${ip.isNotEmpty ? ip : name}',
      country: country,
      flag: VpnGateService.flagFor(code),
      type: 'free',
      protocol: 'openvpn',
      note: 'Mirror • ${f['proto']} • no login',
      source: 'mirror',
      configLoader: () => _fetchConfig(f['url']!),
    );
  }

  Future<String> _fetchConfig(String url) async {
    final r = await http.get(Uri.parse(url),
        headers: {'User-Agent': 'IPChakra'}).timeout(
        const Duration(seconds: 30));
    if (r.statusCode != 200 || !r.body.contains('<ca>')) {
      throw Exception('Config download nahi hui.');
    }
    // Agar bare auth-user-pass hai aur credentials nahi pata, to bhi try karo
    // (kuch configs bina auth ke chalte hain).
    return r.body;
  }
}
