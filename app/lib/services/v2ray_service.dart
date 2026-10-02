import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_server.dart';
import 'vpngate_service.dart';

/// Free V2Ray/Xray servers (Shadowsocks links).
///
/// Source: V2RayAggregator (GitHub, roz update hota hai) ki Eternity.txt —
/// 150-200+ ss:// links. Links khud me password rakhte hain, alag login nahi.
/// Connect flutter_v2ray_client (Xray core) se hota hai.
class V2RayService extends ChangeNotifier {
  static const _url =
      'https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/Eternity.txt';
  static const _kList = 'v2ray_list';
  static const _kTime = 'v2ray_time';

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

      List<String>? links;
      if (forceRefresh || stale) {
        try {
          final r = await http.get(Uri.parse(_url)).timeout(
              const Duration(seconds: 30));
          if (r.statusCode == 200 && r.body.contains('ss://')) {
            links = r.body
                .split('\n')
                .map((l) => l.trim())
                .where((l) => l.startsWith('ss://'))
                .toList();
            if (links.isNotEmpty) {
              await prefs.setStringList(_kList, links);
              await prefs.setInt(
                  _kTime, DateTime.now().millisecondsSinceEpoch);
            }
          }
        } catch (_) {
          // neeche cache
        }
      }
      links ??= prefs.getStringList(_kList);
      if (links != null && links.isNotEmpty) {
        servers = links
            .map(_toServer)
            .whereType<VpnServer>()
            .toList();
      } else {
        error = 'V2Ray list nahi mili. Refresh karo.';
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  VpnServer? _toServer(String link) {
    try {
      // ss://BASE64@host:port#remark  (remark URL-encoded hai)
      final hashIdx = link.indexOf('#');
      final remark = hashIdx > 0
          ? Uri.decodeComponent(link.substring(hashIdx + 1))
          : '';
      // remark jaise: "🇨🇦🇺🇸CA-185.156.47.97-0424" -> code "CA"
      final codeMatch = RegExp(r'([A-Z]{2})-').firstMatch(remark);
      final code = codeMatch?.group(1) ?? '';
      final country = _countryName(code);
      // host nikalo
      final atIdx = link.indexOf('@');
      String host = '';
      if (atIdx > 0) {
        final after = link.substring(atIdx + 1);
        final endIdx = after.indexOf(RegExp(r'[#/?]'));
        final hostPort = endIdx > 0 ? after.substring(0, endIdx) : after;
        host = hostPort.split(':').first;
      }
      return VpnServer(
        id: 'v2ray-${link.hashCode}',
        name: '$country $host'.trim(),
        country: country,
        flag: VpnGateService.flagFor(code),
        type: 'free',
        protocol: 'v2ray',
        note: 'V2Ray • Shadowsocks',
        source: 'v2ray',
        shareLink: link,
      );
    } catch (_) {
      return null;
    }
  }

  static const _names = {
    'US': 'United States', 'CA': 'Canada', 'GB': 'United Kingdom',
    'DE': 'Germany', 'FR': 'France', 'NL': 'Netherlands',
    'SG': 'Singapore', 'JP': 'Japan', 'KR': 'South Korea',
    'AU': 'Australia', 'IN': 'India', 'BR': 'Brazil',
    'RU': 'Russia', 'TR': 'Turkey', 'AE': 'UAE',
    'IT': 'Italy', 'ES': 'Spain', 'PL': 'Poland',
    'SE': 'Sweden', 'CH': 'Switzerland', 'HK': 'Hong Kong',
    'TW': 'Taiwan', 'VN': 'Vietnam', 'TH': 'Thailand',
    'ID': 'Indonesia', 'MY': 'Malaysia', 'PH': 'Philippines',
    'ZA': 'South Africa', 'MX': 'Mexico', 'AR': 'Argentina',
    'CL': 'Chile', 'CO': 'Colombia', 'IR': 'Iran',
  };

  static String _countryName(String code) =>
      _names[code.toUpperCase()] ?? (code.isNotEmpty ? code : 'Unknown');

  /// Sirf test ke liye.
  @visibleForTesting
  VpnServer? debugToServer(String link) => _toServer(link);
}
