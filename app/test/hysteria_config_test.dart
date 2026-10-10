// Tests for the hand-built Hysteria2 Xray configuration
// (buildHysteria2Config): the outbound shape the desktop Xray
// validator accepted, the finalmask mapping for obfs / port
// hopping, the DNS treatment shared with every stealth scheme, and
// the deliberate omission of the removed allowInsecure feature.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/services/hysteria_config.dart';
import 'package:ipchakra/services/v2ray_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _build(String link, [List<String> dns = const []]) {
  final out = buildHysteria2Config(link, dns);
  expect(out, isNotNull, reason: 'config should build for $link');
  return jsonDecode(out!) as Map<String, dynamic>;
}

Map<String, dynamic> _outbound(Map<String, dynamic> config) =>
    (config['outbounds'] as List).first as Map<String, dynamic>;

void main() {
  group('buildHysteria2Config', () {
    test('rejects non-Hysteria2 links', () {
      expect(buildHysteria2Config('ss://YWVzLTI1Ni1nY206cA==@h:8388#x',
          const []), isNull);
      expect(buildHysteria2Config('not a link', const []), isNull);
      expect(buildHysteria2Config('hysteria2://@h:443#x', const []),
          isNull);
    });

    test('builds the hysteria outbound with TLS and h3 ALPN', () {
      final config = _build(
        'hysteria2://secretpw@hy.example.com:8443?sni=cdn.example.com#Hy',
        ['9.9.9.9', '149.112.112.112'],
      );
      final outbound = _outbound(config);
      expect(outbound['tag'], 'proxy');
      expect(outbound['protocol'], 'hysteria');
      expect(outbound['settings'], {
        'version': 2,
        'address': 'hy.example.com',
        'port': 8443,
      });
      final stream = outbound['streamSettings'] as Map<String, dynamic>;
      expect(stream['network'], 'hysteria');
      expect(stream['security'], 'tls');
      expect(stream['tlsSettings'], {
        'serverName': 'cdn.example.com',
        'alpn': ['h3'],
      });
      expect(stream['hysteriaSettings'], {
        'version': 2,
        'auth': 'secretpw',
      });
      // The plugin-compatible envelope: socks inbound, helper
      // outbounds, the shared DNS treatment.
      final inbound = (config['inbounds'] as List).single as Map;
      expect(inbound['tag'], 'in_proxy');
      expect(inbound['port'], 10807);
      expect(inbound['protocol'], 'socks');
      expect(
        (config['outbounds'] as List).map((o) => (o as Map)['tag']),
        ['proxy', 'direct', 'blackhole'],
      );
      expect(config['dns'], {
        'servers': ['9.9.9.9', '149.112.112.112'],
        'queryStrategy': 'UseIPv4',
      });
      final rules = (config['routing'] as Map)['rules'] as List;
      expect(rules.single, {
        'type': 'field',
        'port': '853',
        'outboundTag': 'direct',
      });
    });

    test('sni falls back to the host and DNS to the defaults', () {
      final config = _build('hy2://pw@hy.example.com#Hy');
      final stream =
          _outbound(config)['streamSettings'] as Map<String, dynamic>;
      expect((stream['tlsSettings'] as Map)['serverName'], 'hy.example.com');
      expect((_outbound(config)['settings'] as Map)['port'], 443);
      expect((config['dns'] as Map)['servers'], ['8.8.8.8', '8.8.4.4']);
    });

    test('salamander obfs lands in the finalmask', () {
      final config = _build(
        'hysteria2://pw@hy.example.com:443?obfs=salamander'
        '&obfs-password=zz#Hy',
      );
      final stream =
          _outbound(config)['streamSettings'] as Map<String, dynamic>;
      expect(stream['finalmask'], {
        'udp': [
          {
            'type': 'salamander',
            'settings': {'password': 'zz'},
          },
        ],
      });
    });

    test('port hopping lands in finalmask quicParams', () {
      final config = _build(
        'hysteria2://pw@hy.example.com:443?mport=24000-24999#Hy',
      );
      final stream =
          _outbound(config)['streamSettings'] as Map<String, dynamic>;
      final mask = stream['finalmask'] as Map<String, dynamic>;
      expect((mask['quicParams'] as Map)['udpHop'], {
        'ports': '24000-24999',
        'interval': '30',
      });
    });

    test('allowInsecure is never emitted, even for insecure=1 links',
        () {
      // The current Xray core removed the feature: a config carrying
      // it fails to load at all. The builder must omit the key.
      final raw = buildHysteria2Config(
        'hysteria2://pw@hy.example.com:443?insecure=1#Hy',
        const [],
      );
      expect(raw, isNotNull);
      expect(raw, isNot(contains('allowInsecure')));
    });

    test('pinSHA256 is passed through as pinnedPeerCertSha256', () {
      final config = _build(
        'hysteria2://pw@hy.example.com:443?pinSHA256=AB12CD34#Hy',
      );
      final stream =
          _outbound(config)['streamSettings'] as Map<String, dynamic>;
      expect((stream['tlsSettings'] as Map)['pinnedPeerCertSha256'],
          'AB12CD34');
    });

    test('an out-of-range udpIdleTimeout is omitted, a valid one kept',
        () {
      Map<String, dynamic> settingsOf(String link) {
        final stream = _outbound(_build(link))['streamSettings']
            as Map<String, dynamic>;
        return stream['hysteriaSettings'] as Map<String, dynamic>;
      }

      // The core only accepts 2..600 seconds; 900 would fail the
      // whole configuration, so the builder drops it (core default).
      expect(
        settingsOf('hysteria2://pw@hy.example.com:443?udpIdleTimeout=900#Hy'),
        isNot(contains('udpIdleTimeout')),
      );
      expect(
        settingsOf('hysteria2://pw@hy.example.com:443?udpIdleTimeout=45#Hy')
            ['udpIdleTimeout'],
        45,
      );
    });
  });

  group('manual import', () {
    test('addCustomLink accepts a Hysteria2 link via the hand-built '
        'config path', () async {
      SharedPreferences.setMockInitialValues({});
      final svc = V2RayService();
      final server = await svc.addCustomLink(
        'hysteria2://pw@hy.example.com:443?sni=hy.example.com#Imported Hy',
      );
      expect(server, isNotNull);
      expect(server!.tier, 'Hysteria2');
      expect(server.note, 'Stealth • Hysteria2');
      expect(server.source, 'custom');
      // And garbage is still rejected.
      expect(await svc.addCustomLink('hysteria2://@hy.example.com#x'),
          isNull);
    });
  });
}
