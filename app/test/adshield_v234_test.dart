// Tests for the v2.3.4 "AdShield Embedded" rework: the pure Xray
// config injection (dns.hosts + dns-out outbound + routing rules),
// the OpenVPN ad-blocking DNS transform, and the ad-blocking
// provider selection. The counting-mode injection variant is pinned
// here too; the counting forwarder itself is tested in
// counting_dns_test.dart.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ipchakra/services/adshield_service.dart';
import 'package:ipchakra/services/dns_service.dart';
import 'package:ipchakra/services/ipv6_hardening.dart';

const _testHosts = <String, String>{
  'domain:ads.example.com': '10.10.10.3',
  'domain:tracker.example.net': '10.10.10.3',
};

/// A plugin-parser-shaped stealth config: proxy first, then direct,
/// then blackhole; the dns object and the port-853 rule optional.
String _pluginConfig({bool withDns = true, bool with853 = true}) {
  final config = <String, dynamic>{
    'log': {'loglevel': 'error'},
    'inbounds': [
      {'tag': 'in_proxy', 'port': 10807, 'protocol': 'socks'},
    ],
    'outbounds': [
      {'tag': 'proxy', 'protocol': 'vless', 'settings': <String, dynamic>{}},
      {'tag': 'direct', 'protocol': 'freedom', 'settings': <String, dynamic>{}},
      {
        'tag': 'blackhole',
        'protocol': 'blackhole',
        'settings': <String, dynamic>{}
      },
    ],
  };
  if (withDns) {
    config['dns'] = {
      'servers': ['9.9.9.9', '149.112.112.112'],
      'queryStrategy': 'UseIPv4',
    };
  }
  final rules = <dynamic>[];
  if (with853) rules.add(DnsService.dnsRoutingRule());
  config['routing'] = {'domainStrategy': 'UseIp', 'rules': rules};
  return jsonEncode(config);
}

