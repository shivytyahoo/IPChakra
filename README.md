<p align="center">
  <img src="assets/ipchakra-icon-512.png" alt="IPChakra logo" width="150">
</p>

<h1 align="center">IPChakra</h1>

<p align="center">
  <strong>Free VPN for Android &amp; Android TV — WARP · OpenVPN · Stealth Xray</strong><br>
  VLESS + Reality · Hysteria2 · Trojan · Shadowsocks — with verified connections,<br>
  smart DNS escalation, self-healing sessions and zero fake "Connected".
</p>

<p align="center">
  <img src="https://img.shields.io/badge/release-v1.0.0-6C4CF1" alt="Release v1.0.0">
  <img src="https://img.shields.io/badge/platform-Android%20%7C%20Android%20TV%20%7C%20Windows-3DDC84" alt="Platforms">
  <img src="https://img.shields.io/badge/built%20with-Flutter-02569B" alt="Built with Flutter">
  <img src="https://img.shields.io/badge/price-Free%20forever-success" alt="Free forever">
</p>

---

A free VPN app for Android phones and Android TV, with a premium interface and three engines under one roof: WireGuard (Cloudflare WARP), OpenVPN, and Xray. IPChakra's speciality is its **Stealth mode** — modern censorship-resistant protocols (VLESS + Reality, Hysteria2, Trojan/TLS, Shadowsocks, VMess) with a connect system that only declares "Connected" after the tunnel has been *proven* to carry traffic with the DNS you chose.

**Current release: v1.0.0**

Made with ❤️ by Shiv

---

## Modes

- **Free** — WireGuard tunnels: Cloudflare WARP (1.1.1.1) endpoints plus any custom WireGuard server from the database. Endpoints are ranked by a real measured round-trip time, so Fastest picks the lowest-latency *working* endpoint. One tap, first-tap connect, with a persistent notification and a working Disconnect action.
- **Stealth** — Xray-powered servers (VLESS Reality, Hysteria2, Trojan/TLS, Shadowsocks, VMess) for networks that block ordinary VPNs. Connect by picking a server, or use **Stealth Auto**, which walks a ranked ladder of servers and DNS combinations until one verifies end to end.
- **Chakra** — rotating residential IP mode. Visible in the app as a placeholder; it goes live in a later phase (it needs exit-node infrastructure that is not part of this repository yet).

## Why Stealth connects differently

Most VPN apps show "Connected" the moment the tunnel service starts — even if no traffic actually flows, which leaks your real IP the moment you start browsing. IPChakra never does that:

1. **Verified connect.** A connection is accepted only after a real DNS answer arrives *through the tunnel* from the combination's resolver **and** a hostname fetch returns the tunnel's exit IP (different from your real one).
2. **DNS escalation, server fixed.** On a manual connect the app tries, in order: your selected DNS → every other answering DNS provider in speed order → a last-resort default-DNS configuration — all against *your* chosen server. The server never changes behind your back; only the DNS escalates.
3. **Stability gate.** After verification, two further probes a few seconds apart must pass with the same exit IP before the UI is allowed to say **Connected**.
4. **Self-healing sessions.** While connected, a watchdog probes the tunnel every 30 seconds. Three consecutive silent probes declare the tunnel dead, the app shows **Reconnecting** — never a false "Connected" — and rebuilds the session on the same server. A stop *you* initiate (app button, notification, Android Settings or quick tile) always wins instantly and nothing ever reconnects on its own.
5. **Live attempt log.** Every step is narrated on the Home screen in plain English — which DNS is being tried, which failed, and the success line appears *before* the Connected state.
6. **DNS you can audit.** Pick from 27 DNS providers in Settings (Cloudflare, Quad9, Control D, AdGuard, NextDNS, CleanBrowsing and more). The Home status card always shows the DNS **actually in use** — including when a fallback provider carried the connection instead of your pick.
7. **Traffic-proven servers rank first.** A server that has actually carried traffic is recorded (24 h) and sorts above untested servers in both Working and Fastest, with a `working ✓` badge; a server that fails verification is marked dead immediately instead of lingering in the list as a fake "Connected".

## AdShield: ad-blocking inside the VPN

The Home screen carries an **AdShield** card with an animated on/off
switch. When the switch is on, the VPN session's DNS carries
ad-blocking — the ~254,000-domain blocklist of the standalone
AdShield v0.6.1 EXTREME (StevenBlack unified hosts, HaGeZi Multi
PRO, uBlock Origin conversions, curated mobile ad-network lists,
plus the streaming EXTREME pack covering SSAI middlemen like
Google DAI/IMA, FreeWheel, SpotX, Innovid, SpringServe, Yospace and
Amazon APS; suffix-deduped to 217,592 entries at build time — a
block on `doubleclick.net` already covers `ads.doubleclick.net`,
so children are dropped).

Why no local port-53 filter: **Android allows only one VpnService
at a time**, and IPChakra already owns it — and stock Android
forbids binding ports below 1024, so an in-app process cannot
answer DNS on port 53 at all. That is exactly why the standalone
AdShield is a full VpnService of its own. Instead the blocking
moves into the tunnel configurations:

