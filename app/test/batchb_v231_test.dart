// Tests for the v2.3.1 "Batch B" release: favourites + recents +
// fastest-by-country, subscription import by URL, config sharing,
// and IPv6 leak hardening at the configuration level.
//
// The properties pinned here:
// - favourites persist by stable server id and are pruned only
//   against a complete id universe; recents are newest-first,
//   deduplicated and capped at 5, with a no-op when the same
//   server connects twice in a row;
// - the fastest pick uses the same speed data the lists sort by
//   (measured latency, then source ping) and only ever picks a
//   server known to be working;
// - subscriptions validate name/URL, merge under the user's name
//   as the source label, survive a reload from persistence, keep
//   their last good links (with a failure note) when a refresh
//   fails, and leave the pool on delete;
// - the subscription-userinfo header parses honestly — absent or
//   garbage headers produce no display values, never invented ones;
// - share payloads are per engine: the link for Stealth, the .ovpn
//   text for OpenVPN, and public details only for WireGuard (a
//   WARP config carries the user's own private key and is never
//   shared);
// - IPv6 hardening per engine: block-ipv6 in wrapped OpenVPN
//   configs (idempotent), ::/0 in every generated WireGuard
//   AllowedIPs (with the WARP IPv6 address tunnelled when the
//   identity carries one), and the Xray freedom egress / DNS
//   pinned to IPv4.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:ipchakra/services/hysteria_config.dart';
import 'package:ipchakra/services/ipv6_hardening.dart';
import 'package:ipchakra/services/share_service.dart';
import 'package:ipchakra/services/user_lists_service.dart';
import 'package:ipchakra/services/v2ray_service.dart';
import 'package:ipchakra/services/warp_service.dart';

const _linkA = 'vless://u@a.example.com:443?security=reality#Sub-A';
const _linkB = 'ss://YWVzLTI1Ni1nY206cGFzcw==@b.example.com:8388#Sub-B';
const _linkC = 'trojan://pw@c.example.com:443#Sub-C';

