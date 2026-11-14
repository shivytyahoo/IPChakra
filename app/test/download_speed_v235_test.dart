// v2.3.5 download-speed sort tests.
//
// The old "fastest" was handshake latency only: a relay answering a
// TCP probe in 20 ms but pushing 1 Mbps outranked one answering in
// 80 ms and pushing 200 Mbps. The Fastest lists now sort by download
// speed instead — measured Mbps first, feed-advertised Mbps next,
// latency only as the last fallback — and a "Test speed" run measures
// the real thing by downloading a file through the live tunnel.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/models/vpn_server.dart';
import 'package:ipchakra/services/health_service.dart';
import 'package:ipchakra/services/speed_test_service.dart';
import 'package:ipchakra/services/tunnel_verifier.dart';
import 'package:ipchakra/services/vpngate_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

VpnServer _server({
  required String id,
  String protocol = 'openvpn',
  String source = 'vpngate',
  int? pingMs,
  double? speedMbps,
}) {
  return VpnServer(
    id: id,
    name: id,
    country: 'JP',
    protocol: protocol,
    source: source,
    pingMs: pingMs,
    speedMbps: speedMbps,
  );
}

class _FakeConnector implements SpeedTestConnector {
  _FakeConnector({this.failConnect = const {}, this._current});

  final Set<String> failConnect;
  VpnServer? _current;
  final List<String> connectLog = [];

  @override
  VpnServer? get currentServer => _current;

  @override
  bool get isConnected => _current != null;

  @override
  Future<void> connect(VpnServer s) async {
    if (failConnect.contains(s.id)) throw Exception('connect failed');
    _current = s;
    connectLog.add(s.id);
  }

  @override
  Future<void> disconnect() async {
    _current = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('sortByDownloadSpeed', () {
    test('measured Mbps first, advertised next, latency last', () {
      final health = HealthService();
      final servers = [
        _server(id: 'lat-20', pingMs: 20),
        _server(id: 'adv-500', pingMs: 200, speedMbps: 500),
        _server(id: 'meas-5', pingMs: 300),
        _server(id: 'meas-50', pingMs: 300),
        _server(id: 'adv-10', pingMs: 30, speedMbps: 10),
        _server(id: 'unchecked', pingMs: 5),
        _server(id: 'dead', pingMs: 5),
      ];
      for (final s in servers) {
        if (s.id == 'unchecked') continue;
        health.status[s.id] = s.id != 'dead';
      }
      health.status['dead'] = false;
      health.latencyMs['lat-20'] = 20;
      health.latencyMs['adv-500'] = 200;
      health.latencyMs['meas-5'] = 300;
      health.latencyMs['meas-50'] = 300;
      health.latencyMs['adv-10'] = 30;
      health.speedMbps['meas-5'] = 5;
      health.speedMbps['meas-50'] = 50;

      final sorted =
          sortByDownloadSpeed(servers, health).map((s) => s.id).toList();
      expect(sorted, [
        'meas-50', // measured 50 Mbps beats everything
        'meas-5', // measured 5 Mbps beats any advertised claim
        'adv-500', // advertised 500 Mbps
        'adv-10', // advertised 10 Mbps
        'lat-20', // working, no speed: lowest latency first
        'unchecked',
        'dead',
      ]);
    });

    test('equal speeds keep input order (stable)', () {
      final health = HealthService();
      final servers = [
        _server(id: 'a', pingMs: 10),
        _server(id: 'b', pingMs: 10),
      ];
      health.status['a'] = true;
      health.status['b'] = true;
      health.speedMbps['a'] = 25;
      health.speedMbps['b'] = 25;
      final sorted =
          sortByDownloadSpeed(servers, health).map((s) => s.id).toList();
      expect(sorted, ['a', 'b']);
    });
  });

  group('measured speed persistence', () {
    test('v4 entries load with speed; legacy v3 entries load without',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'health_results_v1': jsonEncode({
          'srv-new': [1, 42, 12500, now],
          'srv-old': [1, 42, now],
        }),
      });
      final health = HealthService();
      await health.loadPersisted();
      expect(health.speedOf('srv-new'), 12.5);
      expect(health.latencyOf('srv-new'), 42);
      expect(health.speedOf('srv-old'), isNull);
      expect(health.latencyOf('srv-old'), 42);
    });

