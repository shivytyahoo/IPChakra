// Real share links sampled live from every public Stealth feed on
// 2026-10-11, with the country the app must derive from each
// link's remark. Generated for stealth_country_v233_test.dart;
// regenerate from the live feeds if they change shape.
//
// (source, link, expectedCountry, expectedFlag, why)
const stealthCountryFixtures = <(String, String, String, String, String)>[
  ("eternity", "ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTprMWRCT21PQjRvcWk3VW1wMzdhMWJR@193.29.139.147:8080#%F0%9F%87%B3%F0%9F%87%B1NL-193.29.139.147-5638", "Netherlands", "🇳🇱", "flag emoji remark"),
  ("submerge", "trojan://UX82473651@moral-basilisk.rooster465.autos:443?security=tls&sni=moral-basilisk.rooster465.autos#%F0%9F%87%B8%F0%9F%87%ACSG-54.151.181.75-0524", "Singapore", "🇸🇬", "flag emoji remark"),
  ("matin", "vmess://ewogICAgImFkZCI6ICI1LjQ1Ljk0LjI4IiwKICAgICJhaWQiOiAwLAogICAgImhvc3QiOiAiIiwKICAgICJpZCI6ICJiZDNkODFjNi05ZDQwLTRlNzUtOGEyMy03YzU1ZDY5YmY4MDEiLAogICAgIm5ldCI6ICJ3cyIsCiAgICAicGF0aCI6ICIvdm1lc3MiLAogICAgInBvcnQiOiA4MCwKICAgICJwcyI6ICLwn4ez8J+HsU5MLTUuNDUuOTQuMjgtNzMzNiIsCiAgICAidGxzIjogIiIsCiAgICAidHlwZSI6ICJhdXRvIiwKICAgICJzZWN1cml0eSI6ICJhdXRvIiwKICAgICJza2lwLWNlcnQtdmVyaWZ5IjogZmFsc2UsCiAgICAic25pIjogIjUuNDUuOTQuMjgiCn0=", "Netherlands", "🇳🇱", "flag + code remark"),
  ("matin", "vmess://ewogICAgImFkZCI6ICIxMjkuMTUwLjQ0LjY0IiwKICAgICJhaWQiOiAwLAogICAgImhvc3QiOiAiIiwKICAgICJpZCI6ICJkYTI1N2U3My1mMDJiLTQ1YWItOTkxNi03YmFmMTU0YzQ3YTMiLAogICAgIm5ldCI6ICJ3cyIsCiAgICAicGF0aCI6ICIvamhuZHNtbGFuajExMjIzIiwKICAgICJwb3J0IjogNDYwNzUsCiAgICAicHMiOiAi8J+HuPCfh6xTRy0xMjkuMTUwLjQ0LjY0LTMyMDgiLAogICAgInRscyI6ICIiLAogICAgInR5cGUiOiAiYXV0byIsCiAgICAic2VjdXJpdHkiOiAiYXV0byIsCiAgICAic2tpcC1jZXJ0LXZlcmlmeSI6IHRydWUsCiAgICAic25pIjogIiIKfQ==", "Singapore", "🇸🇬", "code before flag remark"),
  ("matin", "vless://3fce5b6d-27f7-6fa8-bbf0-f822bc6c79c6@api.nuxt.com:2083?security=tls&host=orangenet.varzeshfotsal.ir&insecure=0&type=xhttp&encryption=none&allowInsecure=0&path=%2F%3Fed%3D2056&sni=orangenet.varzeshfotsal.ir&pcs=1E487BB8C66822D4BCB4CB4744A7317208D9E6C2454853BC32C2E589A85F67D6&fp=chrome&vcn=dns.google&mode=packet-up&alpn=h3%2Ch2%2Chttp%2F1.1#⚡ b2n.ir/v2ray-configs | 438", "Unknown", "🌐", "channel-tag remark states no country"),
  ("nomorewalls", "vless://f55e9aba-7b14-4f6f-b59a-d5b3d45c9309@62.60.233.157:8444?#%F0%9F%87%B9%F0%9F%87%B7%5Bwww.v2nodes.com%5D%20vless-TR-1...", "Turkey", "🇹🇷", "flag emoji remark"),
  ("nomorewalls", "vless://5905d91f-c3bc-4e80-bd66-4b17beb166cb@38.244.4.1:443?allowInsecure=0&sni=www.apple.com&flow=xtls-rprx-vision-udp443&fp=chrome&security=tls#US_speednode_0130", "United States", "🇺🇸", "leading code token"),
  ("barryfar", "vless://d65cc14c-f53f-4fe2-b262-97856601319c@169.40.42.173:443?security=reality&encryption=none&pbk=e2RLf57Li_-MDZGE9ss1BWPgP54mqRb5PfXhW2jcVVg&headerType=none&fp=ios&type=tcp&flow=xtls-rprx-vision&sni=yahoo.com&sid=c39cc7310a#%F0%9F%87%A9%F0%9F%87%AAtelegram%E2%9E%A0%40v2rayNG_Matsuri", "Germany", "🇩🇪", "flag emoji at remark end"),
  ("snsub", "ss://YWVzLTI1Ni1nY206Rm9PaUdsa0FBOXlQRUdQ@15.204.246.132:7307#🇺🇸", "United States", "🇺🇸", "flag emoji remark"),
  ("pawdroid", "vless://a1de0630-5786-48a0-84f6-dc6f2de10d6d@213.111.177.107:443?encryption=none&security=tls&sni=vlso5.1d.mom&fp=chrome&type=ws&host=vlso5.1d.mom&path=%2Fsocks5%3D888%3A888%40hkip.1d.mom%3A1080#%E4%B9%8C%E5%85%8B%E5%85%B0+V2CROSS.COM", "Ukraine", "🇺🇦", "chinese country name"),
  ("pawdroid", "vless://6bceb548-d9b6-461f-8e37-a5a7fbcdc2c8@milo.rubinaz.xyz:8080?encryption=none&security=&type=tcp#%E7%BE%8E%E5%9B%BD+Host1Plus%E6%95%B0%E6%8D%AE%E4%B8%AD%E5%BF%83", "United States", "🇺🇸", "chinese country name"),
  ("epodonios", "vless://e75ad2eb-6c1f-45ce-8023-f5f10875df66@205.237.110.254:443?security=reality&encryption=none&pbk=IG6lxrx_xkGOoBuo3DC8sgQoIFmqVgznIr0qOuNO0w4&headerType=none&fp=firefox&type=tcp&flow=xtls-rprx-vision&sni=zsit.eu-cdn294.com&sid=cd2d53510b4df2a8#EPODONIOS", "Unknown", "🌐", "brand-only remark states no country"),
  ("au1rxx", "hy2://my_super_password_123@138.2.21.246:5443?insecure=1#hysteria2-1701029322", "Unknown", "🌐", "programmatic id remark states no country"),
];
