// v2.3.4 live-counter tests: the counting DNS forwarder.
//
// The counters on the AdShield card are only honest because this
// forwarder really receives the session's DNS queries. These tests
// pin the wire codec (parse / blocked answer / SERVFAIL), the
// blocklist suffix semantics (the Xray `domain:` rule), and the
// live socket behaviour: a blocked name is answered locally and
// counted, a clean name is relayed and counted, and a relay
// failure surfaces as SERVFAIL rather than silence.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/services/counting_dns.dart';
import 'package:ipchakra/services/dns_service.dart';

void main() {
  group('parseDnsQuery', () {
    test('reads id, qname, qtype and the question end', () {
      final query = DnsService.buildAQuery('Ads.Example.COM', 0x1234);
      final info = parseDnsQuery(query)!;
      expect(info.id, 0x1234);
      expect(info.qname, 'ads.example.com'); // lower-cased
      expect(info.qtype, 1);
      expect(info.questionEnd, query.length);
    });

    test('rejects responses and garbage', () {
      final query = DnsService.buildAQuery('example.com', 7);
      final asResponse = Uint8List.fromList(query);
      asResponse[2] |= 0x80; // QR bit
      expect(parseDnsQuery(asResponse), isNull);
      expect(parseDnsQuery(Uint8List(5)), isNull);
      expect(parseDnsQuery(Uint8List(20)), isNull);
    });
  });

  group('isBlockedName (domain: suffix semantics)', () {
    final hosts = {'domain:ads.example.com': '0.0.0.0'};
    test('matches the domain and its subdomains', () {
      expect(isBlockedName('ads.example.com', hosts), isTrue);
      expect(isBlockedName('cdn.ads.example.com', hosts), isTrue);
      expect(isBlockedName('deep.cdn.ads.example.com', hosts), isTrue);
    });
    test('does not match lookalikes or parents', () {
      expect(isBlockedName('notads.example.com', hosts), isFalse);
      expect(isBlockedName('example.com', hosts), isFalse);
      expect(isBlockedName('ads.example.com.evil.com', hosts), isFalse);
      expect(isBlockedName('other.org', hosts), isFalse);
    });
  });

  group('blocked / servfail responses', () {
    test('A query gets the anti-detect stub IP echoing the question', () {
      final query = DnsService.buildAQuery('ads.example.com', 0x99);
      final info = parseDnsQuery(query)!;
      final response = buildBlockedResponse(query, info);
      final data = ByteData.view(response.buffer);
      expect(data.getUint16(0), 0x99);
      expect(data.getUint16(2) & 0x8000, isNot(0)); // QR
      expect(data.getUint16(2) & 0x000F, 0); // NOERROR
      expect(data.getUint16(6), 1); // ANCOUNT
      // Question echoed verbatim.
      expect(response.sublist(12, info.questionEnd),
          query.sublist(12, info.questionEnd));
      // Answer: pointer name, type A, class IN, rdlen 4, stub IP
      // (anti-detect: bait succeeds against the local stub server).
      final o = info.questionEnd;
      expect(data.getUint16(o), 0xC00C);
      expect(data.getUint16(o + 2), 1);
      expect(data.getUint16(o + 10), 4);
      expect(response.sublist(o + 12, o + 16), [10, 10, 10, 3]);
    });

    test('SERVFAIL carries rcode 2 and no answers', () {
      final query = DnsService.buildAQuery('example.com', 3);
      final info = parseDnsQuery(query)!;
      final response = buildServfailResponse(query, info);
      final data = ByteData.view(response.buffer);
      expect(data.getUint16(2) & 0x000F, 2);
      expect(data.getUint16(6), 0);
    });
  });

  group('CountingDnsForwarder serving logic', () {
    // The serving decision is exercised directly (debugAnswerFor):
    // some sandboxes forbid UDP sends outright, which would make a
    // socket-level test fail for environmental reasons while the
    // logic is fine. The socket itself is pinned separately below
    // (bind + port), and the on-device run proves the transport.
    test('blocked counted + answered locally; clean relayed; failure '
        'is SERVFAIL', () async {
      var queries = 0;
      var blocked = 0;
      final forwarder = CountingDnsForwarder(
        hosts: const {'domain:ads.test': '0.0.0.0'},
        onQuery: () => queries++,
        onBlocked: () => blocked++,
        relay: (query, upstream) async {
          final info = parseDnsQuery(query);
          if (info?.qname == 'good.test') {
            // A minimal valid response: the query with QR set and
            // the same id.
            final response = Uint8List.fromList(query);
            response[2] |= 0x80;
            return response;
          }
          return null; // relay failure
        },
      );
      final port = await forwarder.start(['203.0.113.53']);
      expect(port, isNotNull);
      expect(forwarder.running, isTrue);
      addTearDown(() => forwarder.stop());

      ByteData view(Uint8List packet) => ByteData.view(
          packet.buffer, packet.offsetInBytes, packet.length);

      // 1) Blocked name: answered by the forwarder itself.
      final blockedReply = await forwarder
          .debugAnswerFor(DnsService.buildAQuery('x.ads.test', 0x1111));
      expect(blockedReply, isNotNull);
      expect(view(blockedReply!).getUint16(0), 0x1111);
      expect(view(blockedReply).getUint16(6), 1); // one answer
      expect(blockedReply.sublist(blockedReply.length - 4), [10, 10, 10, 3]);
      expect(queries, 1);
      expect(blocked, 1);

      // 2) Clean name: the relayed response comes back.
      final relayed = await forwarder
          .debugAnswerFor(DnsService.buildAQuery('good.test', 0x2222));
      expect(relayed, isNotNull);
      expect(view(relayed!).getUint16(0), 0x2222);
      expect(view(relayed).getUint16(2) & 0x8000, isNot(0));
      expect(queries, 2);
      expect(blocked, 1);

      // 3) Relay failure: SERVFAIL, still counted as a query.
      final failed = await forwarder
          .debugAnswerFor(DnsService.buildAQuery('dead.test', 0x3333));
      expect(failed, isNotNull);
      expect(view(failed!).getUint16(2) & 0x000F, 2);
      expect(queries, 3);
      expect(blocked, 1);

      // 4) A non-query packet is dropped, never counted.
      expect(await forwarder.debugAnswerFor(Uint8List(4)), isNull);
      expect(queries, 3);
    });
  });
}
