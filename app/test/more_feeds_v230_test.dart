// Tests for the v2.3.0 "More Servers" release: the five new public
// stealth feeds (sNSub, Au1rxx, MatinGhanbari, NoMoreWalls, Barry-Far)
// and the attributed merge they feed into.
//
// The properties pinned here:
// - every new feed's wire format parses through the production
//   extraction helpers (plain lists, base64 subscriptions, and the
//   per-protocol base64 files whose decoded bodies start with
//   #-prefixed profile headers);
// - a dead or empty feed is a silent no-op;
// - deduplication is by the full link string across ALL feeds, and
//   the surviving copy is attributed to the highest-priority feed
//   (the pre-tested sources first);
// - the attributed list survives the cache round-trip;
// - the tier cap keeps its floors (Reality >= 175, Hysteria2 >= 45)
//   and pre-tested sources win quota slots when tiers compete.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/services/v2ray_service.dart';

const _reality = 'vless://u@a.example.com:443?security=reality#R1';
const _reality2 = 'vless://u@b.example.com:443?security=reality#R2';
const _tls = 'trojan://pw@d.example.com:443#J1';
const _ss = 'ss://YWVzLTI1Ni1nY206cGFzcw==@c.example.com:8388#S1';
const _hy2 = 'hysteria2://pw@h.example.com:443?sni=h#H1';

String _b64(String plain) => base64Encode(utf8.encode(plain));

