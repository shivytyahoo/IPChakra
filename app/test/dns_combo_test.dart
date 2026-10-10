// Tests for the pure (server, DNS) combination logic behind the
// verified stealth connect: candidate ordering, combination
// building, manual attempts and the verification gate.
import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/services/dns_combo.dart';
import 'package:ipchakra/services/dns_service.dart';

DnsProvider _p(String id) => DnsService.byId(id);

VpnServer _server(String id) => VpnServer(
      id: id,
      name: id,
      protocol: 'v2ray',
      source: 'v2ray',
      tier: 'TLS',
    );

void main() {
  group('orderDnsCandidates', () {
    test('the selected provider leads when it answered, even if a '
        'rival measured faster', () {
      final ordered = orderDnsCandidates(
        selected: _p('quad9'),
        measured: {'quad9': 80, 'google': 20, 'cloudflare': 40},
      );
      expect(ordered.map((p) => p.id),
          ['quad9', 'google', 'cloudflare']);
    });

    test('when the selected provider did not answer, the fastest '
        'answering provider leads and the dead one is excluded', () {
      final ordered = orderDnsCandidates(
        selected: _p('quad9'),
        measured: {'quad9': null, 'google': 55, 'cloudflare': 30},
      );
      expect(ordered.map((p) => p.id), ['cloudflare', 'google']);
    });

    test('nothing answering yields an empty candidate list', () {
      final ordered = orderDnsCandidates(
        selected: _p('cloudflare'),
        measured: {'cloudflare': null, 'quad9': null},
      );
      expect(ordered, isEmpty);
    });
  });

  group('manualDnsAttempts', () {
    test('selected first, then the fastest other answering provider',
        () {
      final attempts = manualDnsAttempts(
        selected: _p('quad9'),
        measured: {'quad9': null, 'google': 25, 'cloudflare': 60},
      );
      expect(attempts.map((p) => p.id), ['quad9', 'google']);
    });

    test('only the selected provider when nothing else answered', () {
      final attempts = manualDnsAttempts(
        selected: _p('quad9'),
        measured: {'quad9': 30},
      );
      expect(attempts.map((p) => p.id), ['quad9']);
    });
  });

  group('buildDnsServerCombos', () {
    final servers = [for (var i = 0; i < 8; i++) _server('s$i')];

    test('primary DNS takes the top servers first, then the second '
        'DNS, capped at 6', () {
      final combos = buildDnsServerCombos(
        servers: servers,
        dnsOrdered: [_p('quad9'), _p('google'), _p('cloudflare')],
        fallbackDns: _p('cloudflare'),
      );
      expect(combos.length, 6);
      expect(
        combos.map((c) => '${c.$1.id}/${c.$2.id}'),
        [
          's0/quad9', 's1/quad9', 's2/quad9',
          's0/google', 's1/google', 's2/google',
        ],
      );
    });

    test('a single DNS candidate pairs with up to 6 servers', () {
      final combos = buildDnsServerCombos(
        servers: servers,
        dnsOrdered: [_p('quad9')],
        fallbackDns: _p('cloudflare'),
      );
      expect(combos.length, 6);
      expect(combos.every((c) => c.$2.id == 'quad9'), isTrue);
      expect(combos.map((c) => c.$1.id),
          ['s0', 's1', 's2', 's3', 's4', 's5']);
    });

    test('no answering provider falls back to the selected DNS', () {
      final combos = buildDnsServerCombos(
        servers: servers,
        dnsOrdered: const [],
        fallbackDns: _p('quad9'),
      );
      expect(combos, isNotEmpty);
      expect(combos.every((c) => c.$2.id == 'quad9'), isTrue);
    });

    test('no servers means no combinations', () {
      expect(
        buildDnsServerCombos(
          servers: const [],
          dnsOrdered: [_p('quad9')],
          fallbackDns: _p('cloudflare'),
        ),
        isEmpty,
      );
    });
  });

  group('comboVerified', () {
    test('both checks passing with a changed exit verifies', () {
      expect(
        comboVerified(
          dnsOk: true,
          fetchOk: true,
          tunnelIp: '203.0.113.9',
          baselineIp: '198.51.100.2',
        ),
        isTrue,
      );
    });

    test('a failed fetch rejects the combination even when the exit '
        'IP changed', () {
      // The exact "Connected but no internet" failure: an address
      // change alone must never be enough.
      expect(
        comboVerified(
          dnsOk: true,
          fetchOk: false,
          tunnelIp: '203.0.113.9',
          baselineIp: '198.51.100.2',
        ),
        isFalse,
      );
    });

    test('a failed DNS check rejects the combination', () {
      expect(
        comboVerified(
          dnsOk: false,
          fetchOk: true,
          tunnelIp: '203.0.113.9',
          baselineIp: '198.51.100.2',
        ),
        isFalse,
      );
    });

    test('an unchanged exit address rejects the combination', () {
      expect(
        comboVerified(
          dnsOk: true,
          fetchOk: true,
          tunnelIp: '198.51.100.2',
          baselineIp: '198.51.100.2',
        ),
        isFalse,
      );
    });

    test('an unknown baseline still verifies on the checks alone', () {
      expect(
        comboVerified(
          dnsOk: true,
          fetchOk: true,
          tunnelIp: '203.0.113.9',
          baselineIp: null,
        ),
        isTrue,
      );
      expect(
        comboVerified(
          dnsOk: true,
          fetchOk: true,
          tunnelIp: null,
          baselineIp: null,
        ),
        isFalse,
      );
    });
  });
}
