import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/vpn_server.dart';

/// The user's own server shortlists: favourites (starred servers)
/// and recents (the last few servers that connected successfully).
///
/// Both lists store stable server ids only (see
/// [V2RayService.stableLinkId] for why ids are trustworthy across
/// launches), so a favourite survives a feed refresh untouched as
/// long as its id is still in the pool; [pruneTo] drops the ids a
/// full refresh proved are gone. Recents are recorded by
/// [VpnController] at the moment a connection is verified — never
/// for an attempt that merely started — newest first, capped at
/// [recentCap].
class UserListsService extends ChangeNotifier {
  static const _kFavourites = 'fav_server_ids';
  static const _kRecents = 'recent_server_ids';

  /// How many recent servers are kept.
  static const recentCap = 5;

  final Set<String> _favourites = {};
  List<String> _recents = [];
  bool _loaded = false;

  bool get loaded => _loaded;

  /// The favourited server ids.
  Set<String> get favourites => Set.unmodifiable(_favourites);

  /// Recently connected server ids, newest first.
  List<String> get recents => List.unmodifiable(_recents);

  bool isFavourite(String serverId) => _favourites.contains(serverId);

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _favourites
        ..clear()
        ..addAll(prefs.getStringList(_kFavourites) ?? const []);
      _recents = List.of(prefs.getStringList(_kRecents) ?? const []);
    } catch (_) {
      // Persistence is best-effort; the lists simply start empty.
    }
    _loaded = true;
    notifyListeners();
  }

  /// Star or unstar a server. Persists immediately.
  Future<void> toggleFavourite(String serverId) async {
    if (!_favourites.remove(serverId)) {
      _favourites.add(serverId);
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kFavourites, _favourites.toList());
    } catch (_) {
      // The in-memory list stays correct for this session.
    }
  }

  /// Record a verified successful connection to [server]: it moves
  /// to the front of recents (deduplicated, capped). A server that
  /// is already the most recent entry changes nothing — engines can
  /// report "connected" more than once for one session, and that
  /// must not cause pointless writes.
  Future<void> recordConnect(VpnServer server) async {
    if (_recents.isNotEmpty && _recents.first == server.id) return;
    _recents = nextRecents(_recents, server.id);
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kRecents, _recents);
    } catch (_) {
      // The in-memory list stays correct for this session.
    }
  }

  /// The recents list after [id] connects: deduplicated, newest
  /// first, capped at [cap]. Pure — unit-tested.
  static List<String> nextRecents(
    List<String> current,
    String id, {
    int cap = recentCap,
  }) {
    final out = <String>[
      id,
      for (final e in current)
        if (e != id) e,
    ];
    return out.length <= cap ? out : out.sublist(0, cap);
  }

  /// Drop favourites and recents whose ids are not in [validIds].
  /// Callers pass the id universe of a *complete* refresh (every
  /// source reloaded), so an id missing here is genuinely gone from
  /// the pool — it is dropped silently, exactly as specified.
  Future<void> pruneTo(Set<String> validIds) async {
    final favBefore = _favourites.length;
    final recBefore = _recents.length;
    _favourites.removeWhere((id) => !validIds.contains(id));
    _recents = _recents.where(validIds.contains).toList();
    if (_favourites.length == favBefore && _recents.length == recBefore) {
      return;
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kFavourites, _favourites.toList());
      await prefs.setStringList(_kRecents, _recents);
    } catch (_) {
      // The in-memory lists stay correct for this session.
    }
  }
}