VpnServer _server(String id) => VpnServer(id: id, name: id);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('favourites', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('toggle persists across instances', () async {
      final lists = UserListsService();
      await lists.load();
      expect(lists.isFavourite('srv-1'), isFalse);
      await lists.toggleFavourite('srv-1');
      expect(lists.isFavourite('srv-1'), isTrue);

      final reloaded = UserListsService();
      await reloaded.load();
      expect(reloaded.isFavourite('srv-1'), isTrue,
          reason: 'a favourite must survive a relaunch (feed refresh '
              'included) because it is keyed by stable id');

      await reloaded.toggleFavourite('srv-1');
      expect(reloaded.isFavourite('srv-1'), isFalse);
    });

    test('pruneTo drops vanished ids silently and persists', () async {
      final lists = UserListsService();
      await lists.load();
      await lists.toggleFavourite('keep');
      await lists.toggleFavourite('gone');
      await lists.recordConnect(_server('keep'));
      await lists.recordConnect(_server('gone'));
      expect(lists.recents, ['gone', 'keep']);

      await lists.pruneTo({'keep'});
      expect(lists.favourites, {'keep'});
      expect(lists.recents, ['keep']);

      final reloaded = UserListsService();
      await reloaded.load();
      expect(reloaded.favourites, {'keep'});
      expect(reloaded.recents, ['keep']);
    });
  });

  group('recents', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('nextRecents: newest first, deduplicated, capped', () {
      expect(UserListsService.nextRecents(const [], 'a'), ['a']);
      expect(UserListsService.nextRecents(const ['a', 'b'], 'b'),
          ['b', 'a']);
      expect(
        UserListsService.nextRecents(const ['a', 'b', 'c', 'd', 'e'], 'f'),
        ['f', 'a', 'b', 'c', 'd'],
        reason: 'the cap keeps the newest five',
      );
    });

    test('recordConnect orders, dedupes, caps and survives reload',
        () async {
      final lists = UserListsService();
      await lists.load();
      for (final id in ['s1', 's2', 's3', 's4', 's5', 's6']) {
        await lists.recordConnect(_server(id));
      }
      expect(lists.recents, ['s6', 's5', 's4', 's3', 's2']);
      // Reconnecting the most recent server is a no-op (engines can
      // report "connected" more than once for one session).
      await lists.recordConnect(_server('s6'));
      expect(lists.recents, ['s6', 's5', 's4', 's3', 's2']);
      // Reconnecting an older entry moves it to the front.
      await lists.recordConnect(_server('s3'));
      expect(lists.recents, ['s3', 's6', 's5', 's4', 's2']);

      final reloaded = UserListsService();
      await reloaded.load();
      expect(reloaded.recents, ['s3', 's6', 's5', 's4', 's2']);
    });
  });

  group('fastest pick', () {
    VpnServer srv(String id, {int? ping}) => VpnServer(
          id: id,
          name: id,
          pingMs: ping,
        );

    test('lowest measured latency among working servers wins', () {
      final health = HealthService();
      health.status['a'] = true;
      health.latencyMs['a'] = 120;
      health.status['b'] = true;
      health.latencyMs['b'] = 40;
      health.status['c'] = false;
      health.latencyMs['c'] = 5; // dead beats nobody, however fast
      final pick = pickFastestInGroup(
        [srv('a'), srv('b'), srv('c')],
        health,
      );
      expect(pick?.id, 'b');
    });

    test('source ping is the fallback speed; unchecked never wins',
        () {
      final health = HealthService();
      health.status['a'] = true; // working, no measurement — ping 90
      health.status['b'] = true; // working, no measurement — ping 30
      // 'c' is unchecked entirely.
      final pick = pickFastestInGroup(
        [srv('a', ping: 90), srv('b', ping: 30), srv('c', ping: 1)],
        health,
      );
      expect(pick?.id, 'b');
    });

    test('lowest speed wins across measured latency and source ping',
        () {
      // The shared ordering treats a source-reported ping and a
      // measured latency as the same kind of speed evidence.
      final health = HealthService();
      health.status['a'] = true; // working, ping 10
      health.status['b'] = true;
      health.latencyMs['b'] = 900; // working, measured 900
      final pick = pickFastestInGroup(
        [srv('a', ping: 10), srv('b')],
        health,
      );
      expect(pick?.id, 'a');
    });

    test('a speed-known working server beats a speed-less one', () {
      final health = HealthService();
      health.status['a'] = true; // working, no speed information
      health.status['b'] = true; // working, ping only
      final pick = pickFastestInGroup(
        [srv('a'), srv('b', ping: 900)],
        health,
      );
      expect(pick?.id, 'b',
          reason: 'the speed-less server is only the fallback when '
              'no working server has any speed at all');
    });

    test('null when nothing in the group is known working', () {
      final health = HealthService();
      health.status['a'] = false;
      expect(pickFastestInGroup([srv('a'), srv('b')], health), isNull);
      expect(pickFastestInGroup(const [], health), isNull);
    });
  });

  group('subscription userinfo', () {
    test('a full header parses into every field', () {
      final info = SubscriptionUserinfo.parse(
        'upload=1024; download=2048; total=107374182400; '
        'expire=1893456000',
      );
      expect(info, isNotNull);
      expect(info!.uploadBytes, 1024);
      expect(info.downloadBytes, 2048);
      expect(info.totalBytes, 107374182400);
      expect(info.expireEpochSeconds, 1893456000);
      expect(info.usedBytes, 3072);
      final line = info.describe();
      expect(line, contains('of 100 GB used'));
      expect(line, contains('Expires'));
      expect(line, contains('2030'));
    });

    test('a partial header shows only what arrived', () {
      final info = SubscriptionUserinfo.parse('download=1048576');
      expect(info, isNotNull);
      expect(info!.usedBytes, 1048576);
      expect(info.describe(), '1 MB used');
    });

    test('absent or garbage headers produce nothing', () {
      expect(SubscriptionUserinfo.parse(null), isNull);
      expect(SubscriptionUserinfo.parse(''), isNull);
      expect(SubscriptionUserinfo.parse('hello world'), isNull);
      expect(SubscriptionUserinfo.parse('upload=abc; total='), isNull,
          reason: 'no usable figure means no display, never an '
              'invented one');
    });

    test('formatBytes', () {
      expect(SubscriptionUserinfo.formatBytes(500), '500 B');
      expect(SubscriptionUserinfo.formatBytes(1536), '1.5 KB');
      expect(SubscriptionUserinfo.formatBytes(1073741824), '1 GB');
    });
  });

  group('subscriptions', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    V2RayService serviceReturning(Object? result) {
      final svc = V2RayService();
      svc.debugSubscriptionFetcher = (url) async {
        if (result is List<String>) {
          return (links: result, userinfo: null);
        }
        return null;
      };
      return svc;
    }

    test('add validates, fetches and merges under the user name',
        () async {
      final svc = V2RayService();
      svc.debugSubscriptionFetcher = (url) async => (
            links: [_linkA, _linkB],
            userinfo: SubscriptionUserinfo.parse(
              'upload=0; download=1073741824; total=107374182400',
            ),
          );
      final error = await svc.addSubscription(
        name: 'My Sub',
        url: 'https://subs.example.com/feed',
      );
      expect(error, isNull);
      expect(svc.subscriptions.single.name, 'My Sub');
      expect(svc.subscriptionServerCount('My Sub'), 2);
      final mine = svc.servers.where((s) => s.source == 'My Sub');
      expect(mine.length, 2);
      expect(mine.every((s) => s.isStealth), isTrue);
      final status = svc.statusOf('My Sub');
      expect(status.refreshFailed, isFalse);
      expect(status.userinfo?.totalBytes, 107374182400);
    });

    test('add rejects bad names and URLs without touching the pool',
        () async {
      final svc = serviceReturning(const [_linkA]);
      expect(await svc.addSubscription(name: '  ', url: 'https://x.co'),
          isNotNull);
      expect(
        await svc.addSubscription(name: 'custom', url: 'https://x.co'),
        isNotNull,
        reason: 'built-in source names are reserved',
      );
      expect(await svc.addSubscription(name: 'Ok', url: 'notaurl'),
          isNotNull);
      expect(await svc.addSubscription(name: 'Ok', url: 'ftp://x.co/f'),
          isNotNull);
      expect(svc.subscriptions, isEmpty);
      expect(
        await svc.addSubscription(name: 'Ok', url: 'https://x.co/f'),
        isNull,
      );
      expect(
        await svc.addSubscription(name: 'ok', url: 'https://y.co/f'),
        isNotNull,
        reason: 'names are unique case-insensitively',
      );
      expect(
        await svc.addSubscription(name: 'Other', url: 'https://x.co/f'),
        isNotNull,
        reason: 'the same URL cannot be added twice',
      );
      expect(svc.subscriptions.length, 1);
    });

    test('a failed refresh keeps the last good links and is noted',
        () async {
      final svc = V2RayService();
      var fail = false;
      svc.debugSubscriptionFetcher = (url) async =>
          fail ? null : (links: [_linkA, _linkC], userinfo: null);
      expect(
        await svc.addSubscription(
          name: 'Flaky',
          url: 'https://flaky.example.com/sub',
        ),
        isNull,
      );
      expect(svc.subscriptionServerCount('Flaky'), 2);

      fail = true;
      await svc.load(forceRefresh: true);
      expect(svc.subscriptionServerCount('Flaky'), 2,
          reason: 'the last good list keeps serving');
      expect(svc.statusOf('Flaky').refreshFailed, isTrue);
    });

    test('delete removes the subscription and its servers', () async {
      final svc = serviceReturning(const [_linkA, _linkB]);
      await svc.addSubscription(name: 'Mine', url: 'https://m.co/s');
      expect(svc.subscriptionServerCount('Mine'), 2);
      await svc.removeSubscription('Mine');
      expect(svc.subscriptions, isEmpty);
      expect(svc.subscriptionServerCount('Mine'), 0);
      expect(svc.servers.where((s) => s.source == 'Mine'), isEmpty);
    });

    test('subscriptions and cached links survive a reload', () async {
      final svc = V2RayService();
      svc.debugSubscriptionFetcher = (url) async => (
            links: [_linkB],
            userinfo: SubscriptionUserinfo.parse('total=2147483648'),
          );
      await svc.addSubscription(name: 'Kept', url: 'https://k.co/s');

      // A fresh service instance reading the same store, with the
      // built-in refresh not due: the subscription must rebuild
      // from its persisted links and status alone.
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        'v2ray_time',
        DateTime.now().millisecondsSinceEpoch,
      );
      final reloaded = V2RayService();
      await reloaded.load();
      expect(reloaded.subscriptions.single.name, 'Kept');
      expect(reloaded.subscriptionServerCount('Kept'), 1);
      expect(
        reloaded.statusOf('Kept').userinfo?.totalBytes,
        2147483648,
      );
    });
  });

  group('share payloads', () {
    const ovpnText = 'client\ndev tun\n<ca>\n-----BEGIN CERT-----\n</ca>';

    test('stealth shares its link', () {
      const server = VpnServer(
        id: 'epodonios-x',
        name: 'Berlin',
        protocol: 'v2ray',
        source: 'epodonios',
        shareLink: _linkA,
      );
      final payload = sharePayloadFor(server);
      expect(payload, isNotNull);
      expect(payload!.kind, SharePayloadKind.link);
      expect(payload.text, _linkA);
      expect(payload.isLink, isTrue);
    });

    test('openvpn shares the config text it holds', () {
      const server = VpnServer(
        id: 'vpngate-1',
        name: 'Tokyo',
        protocol: 'openvpn',
        source: 'vpngate',
        ovpnConfig: ovpnText,
      );
      final payload = sharePayloadFor(server);
      expect(payload!.kind, SharePayloadKind.config);
      expect(payload.text, ovpnText);
    });

    test('openvpn loads an on-demand config for sharing', () async {
      final server = VpnServer(
        id: 'vpnbook-1',
        name: 'London',
        protocol: 'openvpn',
        source: 'vpnbook',
        configLoader: () async => ovpnText,
      );
      expect(sharePayloadFor(server), isNull,
          reason: 'nothing is held until the loader runs');
      final payload = await loadSharePayload(server);
      expect(payload!.kind, SharePayloadKind.config);
      expect(payload.text, ovpnText);
    });

    test('wireguard shares public details only — never a private key',
        () {
      const server = VpnServer(
        id: 'warp-1',
        name: 'WARP',
        protocol: 'wireguard',
        source: 'warp',
        warp: true,
        endpoint: '162.159.192.1:2408',
        peerPublicKey: 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=',
      );
      final payload = sharePayloadFor(server);
      expect(payload!.kind, SharePayloadKind.details);
      expect(payload.text, contains('162.159.192.1:2408'));
      expect(payload.text, contains('Peer public key'));
      expect(payload.text.toLowerCase(), isNot(contains('privatekey')),
          reason: 'a WARP configuration carries the user\'s own '
              'private identity key and must never be shared');
    });
  });

  group('ipv6 hardening', () {
    test('openvpn: block-ipv6 is added once and only once', () {
      const config = 'client\ndev tun\nremote 203.0.113.5 1194\n';
      final once = hardenOpenVpnConfig(config);
      expect(once, contains('\nblock-ipv6\n'));
      expect(hardenOpenVpnConfig(once), once,
          reason: 'idempotent — a second wrap changes nothing');
      const already = 'client\n  Block-IPv6\nremote x 1\n';
      expect(hardenOpenVpnConfig(already), already,
          reason: 'an existing directive in any casing is respected');
    });

    test('wireguard: the shared AllowedIPs always routes IPv6 in',
        () {
      expect(kWireGuardAllowedIps, contains('0.0.0.0/0'));
      expect(kWireGuardAllowedIps, contains('::/0'));
    });

    test('warp config: IPv6 tunnelled when the identity carries it',
        () {
      final warp = WarpService();
      final dual = WarpConfig(
        privateKey: 'priv',
        addressV4: '172.16.0.2/32',
        addressV6: 'fd01:4700::2/128',
        peerPublicKey: 'peer',
        endpoint: '162.159.192.1:2408',
      );
      final conf = warp.buildQuickConfig(dual, dual.endpoint);
      expect(conf, contains('Address = 172.16.0.2/32, fd01:4700::2/128'));
      expect(conf, contains('AllowedIPs = $kWireGuardAllowedIps'));

      final v4Only = WarpConfig(
        privateKey: 'priv',
        addressV4: '172.16.0.2/32',
        peerPublicKey: 'peer',
        endpoint: '162.159.192.1:2408',
      );
      final conf4 = warp.buildQuickConfig(v4Only, v4Only.endpoint);
      expect(conf4, contains('Address = 172.16.0.2/32\n'));
      expect(conf4, contains('AllowedIPs = $kWireGuardAllowedIps'),
          reason: 'even without an IPv6 address, ::/0 routes IPv6 '
              'into the tunnel so it cannot leak around it');
    });

    test('warp registration parses the v6 interface address', () {
      final withV6 = WarpService.debugAddressV6FromJson({
        'config': {
          'interface': {
            'addresses': {'v4': '172.16.0.2', 'v6': 'fd01:4700::2'},
          },
        },
      });
      expect(withV6, 'fd01:4700::2');
      final without = WarpService.debugAddressV6FromJson({
        'config': {
          'interface': {
            'addresses': {'v4': '172.16.0.2'},
          },
        },
      });
      expect(without, isNull);
      expect(WarpService.debugAddressV6FromJson(const {}), isNull);
    });

    test('xray: freedom egress and DNS pinned to IPv4', () {
      final pluginShaped = jsonEncode({
        'outbounds': [
          {
            'protocol': 'freedom',
            'tag': 'direct',
            'streamSettings': {
              'network': 'tcp',
              'sockopt': {'domainStrategy': 'UseIP'},
            },
          },
          {'protocol': 'blackhole', 'tag': 'block'},
        ],
        'dns': {
          'servers': ['1.1.1.1'],
        },
      });
      final hardened =
          jsonDecode(hardenXrayConfig(pluginShaped)) as Map<String, dynamic>;
      final outbounds = hardened['outbounds'] as List;
      final freedom = outbounds[0] as Map<String, dynamic>;
      expect(
        ((freedom['streamSettings'] as Map)['sockopt'] as Map)
            ['domainStrategy'],
        'UseIPv4',
      );
      expect(outbounds[1], {'protocol': 'blackhole', 'tag': 'block'},
          reason: 'non-freedom outbounds are untouched');
      expect((hardened['dns'] as Map)['queryStrategy'], 'UseIPv4');
    });

    test('xray: the hand-built hysteria2 shape is pinned too', () {
      final built = buildHysteria2Config(
        'hysteria2://pw@h.example.com:443?sni=h.example.com#H1',
        const ['1.1.1.1'],
      );
      expect(built, isNotNull);
      final hardened =
          jsonDecode(hardenXrayConfig(built!)) as Map<String, dynamic>;
      final freedom = (hardened['outbounds'] as List).firstWhere(
        (o) => (o as Map)['protocol'] == 'freedom',
      ) as Map<String, dynamic>;
      expect(
        ((freedom['streamSettings'] as Map)['sockopt'] as Map)
            ['domainStrategy'],
        'UseIPv4',
      );
      expect((hardened['dns'] as Map)['queryStrategy'], 'UseIPv4');
    });

    test('xray: malformed input passes through unchanged', () {
      expect(hardenXrayConfig('not json at all'), 'not json at all');
      expect(hardenXrayConfig('[1, 2, 3]'), '[1, 2, 3]');
    });
  });
}
