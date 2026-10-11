// Regression tests for the v2.3.3 Stealth country fix.
//
// Shiv's S25 report on v2.3.2: "Stealth mein country nhi aa rhe h"
// — the Stealth tab showed no countries. Measured root cause (see
// the v2.3.3 report): country came only from a remark substring
// regex, and the tier cap filled its quotas from two feeds that
// publish no country metadata at all, so the shipped pool was
// 600/600 "Unknown" — one group, no countries. These tests pin:
//  * the layered remark extractor (flag emoji / validated ISO
//    token / English name / Chinese name) and its false-positive
//    guards against the old substring behaviour;
//  * real links sampled from EVERY current feed landing in the
//    country their remark states (feeds whose remarks state no
//    country honestly stay Unknown — nothing is invented);
//  * the tier cap preferring country-known servers within a tier;
//  * the Stealth country group headers rendering visibly, with
//    geometry assertions (the v2.3.2 lesson: presence is not size).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ipchakra/core/theme.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/screens/servers_screen.dart';
import 'package:ipchakra/services/country_table.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:ipchakra/services/ovpn_mirror_service.dart';
import 'package:ipchakra/services/server_database.dart';
import 'package:ipchakra/services/user_lists_service.dart';
import 'package:ipchakra/services/v2ray_service.dart';
import 'package:ipchakra/services/vpn_controller.dart';
import 'package:ipchakra/services/vpnbook_service.dart';
import 'package:ipchakra/services/vpngate_pool_service.dart';
import 'package:ipchakra/services/vpngate_service.dart';
import 'package:ipchakra/services/warp_service.dart';