Map<String, dynamic> _decode(String s) =>
    jsonDecode(s) as Map<String, dynamic>;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('injectXrayHosts', () {
    test('injects hosts, the dns-out outbound and the routing rules',
        () {
      final out =
          AdShieldService.injectXrayHosts(_pluginConfig(), _testHosts);
      final decoded = _decode(out);

      final dns = decoded['dns'] as Map<String, dynamic>;
      expect(dns['tag'], AdShieldService.dnsTag);
      expect(
        (dns['hosts'] as Map)['domain:ads.example.com'],
        '10.10.10.3', // anti-detect stub IP, not 0.0.0.0
      );
      // The attempt's own servers survive the injection.
      expect(dns['servers'], ['9.9.9.9', '149.112.112.112']);

      final outbounds = decoded['outbounds'] as List;
      final dnsOuts = outbounds
          .where((o) => o is Map && o['tag'] == 'dns-out')
          .toList();
      expect(dnsOuts, hasLength(1));
      expect(dnsOuts.first['protocol'], 'dns');
      // Anti-detect: the dokodemo-door stub outbound exists once.
      final stubOuts = outbounds
          .where((o) => o is Map && o['tag'] == 'adshield-stub')
          .toList();
      expect(stubOuts, hasLength(1));
      expect(stubOuts.first['protocol'], 'dokodemo-door');
      expect(
        (stubOuts.first['settings'] as Map)['address'],
        '127.0.0.1',
      );

      final rules = (decoded['routing'] as Map)['rules'] as List;
      // Our four rules lead: the stub-IP redirect first (disjoint
      // from the DNS plumbing, must win over default routing),
      // then the loop-free DNS order — the DNS client's loopback
      // queries direct (a loopback upstream — the counting
      // forwarder — must stay on the device), its other queries
      // via the proxy, then TUN port 53 to dns-out (scoped to the
      // TUN inbound so the forwarder's own SOCKS relays are never
      // captured and looped).
      expect(rules[0]['ip'], ['10.10.10.3/32']);
      expect(rules[0]['outboundTag'], 'adshield-stub');
      expect(rules[1]['inboundTag'], ['adshield-dns']);
      expect(rules[1]['ip'], ['127.0.0.0/8']);
      expect(rules[1]['outboundTag'], 'direct');
      expect(rules[2]['inboundTag'], ['adshield-dns']);
      expect(rules[2]['outboundTag'], 'proxy');
      expect(rules[3]['port'], '53');
      expect(rules[3]['inboundTag'], ['tun']);
      expect(rules[3]['outboundTag'], 'dns-out');
      // The pre-existing port-853 rule is kept exactly once.
      expect(
        rules.where((r) => r is Map && '${r['port']}' == '853'),
        hasLength(1),
      );
    });

    test('applying twice changes nothing (no duplicate rules/outbounds)',
        () {
      final once =
          AdShieldService.injectXrayHosts(_pluginConfig(), _testHosts);
      final twice = AdShieldService.injectXrayHosts(once, _testHosts);
      expect(twice, once);

      final decoded = _decode(twice);
      final outbounds = decoded['outbounds'] as List;
      expect(
        outbounds.where((o) => o is Map && o['tag'] == 'dns-out'),
        hasLength(1),
      );
      expect(
        outbounds.where((o) => o is Map && o['tag'] == 'adshield-stub'),
        hasLength(1),
      );
      final rules = (decoded['routing'] as Map)['rules'] as List;
      expect(
        rules
            .where((r) => r is Map && r['outboundTag'] == 'dns-out')
            .toList(),
        hasLength(1),
      );
      expect(
        rules
            .where((r) => r is Map && r['outboundTag'] == 'adshield-stub')
            .toList(),
        hasLength(1),
      );
      expect(
        rules
            .where((r) =>
                r is Map &&
                (r['inboundTag'] as List?)?.isNotEmpty == true)
            .toList(),
        hasLength(3), // loopback, proxy and TUN-scoped port 53
      );
    });

    test('Tier-3: a config without a dns object gets one with the '
        'fallback servers', () {
      final tier3 = _pluginConfig(withDns: false, with853: false);
      final out = AdShieldService.injectXrayHosts(
        tier3,
        _testHosts,
        serversFallback: ['1.1.1.1', '1.0.0.1'],
      );
      final decoded = _decode(out);

      final dns = decoded['dns'] as Map<String, dynamic>;
      expect(dns['servers'], ['1.1.1.1', '1.0.0.1']);
      expect(dns['queryStrategy'], 'UseIPv4');
      expect(dns['tag'], AdShieldService.dnsTag);
      expect((dns['hosts'] as Map).length, 2);

      final rules = (decoded['routing'] as Map)['rules'] as List;
      // rules[0] is the anti-detect stub-IP redirect; the DNS
      // plumbing follows in loop-free order.
      expect(rules[0]['outboundTag'], 'adshield-stub');
      expect(rules[1]['inboundTag'], ['adshield-dns']);
      expect(rules[1]['outboundTag'], 'direct');
      expect(rules[2]['inboundTag'], ['adshield-dns']);
      expect(rules[2]['outboundTag'], 'proxy');
      expect(rules[3]['port'], '53');
      expect(rules[3]['inboundTag'], ['tun']);
      expect(rules[3]['outboundTag'], 'dns-out');
      // The port-853 rule is added when missing.
      expect(
        rules.where((r) => r is Map && '${r['port']}' == '853'),
        hasLength(1),
      );
    });

    test('a config without any routing object gets one', () {
      final bare = jsonEncode({
        'outbounds': [
          {'tag': 'proxy', 'protocol': 'vless'},
        ],
      });
      final out = AdShieldService.injectXrayHosts(bare, _testHosts);
      final decoded = _decode(out);
      final rules = (decoded['routing'] as Map)['rules'] as List;
      expect(rules, hasLength(5)); // stub-ip, loopback, proxy, port 53, 853
    });

    test('an existing dns tag is preserved and used by the rule', () {
      final config = _pluginConfig();
      final withTag = _decode(config)
        ..['dns'] = {
          'tag': 'custom-dns',
          'servers': ['9.9.9.9'],
          'queryStrategy': 'UseIPv4',
        };
      final out = AdShieldService.injectXrayHosts(
          jsonEncode(withTag), _testHosts);
      final decoded = _decode(out);
      expect((decoded['dns'] as Map)['tag'], 'custom-dns');
      final rules = (decoded['routing'] as Map)['rules'] as List;
      // rules[0] is the anti-detect stub-IP redirect; the
      // custom-tagged DNS-client rule follows it.
      expect(rules[0]['outboundTag'], 'adshield-stub');
      expect(rules[1]['inboundTag'], ['custom-dns']);
    });

    test('a pre-existing dns-out outbound is not duplicated', () {
      final config = _decode(_pluginConfig());
      (config['outbounds'] as List).add(
          {'protocol': 'dns', 'tag': 'dns-out'});
      final out = AdShieldService.injectXrayHosts(
          jsonEncode(config), _testHosts);
      final decoded = _decode(out);
      final outbounds = decoded['outbounds'] as List;
      expect(
        outbounds.where((o) => o is Map && o['tag'] == 'dns-out'),
        hasLength(1),
      );
    });

    test('non-JSON input passes through unchanged', () {
      expect(
          AdShieldService.injectXrayHosts('not json at all', _testHosts),
          'not json at all');
      expect(AdShieldService.injectXrayHosts('[1, 2, 3]', _testHosts),
          '[1, 2, 3]');
      expect(AdShieldService.injectXrayHosts('', _testHosts), '');
    });

    test('the first outbound is the main proxy in both config shapes',
        () {
      // Hand-built Hysteria2 shape (hysteria_config.dart) and the
      // plugin-parser shape both order [proxy, direct, blackhole]:
      // the injected DNS-client rule must target the proxy.
      final out =
          AdShieldService.injectXrayHosts(_pluginConfig(), _testHosts);
      final rules = (_decode(out)['routing'] as Map)['rules'] as List;
      expect(rules[2]['inboundTag'], ['adshield-dns']);
      expect(rules[2]['outboundTag'], 'proxy');
    });
  });

  group('applyAdShieldOpenVpnDns', () {
    test('strips foreign DNS options and adds one line per server',
        () {
      const sample = 'client\n'
          'remote example.com 1194\n'
          'dhcp-option DNS 8.8.8.8\n'
          'dhcp-option DNS 1.1.1.1\n'
          'dhcp-option DNS6 2001:4860:4860::8888\n';
      final out = applyAdShieldOpenVpnDns(
          sample, ['94.140.14.14', '94.140.15.15']);
      expect(out.contains('dhcp-option DNS 8.8.8.8'), isFalse);
      expect(out.contains('dhcp-option DNS 1.1.1.1'), isFalse);
      // IPv6 DNS options are not the filter's business; left alone.
      expect(out.contains('dhcp-option DNS6'), isTrue);
      expect(out.contains('remote example.com 1194'), isTrue);
      expect(out.contains('pull-filter ignore "dhcp-option DNS"'),
          isTrue);
      expect(out.contains('dhcp-option DNS 94.140.14.14'), isTrue);
      expect(out.contains('dhcp-option DNS 94.140.15.15'), isTrue);
      expect(
          out.indexOf('pull-filter'), lessThan(out.indexOf('94.140.14.14')));
    });

    test('applying twice leaves exactly one copy of each added line',
        () {
      const sample = 'client\ndhcp-option DNS 1.1.1.1\n';
      final once =
          applyAdShieldOpenVpnDns(sample, ['94.140.14.14', '94.140.15.15']);
      final twice = applyAdShieldOpenVpnDns(
          once, ['94.140.14.14', '94.140.15.15']);
      expect(twice, once);
      expect('dhcp-option DNS 94.140.14.14'.allMatches(once).length, 1);
      expect('dhcp-option DNS 94.140.15.15'.allMatches(once).length, 1);
      expect('pull-filter ignore "dhcp-option DNS"'.allMatches(once).length,
          1);
    });

    test('a config without DNS lines just gains the override lines',
        () {
      const sample = 'client\nremote example.com 1194\n';
      final out = applyAdShieldOpenVpnDns(sample, ['76.76.2.2']);
      expect(out.startsWith(sample), isTrue);
      expect(out.contains('pull-filter ignore "dhcp-option DNS"'),
          isTrue);
      expect(out.contains('dhcp-option DNS 76.76.2.2'), isTrue);
    });
  });

  group('adBlockingServers', () {
    test('keeps the selected provider when it already blocks ads', () {
      final adguard =
          DnsService.providers.firstWhere((p) => p.id == 'adguard');
      expect(AdShieldService.adBlockingServers(adguard), adguard.servers);
      expect(AdShieldService.adBlockingProvider(adguard).id, 'adguard');
    });

    test('switches a non-blocking provider to the first ad-blocking one',
        () {
      final cloudflare =
          DnsService.providers.firstWhere((p) => p.id == 'cloudflare');
      // AdGuard DNS is the first 'Ad blocking' entry in the catalogue.
      expect(AdShieldService.adBlockingServers(cloudflare),
          ['94.140.14.14', '94.140.15.15']);
      expect(
          AdShieldService.adBlockingProvider(cloudflare).id, 'adguard');
    });

    test('falls back to the selected provider when the catalogue has '
        'no ad-blocking entry', () {
      const selected = DnsProvider(
          id: 'x', name: 'X', tag: 'Fast', primary: '1.2.3.4');
      const other = DnsProvider(
          id: 'y', name: 'Y', tag: 'Family', primary: '5.6.7.8');
      expect(
        AdShieldService.debugAdBlockingProvider(
            [selected, other], selected),
        same(selected),
      );
      expect(
        AdShieldService.debugAdBlockingProvider(
            [selected, other], other),
        same(other),
      );
    });
  });
  group('bundled lists', () {
    test('init loads the real bundled blocklist from the assets',
        () async {
      SharedPreferences.setMockInitialValues({});
      final svc = AdShieldService();
      await svc.init();
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!svc.listsLoaded && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(svc.listsLoaded, isTrue);
      // The card's number must be the list's real size: meta.json
      // and the hosts map agree, entry for entry.
      expect(svc.domainCount, 217592);
      expect(svc.hosts.length, svc.domainCount);
      // Anti-detect: every hosts value is the stub IP now.
      expect(svc.hosts.values.every((v) => v == '10.10.10.3'), isTrue);
      expect(svc.source, 'AdShield v0.6.1 EXTREME');
      svc.dispose();
    });
  });
  group('injectXrayHosts counting mode', () {
    test('points the core DNS at the forwarder and drops hosts', () {
      final out = AdShieldService.injectXrayHosts(
        _pluginConfig(),
        _testHosts,
        countingPort: 15353,
      );
      final config = _decode(out);
      final dns = config['dns'] as Map<String, dynamic>;
      expect(dns['servers'], [
        {'address': '127.0.0.1', 'port': 15353},
      ]);
      // The forwarder owns the list in counting mode: a core-side
      // hosts entry would be answered without ever being counted.
      expect(dns.containsKey('hosts'), isFalse);
      // The dns-out machinery is unchanged.
      final outbounds = config['outbounds'] as List;
      expect(
        outbounds.any((o) =>
            o is Map && o['protocol'] == 'dns' && o['tag'] == 'dns-out'),
        isTrue,
      );
      final rules = (config['routing'] as Map)['rules'] as List;
      expect(
        rules.any((r) => r is Map && r['outboundTag'] == 'dns-out'),
        isTrue,
      );
      // Anti-detect: the stub-IP redirect is present in counting
      // mode too (the forwarder answers blocked A with the stub IP).
      expect(
        rules.any((r) =>
            r is Map &&
            r['outboundTag'] == 'adshield-stub' &&
            '${r['ip']}' == '[10.10.10.3/32]'),
        isTrue,
      );
    });

    test('without a counting port the hosts injection is unchanged', () {
      final out = AdShieldService.injectXrayHosts(_pluginConfig(), _testHosts);
      final dns = _decode(out)['dns'] as Map<String, dynamic>;
      expect(dns['hosts'], _testHosts);
      expect(dns['servers'], ['9.9.9.9', '149.112.112.112']);
    });
  });
}
