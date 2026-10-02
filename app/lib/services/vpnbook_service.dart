import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_server.dart';
import 'vpngate_service.dart';

/// VPNBook ke free OpenVPN servers.
///
/// username hamesha "vpnbook", password weekly rotate hota hai (site se
/// scrape hota hai). Config API se on-demand aati hai:
///   GET https://www.vpnbook.com/api/openvpn?hostname=X&protocol=tcp443
/// Servers: US, CA, UK, DE, FR, PL.
class VpnBookService extends ChangeNotifier {
  static const _pageUrl = 'https://www.vpnbook.com/freevpn/openvpn';
  static const _apiUrl = 'https://www.vpnbook.com/api/openvpn';
  static const _kHosts = 'vpnbook_hosts';
  static const _kPass = 'vpnbook_pass';
  static const _kTime = 'vpnbook_time';

  static const username = 'vpnbook';
  static const _protocol = 'tcp443'; // firewall-friendly

  /// hostname prefix -> country.
  static const _countries = {
    'us': ['United States', '🇺🇸'],
    'ca': ['Canada', '🇨🇦'],
    'uk': ['United Kingdom', '🇬🇧'],
    'de': ['Germany', '🇩🇪'],
    'fr': ['France', '🇫🇷'],
    'pl': ['Poland', '🇵🇱'],
  };

  List<VpnServer> servers = [];
  String? password;
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

      List<String>? hosts;
      String? pass;
      if (forceRefresh || stale) {
        try {
          final r = await http.get(Uri.parse(_pageUrl),
              headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 14)'}).timeout(
              const Duration(seconds: 30));
          if (r.statusCode == 200) {
            final scraped = _scrape(r.body);
            hosts = scraped.hosts;
            pass = scraped.password;
            if (hosts.isNotEmpty && (pass ?? '').isNotEmpty) {
              await prefs.setStringList(_kHosts, hosts);
              await prefs.setString(_kPass, pass!);
              await prefs.setInt(
                  _kTime, DateTime.now().millisecondsSinceEpoch);
            }
          }
        } catch (_) {
          // neeche cache
        }
      }
      hosts ??= prefs.getStringList(_kHosts);
      pass ??= prefs.getString(_kPass);
      password = pass;
      if (hosts != null && hosts.isNotEmpty && (pass ?? '').isNotEmpty) {
        servers = hosts.map((h) => _toServer(h, pass!)).toList();
      } else {
        error = 'VPNBook list nahi mili. Refresh karo.';
      }
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  VpnServer _toServer(String host, String pass) {
    final prefix = host.split('.').first.replaceAll(RegExp(r'[0-9]'), '');
    final c = _countries[prefix] ?? ['Europe', '🇪🇺'];
    return VpnServer(
      id: 'vpnbook-$host',
      name: '${c[0]} ${host.split('.').first}',
      country: c[0],
      flag: c[1],
      type: 'free',
      protocol: 'openvpn',
      note: 'VPNBook • TCP 443',
      source: 'vpnbook',
      configLoader: () => fetchConfig(host),
      // Plugin ke username/password params me jaayega (documented path).
      authUsername: username,
      authPassword: pass,
    );
  }

  /// Sirf test ke liye.
  @visibleForTesting
  ({List<String> hosts, String? password}) debugScrape(String html) =>
      _scrape(html);

  /// Sirf test ke liye.
  @visibleForTesting
  VpnServer debugToServer(String host) => _toServer(host, 'testpass');

  /// Ek server ka .ovpn config lao (credentials embedded).
  Future<String> fetchConfig(String hostname) async {
    final pass = password;
    if ((pass ?? '').isEmpty) {
      throw Exception('VPNBook password nahi mila. List refresh karo.');
    }
    final r = await http.get(
      Uri.parse('$_apiUrl?hostname=$hostname&protocol=$_protocol'),
      headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android 14)'},
    ).timeout(const Duration(seconds: 30));
    if (r.statusCode != 200 || !r.body.contains('<ca>')) {
      throw Exception('VPNBook config nahi mili.');
    }
    // bare "auth-user-pass" ko inline credentials se badlo
    final lines = r.body.split('\n');
    final out = <String>[];
    for (final line in lines) {
      if (line.trim() == 'auth-user-pass') {
        out.add('<auth-user-pass>');
        out.add(username);
        out.add(pass!);
        out.add('</auth-user-pass>');
      } else {
        out.add(line);
      }
    }
    return out.join('\n');
  }

  ({List<String> hosts, String? password}) _scrape(String html) {
    final hostRe = RegExp(r'\b([a-z0-9]+\.vpnbook\.com)\b');
    final seen = <String>{};
    final hosts = <String>[];
    for (final m in hostRe.allMatches(html)) {
      final h = m.group(1)!.toLowerCase();
      if (!h.contains('www') && seen.add(h)) hosts.add(h);
    }
    String? password;
    final codeRe = RegExp(r'<code[^>]*>([^<]{4,60})</code>');
    for (final m in codeRe.allMatches(html)) {
      final val = m.group(1)!.trim();
      if (val.isEmpty || val == 'vpnbook') continue;
      if (val.startsWith('bc1') ||
          val.startsWith('0x') ||
          val.startsWith('1') ||
          val.startsWith('3') ||
          val.startsWith('L') ||
          val.startsWith('M')) {
        continue; // crypto wallet
      }
      if (val.length <= 20) {
        password = val;
        break;
      }
    }
    return (hosts: hosts, password: password);
  }

  static String flagFor(String country) =>
      VpnGateService.flagFor(_codeFor(country));

  static String _codeFor(String country) {
    for (final e in _countries.entries) {
      if (e.value[0] == country) return e.key.toUpperCase();
    }
    return '';
  }
}