import 'fixtures/stealth_country_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('countryCodeFromRemark conventions', () {
    test('flag emoji anywhere in the remark', () {
      expect(countryCodeFromRemark('🇳🇱NL-193.29.139.147-5638'), 'NL');
      expect(countryCodeFromRemark('SG 🇸🇬 | @Raydikalx | 09AA26'), 'SG');
      expect(countryCodeFromRemark('@Everyday_VPN | 01 🇩🇪'), 'DE');
      expect(countryCodeFromRemark('🇺🇸'), 'US');
    });

    test('the UM flag/token is the United States, as feeds mean it', () {
      expect(countryCodeFromRemark('Telegram @Cnetvpn 🇺🇲'), 'US');
      expect(countryNameForCode('UM'), 'United States');
      expect(flagEmojiForCode('UM'), '🇺🇸');
    });

    test('bounded ISO code tokens', () {
      expect(countryCodeFromRemark('US_speednode_0144'), 'US');
      expect(countryCodeFromRemark('[www.v2nodes.com] vless-AL-1'), 'AL');
      expect(countryCodeFromRemark('DE-Reality'), 'DE');
      expect(countryCodeFromRemark('UK-London 3'), 'GB'); // UK alias
      expect(countryCodeFromRemark('USA-New York'), 'US'); // USA alias
    });

    test('English country names as whole phrases', () {
      expect(countryCodeFromRemark('Germany Frankfurt 2'), 'DE');
      expect(countryCodeFromRemark('United States - New York'), 'US');
      expect(countryCodeFromRemark('Hong Kong 01'), 'HK');
      expect(countryCodeFromRemark('Premium Netherlands server'), 'NL');
    });

    test('Chinese country names', () {
      expect(countryCodeFromRemark('乌克兰+V2CROSS.COM'), 'UA');
      expect(countryCodeFromRemark('美国+CloudFlare节点'), 'US');
      expect(countryCodeFromRemark('立陶宛+V2CROSS.COM'), 'LT');
    });

    test('no country stated -> null, never a guess', () {
      expect(countryCodeFromRemark('EPODONIOS'), isNull);
      expect(countryCodeFromRemark('hysteria2-1701029322'), isNull);
      expect(countryCodeFromRemark('@ghand_sheken'), isNull);
      expect(countryCodeFromRemark('⚡ b2n.ir/v2ray-configs | 438'), isNull);
      expect(countryCodeFromRemark(''), isNull);
    });

    test('the old substring false positives are gone', () {
      // The pre-fix regex read a code out of ANY [A-Z]{2}- substring.
      expect(countryCodeFromRemark('🏁RELAY-104.19.173.68-0071'), isNull,
          reason: 'was the junk group "AY" (from RELAY)');
      expect(countryCodeFromRemark('Telegram---PLANB_NET---x'), isNull,
          reason: 'was the junk group "ET" (from NET)');
      expect(countryCodeFromRemark('ProxyMtpVPN-3'), isNull,
          reason: 'was the junk group "PN" (from VPN)');
      expect(countryCodeFromRemark('canfingV2rayNG-46'), isNull,
          reason: 'was the junk group "NG" (from V2rayNG)');
      expect(countryCodeFromRemark('VLESS-Reality'), isNull,
          reason: 'was the junk group "SS" (from VLESS)');
    });
  });

  group('country table', () {
    test('codes beyond the old 31-name table resolve to real names', () {
      expect(countryNameForCode('IE'), 'Ireland');
      expect(countryNameForCode('FI'), 'Finland');
      expect(countryNameForCode('KZ'), 'Kazakhstan');
      expect(countryNameForCode('VN'), 'Vietnam');
      expect(countryNameForCode('BG'), 'Bulgaria');
      expect(countryNameForCode('NO'), 'Norway');
      expect(countryNameForCode('XX'), isNull);
    });

    test('flags are computed for every code', () {
      expect(flagEmojiForCode('KZ'), '🇰🇿');
      expect(flagEmojiForCode('IE'), '🇮🇪');
      expect(flagEmojiForCode(''), '🌐');
      expect(flagEmojiForCode('toolong'), '🌐');
    });

    test('a server built from a flag+code remark gets the full name',
        () {
      final s = V2RayService().debugToServer(
        'vless://u@54.72.130.222:443?security=reality'
        '#🇮🇪IE-54.72.130.222-0475',
      );
      expect(s, isNotNull);
      expect(s!.country, 'Ireland',
          reason: 'the old table stopped at the raw code "IE"');
      expect(s.flag, '🇮🇪');
    });
  });

  group('every feed lands in its stated country (real sampled links)',
      () {
    test('per-feed fixtures', () {
      final svc = V2RayService();
      final seenSources = <String>{};
      for (final (source, link, country, flag, why) in
          stealthCountryFixtures) {
        seenSources.add(source);
        final s = svc.debugToServerWithSource(link, source: source);
        expect(s, isNotNull, reason: '$source fixture link must parse');
        expect(s!.country, country,
            reason: '$source ($why): remark '
                '"${s.name.length > 40 ? s.name.substring(0, 40) : s.name}"');
        expect(s.flag, flag, reason: '$source flag');
      }
      // The fixture set really does cover every built-in feed.
      expect(
        seenSources,
        containsAll([
          'snsub',
          'au1rxx',
          'epodonios',
          'eternity',
          'submerge',
          'pawdroid',
          'matin',
          'nomorewalls',
          'barryfar',
        ]),
      );
    });
  });

  group('tier cap prefers country-known servers', () {
    test('anonymous flood cannot shut known countries out of a tier',
        () {
      final svc = V2RayService();
      final servers = <VpnServer>[];
      // 250 anonymous Reality links first in merged order (the
      // Au1rxx/Epodonios shape: remarks state no country)…
      for (var i = 0; i < 250; i++) {
        servers.add(svc.debugToServer(
            'vless://u@10.5.0.1:${1000 + i}?security=reality#node$i')!);
      }
      // …then 100 German Reality links from a later feed.
      for (var i = 0; i < 100; i++) {
        servers.add(svc.debugToServer(
            'vless://u@10.5.0.2:${2000 + i}?security=reality#🇩🇪DE-$i')!);
      }
      // TLS fillers push the total past the cap so it engages.
      for (var i = 0; i < 400; i++) {
        servers.add(
            svc.debugToServer('trojan://pw@10.5.0.9:${9000 + i}#F$i')!);
      }
      final capped = V2RayService.debugCapByTier(servers);
      expect(capped.length, V2RayService.maxFeedServers);
      final reality = capped.where((s) => s.tier == 'Reality').toList();
      final quotaRound = reality.take(200).toList();
      expect(quotaRound.length, 200);
      // Every German server is inside the quota round, at its head:
      // under the old cap the round was the first 200 anonymous
      // links and Germany shipped nothing at all.
      expect(
        quotaRound.where((s) => s.country == 'Germany').length,
        100,
      );
      expect(
        quotaRound.take(100).every((s) => s.country == 'Germany'),
        isTrue,
      );
    });
  });

  group('Stealth country group headers render (geometry)', () {
    testWidgets('headers are visible, sized, and expandable',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});

      final svc = V2RayService();
      VpnServer build(String link) =>
          svc.debugToServerWithSource(link, source: 'eternity')!;
      final warp = WarpService();
      final db = ServerDatabase();
      final vpngate = VpnGateService();
      final pool = VpnGatePoolService();
      final vpnbook = VpnBookService();
      final mirror = OvpnMirrorService();
      final v2ray = V2RayService();
      final health = HealthService();
      final userLists = UserListsService();
      final vpn = VpnController(warp);
      v2ray.servers = [
        build('vless://u@10.9.0.1:443?security=reality#🇩🇪DE-Berlin'),
        build('vless://u@10.9.0.2:443?security=reality#🇩🇪DE-Munich'),
        build('vless://u@10.9.0.3:443?security=reality#🇯🇵JP-Tokyo'),
      ];
      for (final s in v2ray.servers) {
        health.status[s.id] = true;
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: ChakraTheme.dark(),
          home: Scaffold(
            body: ServersScreen(
              db: db,
              vpn: vpn,
              vpngate: vpngate,
              pool: pool,
              vpnbook: vpnbook,
              mirror: mirror,
              v2ray: v2ray,
              health: health,
              userLists: userLists,
              onGoHome: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.textContaining('Stealth').first);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      final listFinder = find.byType(ListView).last;
      await tester.dragUntilVisible(
        find.text('Germany'),
        listFinder,
        const Offset(0, -200),
      );
      // The header is really there: right text, real size (the
      // v2.3.2 failure mode was a header-adjacent text slot
      // collapsing to ~zero width).
      final headerSize = tester.getSize(find.text('Germany'));
      expect(headerSize.height, greaterThan(10));
      expect(headerSize.width, greaterThan(50));
      expect(find.text('2 servers'), findsOneWidget);
      expect(find.text('Japan'), findsOneWidget);
      expect(find.text('1 servers'), findsOneWidget);

      // Expanding the group reveals the fastest row and the rows.
      await tester.tap(find.text('Germany'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Connect fastest'), findsWidgets);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  });
}
