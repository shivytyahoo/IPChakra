import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/services/health_service.dart';

void main() {
  test('OpenVPN remote + proto parse hota hai', () {
    final h = HealthService();
    const tcpCfg =
        'client\ndev tun\nproto tcp\nremote de20.vpnbook.com 443\n<ca>\nxx\n</ca>';
    final t = h.debugParseRemote(tcpCfg);
    expect(t?.$1, 'de20.vpnbook.com');
    expect(t?.$2, 443);
    expect(t?.$3, isFalse);

    const udpCfg =
        'client\ndev tun\nproto udp\nremote 1.2.3.4 1194\n<ca>\nxx\n</ca>';
    final u = h.debugParseRemote(udpCfg);
    expect(u?.$1, '1.2.3.4');
    expect(u?.$2, 1194);
    expect(u?.$3, isTrue);
  });

  test('ss link se host:port nikalta hai', () {
    final h = HealthService();
    const link =
        'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@185.156.47.97:9443#%F0%9F%87%A8CA-1';
    final t = h.debugParseSs(link);
    expect(t?.$1, '185.156.47.97');
    expect(t?.$2, 9443);
  });

  test('galat input pe null', () {
    final h = HealthService();
    expect(h.debugParseRemote('client\ndev tun\n'), isNull);
    expect(h.debugParseSs('not-a-link'), isNull);
    expect(h.debugParseSs(null), isNull);
  });
}
