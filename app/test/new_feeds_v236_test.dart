// v2.3.6 new stealth feeds tests.
//
// 2026-11-14 live check: Pawdroid's `sub` file holds only 9 links
// (the repo pivoted to a paid app), so it is removed; three feeds
// join — 0xRadikal top100 (curated, 15-min updates), MahanKenway
// mix_sub (2-hourly) and 0xRadikal light. Samples below are real
// lines fetched from those feeds on 2026-11-14, in their exact
// on-the-wire formats (top100 is plain text with a #profile-title
// header; the other two are base64 subscriptions whose decoded
// bodies also carry #profile-title comment lines).

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/services/v2ray_service.dart';

const _top100Sample = '''
#profile-title: @Raydikalx — TOP 100
#profile-update-interval: 1
ss://YWVzLTI1Ni1nY206WlJwZ2FCZUd4dEVOSVhndmhwa1pCS3o5R25XUlMyZFljeDlPK2EyaXdOND0=@95.215.201.18:19999#US 🇺🇸 | @Raydikalx | 983667
ss://YWVzLTI1Ni1nY206WlJwZ2FCZUd4dEVOSVhndmhwa1pCS3o5R25XUlMyZFljeDlPK2EyaXdOND0=@23.150.152.38:19999#US 🇺🇸 | @Raydikalx | DFD1D5
''';

const _mahanDecoded = '''
ss://MjAyMi1ibGFrZTMtY2hhY2hhMjAtcG9seTEzMDU6OHlPM0FOV2VmdXVHczFsUktYRUNRQTFGRWh4bFdGVjJwcFFNY0JhWm81WT0@47.254.143.251:443#🇩🇪 DE | 47.254.143.2
ss://MjAyMi1ibGFrZTMtYWVzLTEyOC1nY206alViRE5zRmFtY3lEZnBtK3JJM1p5dz09@38.145.220.193:8443#🇺🇸 US | 38.145.220.193
''';

const _lightDecoded = '''
#profile-title: @Raydikalx — LIGHT
#profile-update-interval: 1
hysteria2://083417772bc618cd61f0cca23dd91680@167.179.34.31:55443?insecure=1&sni=gorbachev-new-th.kvnfreetest.uk#TH 🇹🇭 | @Raydikalx | 2373E1
hysteria2://2691cbe7c20cced8b0aeb12c812d09077e5b3eec7669fb8f@144.31.148.87:443?insecure=1&sni=replay.wwwinternetvideo.click#DE 🇩🇪 | @Raydikalx |
''';

void main() {
  test('schema is 6: v5 caches are discarded once', () {
    expect(V2RayService.cacheSchemaVersion, 6);
    expect(V2RayService.cacheSchemaMatches(5), isFalse);
    expect(V2RayService.cacheSchemaMatches(6), isTrue);
  });

  test('feed list carries the three new feeds, not Pawdroid', () {
    final keys = V2RayService.feedSourceKeys;
    expect(keys.first, 'top100',
        reason: 'the curated 15-min feed merges first');
    expect(keys, containsAll(['top100', 'mahan', 'radikallight']));
    expect(keys, isNot(contains('pawdroid')));
    expect(keys, isNot(contains('epodonios')));
  });

  test('top100 plain text: #profile-title header is skipped', () {
    final links = V2RayService.debugExtractLinks(_top100Sample);
    expect(links, hasLength(2));
    expect(links.first, startsWith('ss://'));
    expect(links.first, contains('95.215.201.18:19999'));
  });

  test('MahanKenway base64 subscription decodes to its links', () {
    final body = base64Encode(utf8.encode(_mahanDecoded));
    final links = V2RayService.debugExtractFromSubscriptionBody(body);
    expect(links, hasLength(2));
    expect(links.first, contains('47.254.143.251:443'));
  });

  test('Radikal light base64: comment lines inside are skipped', () {
    final body = base64Encode(utf8.encode(_lightDecoded));
    final links = V2RayService.debugExtractFromSubscriptionBody(body);
    expect(links, hasLength(2));
    expect(links, everyElement(startsWith('hysteria2://')));
  });

  test('merge attributes a shared link to the earliest feed', () {
    final a = 'ss://x@1.2.3.4:1#a';
    final b = 'ss://x@5.6.7.8:2#b';
    final merged = V2RayService.debugMergeFeedLinks([
      ('top100', [a]),
      ('mahan', [a, b]),
    ]);
    expect(merged, hasLength(2));
    expect(merged[0].source, 'top100');
    expect(merged[1].source, 'mahan');
  });
}
