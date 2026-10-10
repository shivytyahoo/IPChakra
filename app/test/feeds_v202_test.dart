// Tests for the v2.0.2 additions: the tap-to-disconnect decision, the
// new public feed formats (Epodonios plain text, Pawdroid base64
// subscription) and the private stealth.json feed parser.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ipchakra/services/v2ray_service.dart';
import 'package:ipchakra/services/vpn_controller.dart';

void main() {
  group('shouldToggleDisconnect truth table', () {
    test('connected + same server disconnects', () {
      expect(
        shouldToggleDisconnect(VpnState.connected, 'srv-1', 'srv-1'),
        isTrue,
      );
    });

    test('connecting + same server disconnects (cancels the attempt)', () {
      expect(
        shouldToggleDisconnect(VpnState.connecting, 'srv-1', 'srv-1'),
        isTrue,
      );
    });

    test('connected + different server connects instead', () {
      expect(
        shouldToggleDisconnect(VpnState.connected, 'srv-1', 'srv-2'),
        isFalse,
      );
    });

    test('disconnected never toggles, even for the same id', () {
      expect(
        shouldToggleDisconnect(VpnState.disconnected, 'srv-1', 'srv-1'),
        isFalse,
      );
      expect(
        shouldToggleDisconnect(VpnState.disconnected, null, 'srv-1'),
        isFalse,
      );
    });

    test('disconnecting and error states never toggle', () {
      expect(
        shouldToggleDisconnect(VpnState.disconnecting, 'srv-1', 'srv-1'),
        isFalse,
      );
      expect(
        shouldToggleDisconnect(VpnState.error, 'srv-1', 'srv-1'),
        isFalse,
      );
    });

    test('no current server never toggles', () {
      expect(
        shouldToggleDisconnect(VpnState.connected, null, 'srv-1'),
        isFalse,
      );
      expect(
        shouldToggleDisconnect(VpnState.connecting, null, 'srv-1'),
        isFalse,
      );
    });
  });

  group('Epodonios-style plain feed extraction', () {
    test('extracts every scheme and keeps Reality links', () {
      const body = 'vless://u@a.example.com:443?security=reality#R1\n'
          'vless://u@b.example.com:443?security=tls#T1\n'
          'ss://YWVzLTI1Ni1nY206cGFzcw==@c.example.com:8388#S1\n'
          'trojan://pw@d.example.com:443#J1\n'
          'this line is not a link\n'
          'vless://u@a.example.com:443?security=reality#R1\n';
      final links = V2RayService.debugExtractLinks(body);
      // 4 unique valid links; the prose line and the duplicate go away.
      expect(links.length, 4);
      expect(links.where((l) => l.contains('reality')).length, 1);
    });
  });

  group('Pawdroid-style subscription extraction', () {
    test('a base64 body decodes and yields its links', () {
      const plain = 'vless://u@a.example.com:443?security=reality#R1\n'
          'trojan://pw@d.example.com:443#J1\n'
          'ss://YWVzLTI1Ni1nY206cGFzcw==@c.example.com:8388#S1';
      final body = base64Encode(utf8.encode(plain));
      final links = V2RayService.debugExtractFromSubscriptionBody(body);
      expect(links.length, 3);
      expect(links.any((l) => l.contains('reality')), isTrue);
    });

    test('a plain-text body is accepted as-is', () {
      const body = 'trojan://pw@d.example.com:443#J1';
      final links = V2RayService.debugExtractFromSubscriptionBody(body);
      expect(links, [body]);
    });
  });

  group('stealth.json parser', () {
    test('a valid document yields its valid links', () {
      const body = '{"version": 1, "servers": ['
          '"vless://u@a.example.com:443?security=reality#R1",'
          '"ss://YWVzLTI1Ni1nY206cGFzcw==@c.example.com:8388#S1"'
          ']}';
      final links = V2RayService.debugParseStealthJson(body);
      expect(links, isNotNull);
      expect(links!.length, 2);
    });

    test('mixed valid and invalid entries keep only the valid ones', () {
      const body = '{"version": 1, "servers": ['
          '"not a link",'
          '"vless://u@a.example.com:443?security=reality#R1",'
          '42,'
          '"",'
          '"vless://u@a.example.com:443?security=reality#R1"'
          ']}';
      final links = V2RayService.debugParseStealthJson(body);
      expect(links, isNotNull);
      expect(links!.length, 1);
    });

    test('an empty servers array is a valid, empty result', () {
      final links =
          V2RayService.debugParseStealthJson('{"version": 1, "servers": []}');
      expect(links, isNotNull);
      expect(links, isEmpty);
    });

    test('invalid JSON returns null (treated as "no document")', () {
      expect(V2RayService.debugParseStealthJson('not json at all'), isNull);
      expect(V2RayService.debugParseStealthJson(''), isNull);
    });

    test('valid JSON without a servers list returns null', () {
      expect(V2RayService.debugParseStealthJson('{"version": 1}'), isNull);
      expect(
        V2RayService.debugParseStealthJson('{"servers": "vless://x"}'),
        isNull,
      );
      expect(V2RayService.debugParseStealthJson('[1, 2, 3]'), isNull);
    });
  });

  group('private feed servers', () {
    test('a private link builds a server with the Private source', () {
      final svc = V2RayService();
      final s = svc.debugToServerWithSource(
        'vless://u@a.example.com:443?security=reality#Priv',
        source: 'private',
      );
      expect(s, isNotNull);
      expect(s!.source, 'private');
      expect(s.id, startsWith('private-'));
      expect(s.tier, 'Reality');
    });
  });
}
