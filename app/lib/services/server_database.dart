import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/vpn_server.dart';

/// The remote server-list database.
///
/// Priority: remote JSON (1-hour cache) -> local cache -> bundled
/// asset. The database is loaded at every app start, so with the
/// 1-hour staleness window an update published to servers.json in
/// the repository reaches the app on a later launch the same day —
/// no app update needed.
class ServerDatabase extends ChangeNotifier {
  static const remoteUrl =
      'https://raw.githubusercontent.com/shivytyahoo/IPChakra/main/servers.json';
  static const _kCache = 'ipchakra_servers_json';
  static const _kCacheTime = 'ipchakra_servers_time';
  static const _kLastCheck = 'ipchakra_servers_last_check';

  List<VpnServer> free = [];
  List<VpnServer> chakra = [];
  List<VpnServer> custom = [];
  int version = 0;
  String updated = '';

  /// The "generated" timestamp inside the JSON, when the publisher
  /// includes one. Parsed tolerantly: absent in older files.
  String generated = '';
  String source = 'bundled'; // remote | cache | bundled

  /// When the remote database was last checked — every attempt is
  /// recorded, success or failure, and persisted across launches.
  DateTime? lastChecked;

  List<VpnServer> get all => [...free, ...chakra, ...custom];

  VpnServer? byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  Future<void> load({bool forceRefresh = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final lastCheckMs = prefs.getInt(_kLastCheck);
    if (lastCheckMs != null) {
      lastChecked = DateTime.fromMillisecondsSinceEpoch(lastCheckMs);
    }
    final lastFetch = prefs.getInt(_kCacheTime) ?? 0;
    final stale =
        DateTime.now().millisecondsSinceEpoch - lastFetch > 1 * 3600 * 1000;

    if (forceRefresh || stale) {
      // Record every remote attempt, success or failure, so Settings
      // can show when the database was last checked.
      lastChecked = DateTime.now();
      await prefs.setInt(
          _kLastCheck, lastChecked!.millisecondsSinceEpoch);
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
    generated = j['generated']?.toString() ?? '';
    List<VpnServer> list(String k) => ((j[k] as List?) ?? [])
        .map((e) => VpnServer.fromJson(e as Map<String, dynamic>))
        .toList();
    free = list('free');
    chakra = list('chakra');
    custom = list('custom');
  }
}
