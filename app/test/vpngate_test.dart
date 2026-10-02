import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/services/vpngate_service.dart';

void main() {
  test('VPNGate CSV parse hota hai', () {
    final svc = VpnGateService();
    // Sample: header + 2 servers (config chhota dummy, <ca> zaroori hai)
    final configB64 =
        'IyBkdW1teQ0KPGNhPiBkdW1teSBjYTwvY2E+'; // "# dummy\r\n<ca> dummy ca</ca>"
    final csv = '*vpngate\n'
        '#HostName,IP,Score,Ping,Speed,CountryLong,CountryShort,NumVpnSessions,Uptime,TotalUsers,TotalTraffic,LogType,Operator,Message,OpenVPN_ConfigData_Base64\n'
        'public-vpn-1,1.2.3.4,100,25,50000000,Japan,JP,10,100,200,300,2weeks,Op,,$configB64\n'
        'public-vpn-2,5.6.7.8,90,60,20000000,Germany,DE,5,100,200,300,2weeks,Op,,$configB64\n';
    final servers = svc.debugParse(csv);
    expect(servers.length, 2);
    // ping ke hisaab se sort: Japan (25ms) pehle
    expect(servers.first.country, 'Japan');
    expect(servers.first.flag, '🇯🇵');
    expect(servers.first.protocol, 'openvpn');
    expect(servers.first.ovpnConfig, contains('<ca>'));
    expect(svc.debugParse('').isEmpty, true);
  });
}
