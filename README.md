# 🌀 IPChakra

A free, fast VPN app for Android, Android TV and Windows.

**Free Mode** gives you an unlimited free VPN (WARP, VPNGate, VPNBook,
community OpenVPN configs and V2Ray). **Chakra Mode** — rotating
residential/mobile IPs — is in trial phase and currently UI only.

## Free servers — 5 sources, all auto-updating

### 1. WARP (WireGuard)
On first connect the app registers a **free identity** with Cloudflare WARP's
public client API (no signup, no password) and builds a WireGuard tunnel on
it. Completely free, zero server cost on our side.

> Note: WARP is an anycast privacy network — the three "WARP Free" entries
> are different entry points to the same network, not different countries.

### 2. VPNGate (OpenVPN) — 🌍 servers worldwide
**VPNGate** (University of Tsukuba, Japan) is a volunteer-run free network:
usually 50–150+ servers across 10–20 countries (Japan, Korea, US, Germany…).
The server list is fetched straight from `vpngate.net` (12-hour cache), so it
stays fresh without app updates. Credentials are public: `vpn` / `vpn`.

### 3. VPNBook (OpenVPN)
**VPNBook**'s free servers (US, CA, UK, DE, FR, PL) over TCP 443, which gets
through most firewalls. Username `vpnbook`, password auto-scraped from their
site (rotates weekly), config from the live API.

### 4. .ovpn Mirror (OpenVPN)
Community-maintained free configs (GitHub) — 18 countries including
India, Indonesia, Thailand, Turkey and the UAE. No login needed.

### 5. V2Ray (Xray/Shadowsocks) — 🚀 the biggest pool
A daily-updated public link list (~150–200 servers, 30+ countries).
Xray core is embedded in the app.

The Servers tab has a **🌍 OpenVPN** tab (VPNGate + VPNBook + Mirror, grouped
by country) and a **🚀 V2Ray** tab (grouped by country, with search).

> Note: free servers are run by volunteers and the community — speed varies
> by server, so pick one with low ping and few users.
> OpenVPN and V2Ray are on Android/Android TV; on Windows only WARP
> (WireGuard) works for now.

## Platforms

- ✅ Android phone (WireGuard + OpenVPN/VPNGate + V2Ray)
- ✅ Android TV (Leanback launcher support — the same APK installs on TV)
- ✅ Windows (built via GitHub Actions; **must be run as Administrator** —
  a WireGuard requirement; VPNGate isn't on Windows yet)

## Server database (no app updates needed)

The server list (`servers.json` in the repo root) is loaded from GitHub:

1. **remote** — `raw.githubusercontent.com/shivytyahoo/IPChakra/main/servers.json` (12-hour cache)
2. **cache** — the copy saved on the phone
3. **bundled** — the copy shipped inside the app (`app/assets/servers.json`)

So the moment a new server is added to `servers.json`, it shows up in every
user's app — no Play Store update required. You can also force an immediate
refresh from Settings → Server Database → Refresh.

`servers.json` format:

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

- `warp: true` → the app connects with its own free WARP identity.
- `type: "custom"` with `peer_public_key` + `endpoint` → your own WireGuard VPS.
- `type: "chakra"` → Chakra Mode (residential rotation) — UI only for now.

## Build

```bash
cd app
flutter pub get
flutter analyze
flutter build apk --debug        # Android (phone + TV)
flutter build windows --release  # Windows (needs a Windows host)
```

Android TV: the manifest already has `LEANBACK_LAUNCHER` + a banner, so the
same APK installs on TV.

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
