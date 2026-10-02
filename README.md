# 🌀 IPChakra

Free, fast VPN app — **Free Mode** me unlimited fast VPN (WARP + VPNGate),
**Chakra Mode** me rotating residential/mobile IP (trial phase me hai).

## Free servers — 5 source, sab auto-update

### 1. WARP (WireGuard)
Pehli baar connect karne pe app Cloudflare WARP ke public client API se ek
**free identity** register karti hai (signup/password nahi). Phir usi identity
se WireGuard tunnel banta hai. Poori tarah free, koi server kharcha nahi.

> Note: WARP ek anycast privacy network hai — teenon "WARP Free" entries usi
> network ke alag entry points hain, alag desh nahi.

### 2. VPNGate (OpenVPN) — 🌍 duniya bhar ke desh
**VPNGate** (University of Tsukuba, Japan) ka volunteer-run free network:
aam taur pe 50–150+ servers, 10–20 countries (Japan, Korea, US, Germany…).
Server list seedha `vpngate.net` se aati hai (12 ghante ka cache), isliye
hamesha taaza rehti hai — app update ki zaroorat nahi. Credentials public
hain: `vpn` / `vpn`.

### 3. VPNBook (OpenVPN)
**VPNBook** ke free servers (US, CA, UK, DE, FR, PL) — TCP 443 pe, firewall
se bhi nikal jaata hai. Username `vpnbook`, password site se auto-scrape
(weekly rotate hota hai), config live API se.

### 4. .ovpn Mirror (OpenVPN)
Community-maintained free configs (GitHub) — 18 countries, India/Indonesia/
Thailand/Turkey/UAE bhi. Bina login ke chalte hain.

### 5. V2Ray (Xray/Shadowsocks) — 🚀 sabse zyada servers
Roz update hone wali public link list (~150-200 servers, 30+ countries).
Xray core app me embedded hai.

Servers tab me **🌍 OpenVPN** tab (VPNGate + VPNBook + Mirror, country-wise)
aur **🚀 V2Ray** tab: country-wise group, search bhi hai.

> Note: Free servers volunteers/community ke hain — speed server ke hisaab se
> alag hoti hai. Kam ping + kam users wala server chuno.
> OpenVPN/V2Ray Android/Android TV pe hain; Windows pe abhi sirf WARP (WireGuard).

## Platforms

- ✅ Android phone (WireGuard + OpenVPN/VPNGate)
- ✅ Android TV (Leanback launcher support; wahi APK)
- ✅ Windows (GitHub Actions se build; **Administrator** ke roop me chalana hoga — WireGuard ki requirement hai; VPNGate Windows pe abhi nahi)

## Server database (bina app update ke)

`servers.json` (repo root me) GitHub se load hoti hai:

1. **remote** — `raw.githubusercontent.com/shivytyahoo/IPChakra/main/servers.json` (12 ghante ka cache)
2. **cache** — phone me saved copy
3. **bundled** — app ke andar wali copy (`app/assets/servers.json`)

Matlab: `servers.json` me naye server add karte hi sab users ke app me aa
jayenge — Play Store update ki zaroorat nahi. Settings → Server Database →
Refresh se turant refresh bhi ho sakta hai.

`servers.json` ka format:

```json
{
  "version": 2,
  "updated": "2026-10-03",
  "free": [
    {
      "id": "warp-1",
      "name": "WARP Free 1",
      "flag": "🌐",
      "type": "free",
      "protocol": "wireguard",
      "warp": true,
      "endpoint": "162.159.192.1:2408",
      "note": "Cloudflare WARP free network",
      "enabled": true
    }
  ],
  "chakra": [],
  "custom": []
}
```

- `warp: true` → app khud free WARP identity se connect karegi.
- `type: "custom"` + `peer_public_key` + `endpoint` → apne WireGuard VPS ka server.
- `type: "chakra"` → Chakra Mode (residential rotation) — abhi UI only.

## Build

```bash
cd app
flutter pub get
flutter analyze
flutter build apk --debug     # Android (phone + TV)
flutter build windows --release  # Windows (Windows host chahiye)
```

Android TV: manifest me `LEANBACK_LAUNCHER` + banner pehle se hai —
wahi APK TV pe bhi install hoga.

## Project structure

```
app/
  lib/
    main.dart                 # app entry, 3 tabs
    core/theme.dart           # dark premium theme
    core/net.dart             # ping / exit-IP helpers
    models/vpn_server.dart    # server record
    services/server_database.dart  # remote → cache → bundled
    services/warp_service.dart     # free WARP identity
    services/vpn_controller.dart   # connect/disconnect brain
    screens/home_screen.dart       # Chakra dial + mode switch
    screens/servers_screen.dart    # Free / Chakra server lists
    screens/settings_screen.dart   # database, engine, about
  assets/servers.json         # bundled fallback list
servers.json                  # remote database (repo root)
.github/workflows/build.yml   # Android + Windows CI builds
```

Made by Shiv 🌀
