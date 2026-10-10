// Tests for the v2.0.1 DNS provider feature: catalogue integrity,
// the pure DNS query/response packet helpers, Xray config injection,
// and selection persistence.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ipchakra/services/dns_service.dart';

bool _isValidIpv4(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return false;
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return false;
    if (part.length > 1 && part.startsWith('0')) return false;
  }
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('provider catalogue integrity', () {
    test('every entry has a unique id and a valid IPv4 primary', () {
      final ids = <String>{};
      for (final p in DnsService.providers) {
        expect(ids.add(p.id), isTrue, reason: 'duplicate id ${p.id}');
        expect(_isValidIpv4(p.primary), isTrue, reason: p.id);
        if (p.secondary != null) {
          expect(_isValidIpv4(p.secondary!), isTrue, reason: p.id);
          expect(p.secondary, isNot(p.primary), reason: p.id);
        }
        expect(p.name, isNotEmpty, reason: p.id);
        expect(
          ['Fast', 'Ad blocking', 'Family', 'Malware blocking', 'Unfiltered'],
          contains(p.tag),
          reason: p.id,
        );
      }
      // The full catalogue was requested; guard against accidental
      // truncation of the list.
      expect(DnsService.providers.length, greaterThanOrEqualTo(25));
    });

    test('default selection is Cloudflare 1.1.1.1', () {
      final d = DnsService.byId(null);
      expect(d.id, DnsService.defaultProviderId);
      expect(d.primary, '1.1.1.1');
      expect(d.secondary, '1.0.0.1');
      expect(d.servers, ['1.1.1.1', '1.0.0.1']);
      // Unknown ids fall back to the default too.
      expect(DnsService.byId('no-such-provider').id, d.id);
    });
  });

  group('DNS packet helpers', () {
    test('buildAQuery produces a well-formed A query', () {
      final packet = DnsService.buildAQuery('example.com', 0x1234);
      final data = ByteData.view(packet.buffer);
      expect(data.getUint16(0), 0x1234); // transaction id
      expect(data.getUint16(2) & 0x0100, 0x0100); // RD flag
      expect(data.getUint16(4), 1); // QDCOUNT
      expect(data.getUint16(6), 0); // ANCOUNT
      // QNAME: 7 'example' 3 'com' 0
      expect(packet[12], 7);
      expect(String.fromCharCodes(packet.sublist(13, 20)), 'example');
      expect(packet[20], 3);
      expect(String.fromCharCodes(packet.sublist(21, 24)), 'com');
      expect(packet[24], 0);
      expect(data.getUint16(25), 1); // QTYPE A
      expect(data.getUint16(27), 1); // QCLASS IN
      expect(packet.length, 29);
    });

    test('isValidResponse accepts only matching QR-set responses', () {
      final response = Uint8List.fromList(DnsService.buildAQuery('a.b', 7));
      final data = ByteData.view(response.buffer);
      // Turn it into a response by setting the QR bit.
      data.setUint16(2, data.getUint16(2) | 0x8000);
      expect(DnsService.isValidResponse(response, 7), isTrue);
      expect(DnsService.isValidResponse(response, 8), isFalse);
      // A query (QR clear) is not a response.
      final query = DnsService.buildAQuery('a.b', 7);
      expect(DnsService.isValidResponse(query, 7), isFalse);
      // Truncated packets are rejected.
      expect(DnsService.isValidResponse(Uint8List(4), 7), isFalse);
    });
  });

  group('Xray config injection', () {
    test('injectDnsServers sets the top-level dns object', () {
      const sample = '{"inbounds":[],"outbounds":[{"protocol":"freedom"}]}';
      final out = DnsService.injectDnsServers(sample, ['9.9.9.9', '149.112.112.112']);
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['dns'], {
        'servers': ['9.9.9.9', '149.112.112.112'],
        'queryStrategy': 'UseIPv4',
      });
      // The rest of the config survives the round-trip.
      expect(decoded['outbounds'], isNotEmpty);
    });

    test('injectDnsServers replaces an existing dns object', () {
      const sample = '{"dns":{"servers":["8.8.8.8"]},"outbounds":[]}';
      final out = DnsService.injectDnsServers(sample, ['1.1.1.1']);
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['dns'], {
        'servers': ['1.1.1.1'],
        'queryStrategy': 'UseIPv4',
      });
    });

    test('applyStealthDns adds the dns object and the DNS routing '
        'rule, exactly once', () {
      const sample = '{"routing":{"domainStrategy":"UseIp"},'
          '"outbounds":[{"protocol":"freedom"}]}';
      final out = DnsService.applyStealthDns(sample, ['9.9.9.9']);
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      expect(decoded['dns'], {
        'servers': ['9.9.9.9'],
        'queryStrategy': 'UseIPv4',
      });
      final rules = (decoded['routing'] as Map)['rules'] as List;
      expect(rules, hasLength(1));
      expect(rules.single, {
        'type': 'field',
        'port': '853',
        'outboundTag': 'direct',
      });
      // Re-applying must not stack a second copy of the rule.
      final again = DnsService.applyStealthDns(out, ['9.9.9.9']);
      final decodedAgain = jsonDecode(again) as Map<String, dynamic>;
      expect((decodedAgain['routing'] as Map)['rules'], hasLength(1));
    });

    test('applyStealthDns preserves existing routing rules and never '
        'breaks a malformed config', () {
      const sample = '{"routing":{"domainStrategy":"UseIp","rules":'
          '[{"type":"field","port":"1234","outboundTag":"proxy"}]},'
          '"outbounds":[]}';
      final out = DnsService.applyStealthDns(sample, ['1.1.1.1']);
      final decoded = jsonDecode(out) as Map<String, dynamic>;
      final rules = (decoded['routing'] as Map)['rules'] as List;
      expect(rules, hasLength(2));
      expect(rules.first['port'], '1234');
      expect(DnsService.applyStealthDns('not json', ['1.1.1.1']),
          'not json');
      expect(DnsService.applyStealthDns(sample, const []), sample);
    });

    test('injectDnsServers never breaks a malformed config', () {
      expect(DnsService.injectDnsServers('not json', ['1.1.1.1']), 'not json');
      expect(DnsService.injectDnsServers('[1,2]', ['1.1.1.1']), '[1,2]');
      const sample = '{"outbounds":[]}';
      expect(DnsService.injectDnsServers(sample, const []), sample);
    });
  });

  group('selection persistence', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('selection survives a reload and loadSelected agrees', () async {
      final service = DnsService();
      await service.load();
      expect(service.selected.id, 'cloudflare');

      await service.select(DnsService.byId('quad9'));
      expect(service.selected.id, 'quad9');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(DnsService.prefsKey), 'quad9');

      final reloaded = DnsService();
      await reloaded.load();
      expect(reloaded.selected.id, 'quad9');
      expect((await DnsService.loadSelected()).id, 'quad9');
      expect(reloaded.selected.servers, ['9.9.9.9', '149.112.112.112']);
    });
  });
}
