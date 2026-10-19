// Regression tests for the Stealth "dead on open" device report
// (v2.3.4, S25): on the first launch after an upgrade the pool
// load forced a full refresh — 13 feed URLs fetched one after
// another, each with a 30 s timeout — and the cached list was only
// applied AFTER the fetch finished. On a slow or hanging feed
// host the Stealth tab therefore sat empty for minutes: no
// servers, no health checks, and a Connect tap that did nothing.
//
// The fixes locked here:
//  1. Cache-first: a stored last-good list is put on screen (and
//     handed to the health checker) immediately, before fetching;
//     the refresh rebuilds the list again when it lands, and a
//     failed refresh keeps the cached list.
//  2. Feeds are fetched concurrently, so a refresh costs the
//     slowest feed, not the sum of all feeds.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ipchakra/services/v2ray_service.dart';

const _cachedLink =
    'vless://u@cached.example.com:443?security=reality#CachedOne';
const _freshLink = 'vless://u@fresh.example.com:443?security=tls#FreshOne';

void _seedCache() {
  SharedPreferences.setMockInitialValues({
    'v2ray_cache_schema': V2RayService.cacheSchemaVersion,
    'v2ray_list': V2RayService.encodeCachedFeedLinks(
      [StealthFeedLink(_cachedLink, 'eternity')],
    ),
    'v2ray_time': 0, // long stale: a refresh must run
  });
}

/// A mock client where every feed takes [delay] and answers with
/// one fresh link; the private stealth.json simply 404s.
MockClient _slowClient(Duration delay) {
  return MockClient((request) async {
    if (request.url.toString().contains('stealth.json')) {
      return http.Response('{}', 404);
    }
    await Future<void>.delayed(delay);
    return http.Response(_freshLink, 200,
        headers: {'content-type': 'text/plain; charset=utf-8'});
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cache-first: the stored list is visible while the refresh '
      'is still running, and the refresh replaces it when done',
      () async {
    _seedCache();
    await http.runWithClient(() async {
      final svc = V2RayService();
      final loading = svc.load();
      // Give load() a moment to reach the fetch stage; every feed
      // takes 400 ms, so the refresh cannot have finished yet.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(svc.loading, isTrue);
      expect(
        svc.servers.any((s) => s.name.contains('CachedOne')),
        isTrue,
        reason: 'the cached list must be on screen during the fetch',
      );
      await loading;
      expect(
        svc.servers.any((s) => s.name.contains('FreshOne')),
        isTrue,
        reason: 'the refresh must rebuild the list when it lands',
      );
    }, () => _slowClient(const Duration(milliseconds: 400)));
  });

  test('a failed refresh keeps the cached list (last-good wins)',
      () async {
    _seedCache();
    final failing = MockClient((request) async {
      if (request.url.toString().contains('stealth.json')) {
        return http.Response('{}', 404);
      }
      return http.Response('nope', 500);
    });
    await http.runWithClient(() async {
      final svc = V2RayService();
      await svc.load();
      expect(svc.servers.any((s) => s.name.contains('CachedOne')),
          isTrue);
    }, () => failing);
  });

  test('feeds are fetched concurrently: the refresh costs the '
      'slowest feed, not the sum of all feeds', () async {
    SharedPreferences.setMockInitialValues({
      'v2ray_cache_schema': V2RayService.cacheSchemaVersion,
      'v2ray_time': 0,
    });
    // 13 feed URLs at 400 ms each: sequential fetching would take
    // over 5 s. Concurrent fetching is bounded by the slowest
    // single feed (MatinGhanbari's five files: ~2 s).
    final sw = Stopwatch()..start();
    await http.runWithClient(() async {
      final svc = V2RayService();
      await svc.load();
      expect(svc.servers, isNotEmpty);
    }, () => _slowClient(const Duration(milliseconds: 400)));
    sw.stop();
    expect(sw.elapsed, lessThan(const Duration(milliseconds: 4500)),
        reason: 'sequential fetching would exceed 5 s');
  });

  test('the cached list survives a base64 subscription body too',
      () async {
    _seedCache();
    final sub = MockClient((request) async {
      if (request.url.toString().contains('stealth.json')) {
        return http.Response('{}', 404);
      }
      // Subscription feeds answer base64; plain feeds accept it as
      // well (extraction falls back cleanly). Either path must end
      // with servers on screen, never an empty pool.
      return http.Response(base64Encode(utf8.encode(_freshLink)), 200);
    });
    await http.runWithClient(() async {
      final svc = V2RayService();
      await svc.load();
      expect(svc.servers, isNotEmpty);
    }, () => sub);
  });
}
