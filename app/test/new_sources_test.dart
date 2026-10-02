import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/services/v2ray_service.dart';
import 'package:ipchakra/services/vpnbook_service.dart';

void main() {
  test('VPNBook scrape: hosts + password nikalta hai', () {
    final svc = VpnBookService();
    final html = '''
<html><body>
<code>vpnbook</code>
<code>abc1234</code>
<code>bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4</code>
<a href="#">us16.vpnbook.com</a> <a href="#">de20.vpnbook.com</a>
<a href="#">www.vpnbook.com</a>
</body></html>''';
    final res = svc.debugScrape(html);
    expect(res.hosts, contains('us16.vpnbook.com'));
    expect(res.hosts, contains('de20.vpnbook.com'));
    expect(res.hosts, isNot(contains('www.vpnbook.com')));
    expect(res.password, 'abc1234');
  });

  test('VPNBook server objects bante hain', () {
    final svc = VpnBookService();
    final s = svc.debugToServer('de20.vpnbook.com');
    expect(s.country, 'Germany');
    expect(s.flag, '🇩🇪');
    expect(s.protocol, 'openvpn');
    expect(s.source, 'vpnbook');
    expect(s.configLoader, isNotNull);
    expect(s.authUsername, 'vpnbook');
    expect(s.authPassword, 'testpass');
  });

  test('V2Ray ss link parse hota hai', () {
    final svc = V2RayService();
    // ss://BASE64(method:pass)@host:port#remark(URL-encoded)
    final link =
        'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@185.156.47.97:9443#%F0%9F%87%A8%F0%9F%87%A6CA-185-0424';
    final s = svc.debugToServer(link);
    expect(s, isNotNull);
    expect(s!.protocol, 'v2ray');
    expect(s.country, 'Canada');
    expect(s.flag, '🇨🇦');
    expect(s.shareLink, link);
    expect(s.source, 'v2ray');
  });
}