    test('recordSpeed proves working and persists as a v4 entry',
        () async {
      final health = HealthService();
      health.recordSpeed('srv-x', 87.3);
      expect(health.isWorking('srv-x'), isTrue);
      expect(health.speedOf('srv-x'), 87.3);
      // The debounced persist runs 800 ms after the record.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final prefs = await SharedPreferences.getInstance();
      final doc =
          jsonDecode(prefs.getString('health_results_v1')!) as Map;
      final entry = doc['srv-x'] as List;
      expect(entry.length, 4);
      expect(entry[0], 1);
      expect(entry[2], 87300);
    });
  });

  group('VPNGate advertised speed', () {
    test('Speed column becomes VpnServer.speedMbps', () {
      final config =
          base64Encode(utf8.encode('client\nremote 192.0.2.1 1194\n<ca>x</ca>'));
      final csv = [
        '*vpn_servers',
        '#HostName,IP,Score,Ping,Speed,CountryLong,CountryShort,NumVpnSessions,Uptime,TotalUsers,TotalTraffic,LogType,Operator,Message,OpenVPN_ConfigData_Base64',
        'public-vpn-1,192.0.2.1,100,42,125000000,Japan,JP,10,100,1000,1000,2weeks,Op,,$config',
      ].join('\n');
      final servers = VpnGateService().debugParse(csv);
      expect(servers, hasLength(1));
      expect(servers.single.speedMbps, 125);
      expect(servers.single.pingMs, 42);
    });
  });

  group('ServerSpeedTest loop (fake connector)', () {
    test('measures in order, records speeds, restores prior session',
        () async {
      final health = HealthService();
      final prev = _server(id: 'prev', protocol: 'openvpn');
      final connector = _FakeConnector(current: prev);
      final speeds = {'a': 10.0, 'b': 40.0};
      final test = ServerSpeedTest(
        connector: connector,
        health: health,
        debugDownload: (s) async => speeds[s.id],
      );
      final progress = <String>[];
      await test.testCandidates(
        [_server(id: 'a'), _server(id: 'b')],
        onProgress: (done, total, name) => progress.add('$done/$total $name'),
        isCancelled: () => false,
      );
      expect(health.speedOf('a'), 10);
      expect(health.speedOf('b'), 40);
      // The previous session is restored after the run.
      expect(connector.currentServer?.id, 'prev');
      expect(connector.connectLog.last, 'prev');
      expect(progress, isNotEmpty);
    });

    test('a failed connect is skipped and the run continues', () async {
      final health = HealthService();
      final connector = _FakeConnector(failConnect: {'bad'});
      final test = ServerSpeedTest(
        connector: connector,
        health: health,
        debugDownload: (s) async => 20.0,
      );
      await test.testCandidates(
        [_server(id: 'bad'), _server(id: 'good')],
        onProgress: (_, _, _) {},
        isCancelled: () => false,
      );
      expect(health.speedOf('bad'), isNull);
      expect(health.speedOf('good'), 20);
    });

    test('cancel stops the run and still restores the session', () async {
      final health = HealthService();
      final prev = _server(id: 'prev');
      final connector = _FakeConnector(current: prev);
      var calls = 0;
      final test = ServerSpeedTest(
        connector: connector,
        health: health,
        debugDownload: (s) async {
          calls++;
          return 30.0;
        },
      );
      await test.testCandidates(
        [_server(id: 'a'), _server(id: 'b')],
        onProgress: (_, _, _) {},
        isCancelled: () => true,
      );
      expect(calls, 0, reason: 'cancelled before the first candidate');
      expect(connector.currentServer?.id, 'prev');
    });

    test('already-connected candidate is measured without reconnecting',
        () async {
      final health = HealthService();
      final current = _server(id: 'a');
      final connector = _FakeConnector(current: current);
      final test = ServerSpeedTest(
        connector: connector,
        health: health,
        debugDownload: (s) async => 15.0,
      );
      await test.testCandidates(
        [current],
        onProgress: (_, _, _) {},
        isCancelled: () => false,
      );
      expect(connector.connectLog, isEmpty,
          reason: 'no reconnect for the server already connected');
      expect(health.speedOf('a'), 15);
      expect(connector.currentServer?.id, 'a',
          reason: 'the live session is left alone');
    });
  });

  test('SOCKS download returns null when no tunnel is listening', () async {
    // Nothing listens on 127.0.0.1:10807 in the test VM, so the
    // SOCKS connect is refused and the measurement reports null
    // instead of hanging or throwing.
    expect(await TunnelVerifier.downloadSpeedMbps(), isNull);
  });
}
