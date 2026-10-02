import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_server.dart';

/// Server list ka remote database.
///
/// Priority: remote JSON (12 ghante ka cache) -> local cache -> bundled asset.
/// Matlab: servers.json GitHub pe update hote hi app me naye servers
/// aa jayenge - app update ki zaroorat nahi.
class ServerDatabase extends ChangeNotifier {
  static const remoteUrl =
      'https://raw.githubusercontent.com/shivytyahoo/IPChakra/main/servers.json';
  static const _kCache = 'ipchakra_servers_json';
  static const _kCacheTime = 'ipchakra_servers_time';

  List<VpnServer> free = [];
  List<VpnServer> chakra = [];
  List<VpnServer> custom = [];
  int version = 0;
  String updated = '';
  String source = 'bundled'; // remote | cache | bundled

  List<VpnServer> get all => [...free, ...chakra, ...custom];

  VpnServer? byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> load({bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final lastFetch = prefs.getInt(_kCacheTime) ?? 0;
    final stale =
        DateTime.now().millisecondsSinceEpoch - lastFetch > 12 * 3600 * 1000;

    if (forceRefresh || stale) {
      try {
        final r = await http
            .get(Uri.parse(remoteUrl))
            .timeout(const Duration(seconds: 15));
        if (r.statusCode == 200 && r.body.contains('"free"')) {
          await prefs.setString(_kCache, r.body);
          await prefs.setInt(
              _kCacheTime, DateTime.now().millisecondsSinceEpoch);
          _parse(r.body);
          source = 'remote';
          notifyListeners();
          return;
        }
      } catch (_) {
        // neeche fallback
      }
    }

    final cached = prefs.getString(_kCache);
    if (cached != null) {
      try {
        _parse(cached);
        source = 'cache';
        notifyListeners();
        return;
      } catch (_) {}
    }

    final bundled = await rootBundle.loadString('assets/servers.json');
    _parse(bundled);
    source = 'bundled';
    notifyListeners();
  }

  void _parse(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    version = (j['version'] as num?)?.toInt() ?? 0;
    updated = j['updated']?.toString() ?? '';
    List<VpnServer> list(String k) => ((j[k] as List?) ?? [])
        .map((e) => VpnServer.fromJson(e as Map<String, dynamic>))
        .toList();
    free = list('free');
    chakra = list('chakra');
    custom = list('custom');
  }
}
