import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_server.dart';

/// VPNGate (University of Tsukuba, Japan) ka free server network.
///
/// Volunteer-run hazaron servers, duniya bhar ke deshon me — sab OpenVPN.
/// List seedha vpngate.net se aati hai (12 ghante ka cache), isliye hamesha
/// taaza rehti hai. Credentials public hain: vpn / vpn.
class VpnGateService extends ChangeNotifier {
  static const apiUrl = 'http://www.vpngate.net/api/iphone/';
  static const _kCsv = 'vpngate_csv';
  static const _kTime = 'vpngate_time';

  /// VPNGate ke public credentials (unki site pe likhe hain).
  static const username = 'vpn';
  static const password = 'vpn';

  List<VpnServer> servers = [];
  bool loading = false;
  String source = 'none'; // remote | cache | none
  String? error;

  /// Country code -> flag emoji.
  static const flags = {
    'JP': '🇯🇵', 'KR': '🇰🇷', 'US': '🇺🇸', 'DE': '🇩🇪', 'GB': '🇬🇧',
    'FR': '🇫🇷', 'NL': '🇳🇱', 'CA': '🇨🇦', 'AU': '🇦🇺', 'SG': '🇸🇬',
    'IN': '🇮🇳', 'BR': '🇧🇷', 'RU': '🇷🇺', 'UA': '🇺🇦', 'PL': '🇵🇱',
    'IT': '🇮🇹', 'ES': '🇪🇸', 'SE': '🇸🇪', 'NO': '🇳🇴', 'FI': '🇫🇮',
    'DK': '🇩🇰', 'CH': '🇨🇭', 'AT': '🇦🇹', 'BE': '🇧🇪', 'IE': '🇮🇪',
    'PT': '🇵🇹', 'CZ': '🇨🇿', 'HU': '🇭🇺', 'RO': '🇷🇴', 'BG': '🇧🇬',
    'GR': '🇬🇷', 'TR': '🇹🇷', 'IL': '🇮🇱', 'AE': '🇦🇪', 'SA': '🇸🇦',
    'ZA': '🇿🇦', 'EG': '🇪🇬', 'NG': '🇳🇬', 'KE': '🇰🇪', 'MX': '🇲🇽',
    'AR': '🇦🇷', 'CL': '🇨🇱', 'CO': '🇨🇴', 'PE': '🇵🇪', 'VE': '🇻🇪',
    'TH': '🇹🇭', 'VN': '🇻🇳', 'MY': '🇲🇾', 'ID': '🇮🇩', 'PH': '🇵🇭',
    'TW': '🇹🇼', 'HK': '🇭🇰', 'CN': '🇨🇳', 'MN': '🇲🇳', 'KZ': '🇰🇿',
    'UZ': '🇺🇿', 'PK': '🇵🇰', 'BD': '🇧🇩', 'LK': '🇱🇰', 'NP': '🇳🇵',
    'MM': '🇲🇲', 'KH': '🇰🇭', 'LA': '🇱🇦', 'NZ': '🇳🇿', 'IS': '🇮🇸',
    'LU': '🇱🇺', 'MT': '🇲🇹', 'CY': '🇨🇾', 'HR': '🇭🇷', 'SI': '🇸🇮',
    'SK': '🇸🇰', 'EE': '🇪🇪', 'LV': '🇱🇻', 'LT': '🇱🇹', 'MD': '🇲🇩',
    'GE': '🇬🇪', 'AM': '🇦🇲', 'AZ': '🇦🇿', 'BY': '🇧🇾', 'RS': '🇷🇸',
    'BA': '🇧🇦', 'AL': '🇦🇱', 'MK': '🇲🇰', 'ME': '🇲🇪',
  };

  static String flagFor(String code) => flags[code.toUpperCase()] ?? '🌐';

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

      String? csv;
      if (forceRefresh || stale) {
        try {
          final r = await http
              .get(Uri.parse(apiUrl))
              .timeout(const Duration(seconds: 30));
          if (r.statusCode == 200 && r.body.contains('#HostName')) {
            csv = r.body;
            await prefs.setString(_kCsv, csv);
            await prefs.setInt(
                _kTime, DateTime.now().millisecondsSinceEpoch);
            source = 'remote';
          }
        } catch (_) {
          // neeche cache try hoga
        }
      }
      csv ??= prefs.getString(_kCsv);
      if (csv != null && source != 'remote') source = 'cache';
      if (csv != null) {
        servers = _parse(csv);
      } else {
        error = 'VPNGate list nahi mili. Internet check karke refresh karo.';
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  List<VpnServer> _parse(String csvText) {
    // Pehli do lines (*vpn_servers aur #header) hatao.
    final dataLines = csvText
        .split('\n')
        .where((l) => l.isNotEmpty && !l.startsWith('*') && !l.startsWith('#'))
        .join('\n');
    final rows = Csv().decode(dataLines);
    final out = <VpnServer>[];
    for (final r in rows) {
      // #HostName,IP,Score,Ping,Speed,CountryLong,CountryShort,NumVpnSessions,
      //  Uptime,TotalUsers,TotalTraffic,LogType,Operator,Message,OpenVPN_ConfigData_Base64
      if (r.length < 15) continue;
      try {
        final host = r[0].toString();
        final ip = r[1].toString();
        final ping = int.tryParse(r[3].toString()) ?? 9999;
        final speed = int.tryParse(r[4].toString()) ?? 0;
        final countryLong = r[5].toString();
        final countryShort = r[6].toString();
        final sessions = int.tryParse(r[7].toString()) ?? 0;
        final b64 = r[14].toString().trim();
        if (b64.isEmpty) continue;
        final config = utf8.decode(base64Decode(b64));
        if (!config.contains('<ca>')) continue;
        final mbps = (speed / 1000000).toStringAsFixed(0);
        out.add(VpnServer(
          id: 'vpngate-$ip',
          name: '$countryLong ${host.split('-').last}',
          country: countryLong,
          flag: flagFor(countryShort),
          type: 'free',
          protocol: 'openvpn',
          note: '$ping ms • $mbps Mbps • $sessions users',
          ovpnConfig: config,
          pingMs: ping,
          source: 'vpngate',
        ));
      } catch (_) {
        continue;
      }
    }
    out.sort((a, b) => (a.pingMs ?? 9999).compareTo(b.pingMs ?? 9999));
    return out;
  }

  /// Country-wise group, har group me sabse tez server pehle.
  Map<String, List<VpnServer>> byCountry() {
    final map = <String, List<VpnServer>>{};
    for (final s in servers) {
      map.putIfAbsent(s.country, () => []).add(s);
    }
    return map;
  }

  /// Sirf test ke liye.
  @visibleForTesting
  List<VpnServer> debugParse(String csvText) => _parse(csvText);
}