void main() {
  group('new feed formats parse', () {
    test('NoMoreWalls plain list (list_raw.txt shape)', () {
      // The real file mixes vmess/vless/trojan/ss/hy2 lines with a
      // few non-link lines; only valid share links survive.
      const body = '$_hy2\n'
          'vless://u@x.example.com:443?security=tls#NMW-TLS\n'
          '$_ss\n'
          'not a link at all\n'
          '$_reality\n';
      final links = V2RayService.debugExtractLinks(body);
      expect(links.length, 4);
      expect(links, contains(_hy2));
      expect(links, contains(_reality));
    });

    test('MatinGhanbari per-protocol file (base64 body, header lines)',
        () {
      // The real files are one base64 blob whose decoded body opens
      // with #-prefixed profile/subscription headers, then links.
      final body = _b64('#profile-title: MatinGhanbari\n'
          '#subscription-userinfo: upload=0; download=0; total=0\n'
          '$_reality\n'
          '$_reality2\n');
      final links = V2RayService.debugExtractFromSubscriptionBody(body);
      expect(links, [_reality, _reality2]);
    });

    test('Au1rxx base64 subscription (hy2-heavy mix)', () {
      final body = _b64('$_hy2\n$_ss\n$_tls');
      final links = V2RayService.debugExtractFromSubscriptionBody(body);
      expect(links.length, 3);
      expect(links, contains(_hy2));
    });

    test('sNSub best59 base64 subscription', () {
      final body = _b64('$_reality\n$_ss');
      final links = V2RayService.debugExtractFromSubscriptionBody(body);
      expect(links, [_reality, _ss]);
    });

    test('Barry-Far plain list carries #-prefixed header lines', () {
      const body = '#profile-title: base64:QmFycnktZmFy\n'
          '#profile-update-interval: 1\n'
          '#subscription-userinfo: upload=0; download=0\n'
          '$_reality\n'
          '$_tls\n';
      final links = V2RayService.debugExtractLinks(body);
      expect(links, [_reality, _tls]);
    });
  });

  group('a dead feed is a silent no-op', () {
    test('empty and 404 bodies extract nothing', () {
      expect(V2RayService.debugExtractLinks(''), isEmpty);
      expect(V2RayService.debugExtractLinks('404: Not Found'), isEmpty);
      expect(
        V2RayService.debugExtractFromSubscriptionBody(''),
        isEmpty,
      );
      expect(
        V2RayService.debugExtractFromSubscriptionBody('404: Not Found'),
        isEmpty,
      );
    });

    test('a merge with dead feeds keeps the live ones untouched', () {
      final merged = V2RayService.debugMergeFeedLinks([
        ('snsub', const []),
        ('au1rxx', const []),
        ('epodonios', const [_reality]),
        ('barryfar', const []),
      ]);
      expect(merged.length, 1);
      expect(merged.single.link, _reality);
      expect(merged.single.source, 'epodonios');
    });
  });

  group('dedupe and attribution across old and new feeds', () {
    test('a link in five feeds ships once, credited to the earliest',
        () {
      final merged = V2RayService.debugMergeFeedLinks([
        ('snsub', const [_reality]),
        ('au1rxx', const [_reality, _tls]),
        ('epodonios', const [_reality, _ss]),
        ('nomorewalls', const [_reality]),
        ('barryfar', const [_reality, _hy2]),
      ]);
      expect(merged.length, 4);
      final byLink = {for (final l in merged) l.link: l.source};
      expect(byLink[_reality], 'snsub');
      expect(byLink[_tls], 'au1rxx');
      expect(byLink[_ss], 'epodonios');
      expect(byLink[_hy2], 'barryfar');
    });

    test('an established feed beats a bulk feed on a shared link', () {
      final merged = V2RayService.debugMergeFeedLinks([
        ('epodonios', const [_reality]),
        ('barryfar', const [_reality]),
      ]);
      expect(merged.single.source, 'epodonios');
    });

    test('merged order follows feed priority', () {
      final merged = V2RayService.debugMergeFeedLinks([
        ('snsub', const [_ss]),
        ('au1rxx', const [_tls]),
        ('barryfar', const [_reality]),
      ]);
      expect(
        merged.map((l) => l.source).toList(),
        ['snsub', 'au1rxx', 'barryfar'],
      );
    });

    test('a feed server keeps its feed source and id prefix', () {
      final svc = V2RayService();
      final s = svc.debugToServerWithSource(_hy2, source: 'nomorewalls');
      expect(s, isNotNull);
      expect(s!.source, 'nomorewalls');
      expect(s.id, startsWith('nomorewalls-'));
      expect(s.tier, 'Hysteria2');
    });
  });

  group('attributed cache round-trip', () {
    test('encode then decode preserves links and sources', () {
      const original = [
        StealthFeedLink(_reality, 'snsub'),
        StealthFeedLink(_ss, 'barryfar'),
        StealthFeedLink(_hy2, 'matin'),
      ];
      final restored =
          V2RayService.debugDecodeCachedFeedLinks(
              V2RayService.debugEncodeCachedFeedLinks(original));
      expect(restored.length, 3);
      expect(restored.map((l) => l.link), original.map((l) => l.link));
      expect(
        restored.map((l) => l.source),
        original.map((l) => l.source),
      );
    });

    test('malformed cache content decodes to an empty list', () {
      expect(V2RayService.debugDecodeCachedFeedLinks(null), isEmpty);
      expect(V2RayService.debugDecodeCachedFeedLinks(''), isEmpty);
      expect(
        V2RayService.debugDecodeCachedFeedLinks('not json'),
        isEmpty,
      );
      expect(
        V2RayService.debugDecodeCachedFeedLinks('{"a": 1}'),
        isEmpty,
      );
      expect(
        V2RayService.debugDecodeCachedFeedLinks('[1, 2, 3]'),
        isEmpty,
      );
      expect(
        V2RayService.debugDecodeCachedFeedLinks('[["only-one"]]'),
        isEmpty,
      );
    });
  });

  group('cache schema v4', () {
    test('version 3 caches are rejected, version 4 accepted', () {
      expect(V2RayService.cacheSchemaVersion, 4);
      expect(V2RayService.cacheSchemaMatches(3), isFalse);
      expect(V2RayService.cacheSchemaMatches(4), isTrue);
      expect(V2RayService.cacheSchemaMatches(null), isFalse);
    });
  });

  group('tier floors and quality priority under the cap', () {
    test('floors hold when TLS floods and other tiers are scarce',
        () {
      final svc = V2RayService();
      final servers = <VpnServer>[];
      // 200 Reality and only 50 Hysteria2 available, a TLS flood,
      // and a handful of Shadowsocks/VMess: the cap must still ship
      // every Reality and Hysteria2 server it was offered (both
      // above their floors) and backfill the rest.
      for (var i = 0; i < 200; i++) {
        servers.add(svc.debugToServer(
            'vless://u@10.1.0.1:${1000 + i}?security=reality#R$i')!);
      }
      for (var i = 0; i < 50; i++) {
        servers.add(svc.debugToServer(
            'hysteria2://pw@10.1.0.2:${2000 + i}?sni=h#H$i')!);
      }
      for (var i = 0; i < 2000; i++) {
        servers.add(
            svc.debugToServer('trojan://pw@10.1.0.3:${3000 + i}#T$i')!);
      }
      for (var i = 0; i < 10; i++) {
        servers.add(svc.debugToServer(
            'ss://YWVzLTI1Ni1nY206cGFzcw==@10.1.0.4:${4000 + i}#S$i')!);
      }
      final capped = V2RayService.debugCapByTier(servers);
      expect(capped.length, V2RayService.maxFeedServers);
      expect(
        capped.where((s) => s.tier == 'Reality').length,
        greaterThanOrEqualTo(175),
      );
      expect(
        capped.where((s) => s.tier == 'Hysteria2').length,
        greaterThanOrEqualTo(45),
      );
    });

    test('quota slots buy distinct servers before link variants',
        () {
      // One feed publishes 5 credential variants of each of 50
      // Reality endpoints (250 links), followed by 100 links on 100
      // further distinct endpoints. Without endpoint diversity the
      // 200-slot Reality quota would cover only the first 50
      // endpoints; with it, the shipped Reality tier spans 150
      // distinct endpoints (50 first-variants + 100 distinct), and
      // only then do variants backfill the remaining 50 slots.
      final svc = V2RayService();
      final links = <StealthFeedLink>[];
      for (var e = 0; e < 50; e++) {
        for (var v = 0; v < 5; v++) {
          links.add(StealthFeedLink(
            'vless://u$v@10.3.0.1:${6000 + e}?security=reality#E$e',
            'bulk',
          ));
        }
      }
      for (var e = 0; e < 100; e++) {
        links.add(StealthFeedLink(
          'vless://u@10.3.0.2:${7000 + e}?security=reality#D$e',
          'bulk',
        ));
      }
      // 400 TLS fillers push the input past the 600 cap so the cap
      // actually engages; what is asserted is the Reality QUOTA
      // round — the first 200 Reality entries of the result, which
      // are exactly the quota picks (backfill can only append more
      // Reality entries after them).
      for (var i = 0; i < 400; i++) {
        links.add(StealthFeedLink(
          'trojan://pw@10.3.0.9:${9000 + i}#F$i',
          'bulk',
        ));
      }
      final servers = [
        for (final l in links)
          svc.debugToServerWithSource(l.link, source: l.source),
      ].whereType<VpnServer>().toList();
      final capped = V2RayService.debugCapByTier(servers);
      final quotaRound =
          capped.where((s) => s.tier == 'Reality').take(200).toList();
      expect(quotaRound.length, 200);
      final endpoints = {
        for (final s in quotaRound)
          s.shareLink!.split('@')[1].split('?')[0],
      };
      expect(endpoints.length, 150);
    });

    test('a pre-tested source wins a Reality slot over a bulk feed',
        () {
      final svc = V2RayService();
      // 250 Reality links from a bulk feed, plus one from sNSub.
      // Merged in priority order, the sNSub link comes first, so the
      // 200-slot Reality quota must include it.
      final bulk = [
        for (var i = 0; i < 250; i++)
          'vless://u@10.2.0.1:${1000 + i}?security=reality#B$i',
      ];
      // TLS fillers push the input past the 600 cap so the cap
      // engages; the assertion targets the Reality QUOTA round (the
      // first 200 Reality entries), which the sNSub server must be
      // part of despite 250 competing bulk links.
      final merged = V2RayService.debugMergeFeedLinks([
        ('snsub', const [_reality]),
        ('barryfar', bulk),
        (
          'bulkfill',
          [
            for (var i = 0; i < 500; i++)
              'trojan://pw@10.2.0.9:${9000 + i}#F$i',
          ],
        ),
      ]);
      final servers = [
        for (final l in merged)
          svc.debugToServerWithSource(l.link, source: l.source),
      ].whereType<VpnServer>().toList();
      final capped = V2RayService.debugCapByTier(servers);
      final quotaRoundIds = capped
          .where((s) => s.tier == 'Reality')
          .take(200)
          .map((s) => s.id)
          .toList();
      expect(quotaRoundIds.length, 200);
      expect(
        quotaRoundIds,
        contains('snsub-${V2RayService.stableLinkId(_reality)}'),
      );
    });
  });
}
