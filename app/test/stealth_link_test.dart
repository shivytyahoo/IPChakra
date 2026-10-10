import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:ipchakra/services/stealth_link.dart';
import 'package:ipchakra/services/v2ray_service.dart';

String vmessLink(Map<String, dynamic> json) =>
    'vmess://${base64Encode(utf8.encode(jsonEncode(json)))}';

void main() {
  group('StealthLink ss', () {
    test('base64 userinfo form parses host, port, remark and tier', () {
      const link =
          'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@185.156.47.97:9443#My%20Server';
      final info = StealthLink.parse(link);
      expect(info, isNotNull);
      expect(info!.scheme, 'ss');
      expect(info.host, '185.156.47.97');
      expect(info.port, 9443);
      expect(info.remark, 'My Server');
      expect(info.tier, 'Shadowsocks');
      expect(info.tierRank, 3);
    });

    test('SIP002 plain userinfo form parses', () {
      const link = 'ss://aes-256-gcm:secret@example.com:8388#Plain';
      final info = StealthLink.parse(link);
      expect(info, isNotNull);
      expect(info!.host, 'example.com');
      expect(info.port, 8388);
      expect(info.remark, 'Plain');
      expect(info.tier, 'Shadowsocks');
    });

    test('SIP002 query string is stripped from host and port', () {
      const link =
          'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@example.com:8388?plugin=obfs-local#Q';
      final info = StealthLink.parse(link);
      expect(info, isNotNull);
      expect(info!.host, 'example.com');
      expect(info.port, 8388);
    });

    test('IPv6 host in brackets parses', () {
      const link = 'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@[2001:db8::1]:8388#v6';
      final info = StealthLink.parse(link);
      expect(info, isNotNull);
      expect(info!.host, '2001:db8::1');
      expect(info.port, 8388);
    });

    test('fully base64 legacy form parses', () {
      final inner = base64Encode(
          utf8.encode('aes-256-gcm:secret@legacy.example.com:1234'));
      final info = StealthLink.parse('ss://$inner#Legacy');
      expect(info, isNotNull);
      expect(info!.host, 'legacy.example.com');
      expect(info.port, 1234);
      expect(info.remark, 'Legacy');
    });
  });

  group('StealthLink vless and trojan', () {
    test('vless with security=reality is the Reality tier', () {
      const link = 'vless://b831381d-6324-4d53-ad4f-8cda48b30811'
          '@reality.example.com:443?encryption=none&security=reality'
          '&sni=www.microsoft.com&fp=chrome#Reality%20One';
      final info = StealthLink.parse(link);
      expect(info, isNotNull);
      expect(info!.scheme, 'vless');
      expect(info.host, 'reality.example.com');
      expect(info.port, 443);
      expect(info.remark, 'Reality One');
      expect(info.tier, 'Reality');
      expect(info.tierRank, 0);
    });

    test('vless with security=tls is the TLS tier and defaults to 443', () {
      const link = 'vless://b831381d-6324-4d53-ad4f-8cda48b30811'
          '@tls.example.com?security=tls&sni=tls.example.com#TlsOne';
      final info = StealthLink.parse(link);
      expect(info, isNotNull);
      expect(info!.port, 443);
      expect(info.tier, 'TLS');
      expect(info.tierRank, 2);
    });

    test('trojan is always the TLS tier', () {
      const link = 'trojan://secret@trojan.example.com:8443?sni=x#TrojanOne';
      final info = StealthLink.parse(link);
      expect(info, isNotNull);
      expect(info!.scheme, 'trojan');
      expect(info.host, 'trojan.example.com');
      expect(info.port, 8443);
      expect(info.remark, 'TrojanOne');
      expect(info.tier, 'TLS');
      expect(info.tierRank, 2);
    });
  });

  group('StealthLink vmess', () {
    test('vmess with tls field is the TLS tier', () {
      final link = vmessLink({
        'v': '2',
        'ps': 'VMess TLS',
        'add': 'vmess.example.com',
        'port': '443',
        'id': 'b831381d-6324-4d53-ad4f-8cda48b30811',
        'aid': '0',
        'net': 'ws',
        'tls': 'tls',
      });
      final info = StealthLink.parse(link);
      expect(info, isNotNull);
      expect(info!.scheme, 'vmess');
      expect(info.host, 'vmess.example.com');
      expect(info.port, 443);
      expect(info.remark, 'VMess TLS');
      expect(info.tier, 'TLS');
      expect(info.tierRank, 2);
    });

    test('vmess without tls is the VMess tier, numeric port works', () {
      final link = vmessLink({
        'v': '2',
        'ps': 'VMess Plain',
        'add': 'plain.example.com',
        'port': 2053,
        'id': 'b831381d-6324-4d53-ad4f-8cda48b30811',
        'tls': '',
      });
      final info = StealthLink.parse(link);
      expect(info, isNotNull);
      expect(info!.port, 2053);
      expect(info.tier, 'VMess');
      expect(info.tierRank, 4);
    });

    test('vmess base64url alphabet and missing padding still parse', () {
      final link = vmessLink({
        'ps': 'Padded',
        'add': 'pad.example.com',
        'port': '8443',
        'tls': '',
      });
      var payload = link.substring('vmess://'.length);
      payload = payload
          .replaceAll('+', '-')
          .replaceAll('/', '_')
          .replaceAll('=', '');
      final info = StealthLink.parse('vmess://$payload');
      expect(info, isNotNull);
      expect(info!.host, 'pad.example.com');
      expect(info.port, 8443);
      expect(info.remark, 'Padded');
    });
  });

  group('StealthLink hysteria2', () {
    test('full link parses auth, sni, insecure, obfs and alpn', () {
      const link = 'hysteria2://secretpw@hy.example.com:8443'
          '?sni=cdn.example.com&insecure=1&obfs=salamander'
          '&obfs-password=obfspw&alpn=h3#Hy%20One';
      final info = StealthLink.parse(link);
      expect(info, isNotNull);
      expect(info!.scheme, 'hysteria2');
      expect(info.host, 'hy.example.com');
      expect(info.port, 8443);
      expect(info.remark, 'Hy One');
      expect(info.tier, 'Hysteria2');
      expect(info.tierRank, 1);
      expect(info.auth, 'secretpw');
      expect(info.sni, 'cdn.example.com');
      expect(info.allowInsecure, isTrue);
      expect(info.obfsType, 'salamander');
      expect(info.obfsPassword, 'obfspw');
      expect(info.alpn, ['h3']);
    });

    test('hy2:// alias normalises to the hysteria2 scheme', () {
      final info = StealthLink.parse('hy2://pw@h.example.com:443#x');
      expect(info, isNotNull);
      expect(info!.scheme, 'hysteria2');
      expect(info.tier, 'Hysteria2');
      expect(info.allowInsecure, isFalse);
    });

    test('mport becomes the hop range and its first port is the '
        'concrete port when the authority has none', () {
      final info = StealthLink.parse(
          'hysteria2://pw@h.example.com?mport=24000-24999#x');
      expect(info, isNotNull);
      expect(info!.port, 24000);
      expect(info.portHop, '24000-24999');
      // With neither an authority port nor mport, the hy2 default
      // 443 applies.
      final plain = StealthLink.parse('hysteria2://pw@h.example.com#x');
      expect(plain!.port, 443);
      expect(plain.portHop, isNull);
    });

    test('percent-encoded auth is decoded', () {
      final info = StealthLink.parse(
          'hysteria2://github.com%2Fsome-user@h.example.com:443#x');
      expect(info, isNotNull);
      expect(info!.auth, 'github.com/some-user');
    });

    test('pinSHA256 and its pcs alias are read', () {
      final a = StealthLink.parse(
          'hysteria2://pw@h.example.com:443?pinSHA256=AB12CD#x');
      expect(a!.pinSha256, 'AB12CD');
      final b = StealthLink.parse(
          'hysteria2://pw@h.example.com:443?pcs=EF34#x');
      expect(b!.pinSha256, 'EF34');
    });

    test('fm parameter decodes into the finalmask object', () {
      final fm = Uri.encodeComponent(
          '{"udp":[{"type":"salamander","settings":{"password":"z"}}]}');
      final info =
          StealthLink.parse('hysteria2://pw@h.example.com:443?fm=$fm#x');
      expect(info, isNotNull);
      expect(info!.finalmask, isNotNull);
      expect(info.finalmask!['udp'], isA<List>());
    });

    test('missing or empty auth is rejected', () {
      expect(StealthLink.parse('hysteria2://@h.example.com:443#x'), isNull);
      expect(StealthLink.parse('hysteria2://h.example.com:443#x'), isNull);
      expect(StealthLink.isSupported('hysteria2://pw@h.example.com#x'),
          isTrue);
    });
  });

  group('StealthLink invalid input', () {
    test('unsupported or malformed links return null', () {
      expect(StealthLink.parse(''), isNull);
      expect(StealthLink.parse('not-a-link'), isNull);
      expect(StealthLink.parse('http://example.com:80#x'), isNull);
      expect(StealthLink.parse('ss://'), isNull);
      expect(StealthLink.parse('ss://no-port-here'), isNull);
      expect(StealthLink.parse('vless://'), isNull);
      expect(StealthLink.parse('vmess://!!!not-base64!!!'), isNull);
      expect(StealthLink.parse('vmess://aGVsbG8='), isNull); // "hello"
    });

    test('isSupported matches parse', () {
      expect(
          StealthLink.isSupported('trojan://pw@h.example.com:443#x'), isTrue);
      expect(StealthLink.isSupported('openvpn://example.com'), isFalse);
    });

    test('tier ranks are strictly ordered Reality < Hysteria2 < TLS '
        '< SS < VMess', () {
      final ranks = [
        StealthLink.parse(
                'vless://u@h.example.com:443?security=reality#x')!
            .tierRank,
        StealthLink.parse('hysteria2://pw@h.example.com:443#x')!.tierRank,
        StealthLink.parse('trojan://p@h.example.com:443#x')!.tierRank,
        StealthLink.parse('ss://aes-256-gcm:p@h.example.com:8388#x')!
            .tierRank,
        StealthLink.parse(vmessLink(
                {'add': 'h.example.com', 'port': '443', 'tls': ''}))!
            .tierRank,
      ];
      expect(ranks, [0, 1, 2, 3, 4]);
    });
  });

  group('integration with services', () {
    test('V2RayService builds a stealth server with tier and note', () {
      final svc = V2RayService();
      const link = 'vless://b831381d-6324-4d53-ad4f-8cda48b30811'
          '@de.example.com:443?security=reality#DE-Reality';
      final s = svc.debugToServer(link);
      expect(s, isNotNull);
      expect(s!.protocol, 'v2ray');
      expect(s.isStealth, isTrue);
      expect(s.tier, 'Reality');
      expect(s.note, 'Stealth • Reality');
      expect(s.name, 'DE-Reality');
      expect(s.country, 'Germany');
      expect(s.source, 'v2ray');
      expect(s.shareLink, link);
    });

    test('tierCounts counts servers by tier', () {
      final svc = V2RayService();
      svc.servers = [
        svc.debugToServer(
            'vless://u@a.example.com:443?security=reality#R')!,
        svc.debugToServer('trojan://p@b.example.com:443#T')!,
        svc.debugToServer('ss://aes-256-gcm:p@c.example.com:8388#S')!,
      ];
      expect(svc.tierCounts, {'Reality': 1, 'TLS': 1, 'Shadowsocks': 1});
    });

    test('subscription helpers extract links and decode base64 bodies', () {
      const plain = 'vless://u@a.example.com:443?security=reality#R\n'
          'not a link\n'
          'ss://aes-256-gcm:p@c.example.com:8388#S\n';
      final links = V2RayService.debugExtractLinks(plain);
      expect(links.length, 2);
      final body = base64Encode(utf8.encode(plain));
      expect(V2RayService.debugDecodeSubscription(body), plain);
      expect(V2RayService.debugExtractLinks(
          V2RayService.debugDecodeSubscription(body)!).length, 2);
    });

    test('HealthService resolves probe targets for every scheme', () {
      final h = HealthService();
      expect(
          h.debugParseLink('ss://aes-256-gcm:p@a.example.com:8388#x'),
          ('a.example.com', 8388));
      expect(
          h.debugParseLink(
              'vless://u@b.example.com:443?security=reality#x'),
          ('b.example.com', 443));
      expect(h.debugParseLink('trojan://p@c.example.com#x'),
          ('c.example.com', 443));
      expect(
          h.debugParseLink(
              vmessLink({'add': 'd.example.com', 'port': '2053'})),
          ('d.example.com', 2053));
      expect(h.debugParseLink('not-a-link'), isNull);
      expect(h.debugParseLink(null), isNull);
    });
  });
}