| Engine | How ads are blocked |
|---|---|
| **V2Ray (Stealth)** | The bundled list is injected into the core's DNS as `dns.hosts` entries (`"domain:<d>": "0.0.0.0"`); a `dns`-protocol outbound (`dns-out`) is added and two routing rules steer lookups — port 53 goes to `dns-out` (blocked names resolve to `0.0.0.0`, the rest forwards to the attempt's upstream), while the core's own upstream queries ride the proxy tunnel instead of looping back. Applied on every attempt, including the Tier-3 default-DNS one. |
| **WireGuard (Free)** | The generated config's `DNS` line is switched to an ad-blocking provider (AdGuard DNS by default, or your pick if you already chose an ad-blocking provider in Settings) — the provider filters at DNS inside the tunnel. |
| **OpenVPN** | The config gains `pull-filter ignore "dhcp-option DNS"` (a server pushing its own DNS cannot bypass the override) plus `dhcp-option DNS` lines for the ad-blocking provider. |

There is deliberately **no live "N ads blocked" counter**: nothing
in this architecture can measure per-query blocks, and the UI never
shows a number it cannot prove. The card instead shows the bundled
list's size — the number of ad domains blocked at DNS for V2Ray
sessions.

Honest limits, by design:

- The switch applies to the **next** connection; flipping it
  mid-session changes nothing until you reconnect.
- Apps doing their own DNS-over-HTTPS/TLS bypass DNS filtering
  entirely — the same limit the standalone AdShield has.
- The injection never breaks a connect: a malformed config passes
  through unchanged, and with the switch off behaviour is byte-for-
  byte what it was before.
- If the ad-blocking DNS itself breaks a connect, the app retries
  once with AdShield treatment off for that session and says so on
  the Home screen — a failed connect is never silently blamed on
  the server.
- Android-only: on other platforms the switch is disabled with a
  note, and behaviour is unchanged.

## Server database

The server lists live in this repository and update **without an app update**:

- [`servers.json`](servers.json) — Free/WARP and custom servers (currently version 3). The app re-checks it about once an hour and shows the database version and "Last checked" time in Settings.
- [`stealth.json`](stealth.json) — optional private Stealth server list, merged into the app's pool when present.
- Stealth additionally syncs from public subscription feeds (a pool of 600: Reality, Hysteria2, TLS, Shadowsocks and VMess tiers) and can import share links you paste yourself. All lists auto-refresh whenever the app returns to the foreground (Stealth every 4 h, VPNGate/VPNBook every 6 h), so dead servers leave the list without an app update.

## What's new

| Version | Date | Highlights |
|---|---|---|
| **1.0.0** | 2026-11-14 | **Verified connect, honest lists:** a Stealth server that cannot carry real traffic never shows "Connected" — it is skipped and marked dead, while traffic-proven servers rank first with a `working ✓` badge. **Your DNS first:** every connect tries the DNS you picked in Settings before escalating. **AdShield fallback:** if the ad-blocking DNS itself breaks a connect, the app retries once with AdShield treatment off and says so. **No more stuck "Connecting…":** a late CONNECTING event can no longer knock a live session back. **In-app update check:** Settings → Check for update asks GitHub for the latest release, downloads its APK into the app cache and opens the system installer — no second app, no manual download. **Server lists:** Stealth feeds 0xRadikal top100/light and MahanKenway mix_sub, WARP endpoints incl. 188.114.99.1, servers.json v3, auto-refresh on every foreground return, real 5 MB download speed tests, R8 release shrinking, and anti-detect surrogates for the embedded AdShield (fail-safe stub DNS server). |

## Updating

Settings → **Check for update** asks GitHub for the latest
release and compares it with the running build. When a newer
release carries an APK, the app downloads it into its cache and
opens the system installer — Android asks once to allow
"Install unknown apps" for IPChakra, then the update installs
over the current one. A release with no APK offers its release
page instead, and a failed check says so rather than claiming
everything is up to date. The check is manual only; nothing
polls GitHub in the background.

## Building from source

Requirements: Flutter SDK, JDK 17, Android SDK.

```bash
bash tools/restore_binaries.sh   # restores the chunked binary assets (icons, jars, WireGuard Windows libraries)
cd app
flutter pub get
flutter build apk --release
```

Three plugins are **vendored** under [`packages/`](packages/) (see each package's `PATCHES.md` for the exact changes versus upstream): `wireguard_flutter` (Free-mode notification + Disconnect), `openvpn_flutter`, and `flutter_v2ray_client` (notification Disconnect wiring, reliable stop signalling, connection-state query).

**Native binaries not stored in git.** A few large prebuilt binaries are deliberately not committed. Restore them from the official upstream packages of the same versions before building:

- `packages/flutter_v2ray_client/android/libs/libv2ray.aar` and `packages/flutter_v2ray_client/android/src/main/jniLibs/*/libtun2socks.so` — from the `flutter_v2ray_client` **3.5.0** package.
- `packages/wireguard_flutter/windows/lib/tunnel/arm64/tunnel.dll` and `packages/wireguard_flutter/windows/lib/wireguard/arm64/wireguard.dll` — from the upstream `wireguard_flutter` package (the amd64 Windows binaries are restored by `tools/restore_binaries.sh`).

## Privacy notes

- IPChakra has no accounts, no analytics and no ads. Server lists are fetched from this repository and public feeds; your chosen DNS provider is the one your queries go to while connected (and the status card proves which one that is).
- The app does not itself block traffic when a tunnel drops. For OS-level leak protection, Android's **Always-on VPN → "Block connections without VPN"** option is the real kill switch — Settings inside the app links straight to it.

## Project layout

- `app/` — the Flutter application (Android phone/TV, Windows).
- `packages/` — vendored engine plugins with IPChakra's patches.
- `servers.json`, `stealth.json` — the live, remotely-updated server database.
- `tools/` — binary restore tooling.
- `trial/` — residential-proxy trial infrastructure scripts (for the future Chakra mode).

---

Made with ❤️ by Shiv
