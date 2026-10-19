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
  <img src="https://img.shields.io/badge/release-v2.3.4%20AdShield%20Embedded-6C4CF1" alt="Release v2.3.4">
  <img src="https://img.shields.io/badge/platform-Android%20%7C%20Android%20TV%20%7C%20Windows-3DDC84" alt="Platforms">
  <img src="https://img.shields.io/badge/built%20with-Flutter-02569B" alt="Built with Flutter">
  <img src="https://img.shields.io/badge/price-Free%20forever-success" alt="Free forever">
</p>

---

A free VPN app for Android phones and Android TV, with a premium interface and three engines under one roof: WireGuard (Cloudflare WARP), OpenVPN, and Xray. IPChakra's speciality is its **Stealth mode** — modern censorship-resistant protocols (VLESS + Reality, Hysteria2, Trojan/TLS, Shadowsocks, VMess) with a connect system that only declares "Connected" after the tunnel has been *proven* to carry traffic with the DNS you chose.

**Current release: v2.3.4 "AdShield Embedded"**

Made with ❤️ by Shiv

---

## Modes

- **Free** — WireGuard tunnels: Cloudflare WARP (1.1.1.1) endpoints plus any custom WireGuard server from the database. One tap, first-tap connect, with a persistent notification and a working Disconnect action.
- **Stealth** — Xray-powered servers (VLESS Reality, Hysteria2, Trojan/TLS, Shadowsocks, VMess) for networks that block ordinary VPNs. Connect by picking a server, or use **Stealth Auto**, which walks a ranked ladder of servers and DNS combinations until one verifies end to end.
- **Chakra** — rotating residential IP mode. Visible in the app as a placeholder; it goes live in a later phase (it needs exit-node infrastructure that is not part of this repository yet).

## Why Stealth connects differently

Most VPN apps show "Connected" the moment the tunnel service starts — even if no traffic actually flows, which leaks your real IP the moment you start browsing. IPChakra never does that:

1. **Verified connect.** A connection is accepted only after a real DNS answer arrives *through the tunnel* from the combination's resolver **and** a hostname fetch returns the tunnel's exit IP (different from your real one).
2. **DNS escalation, server fixed.** On a manual connect the app tries, in order: your selected DNS → every other answering DNS provider in speed order → a last-resort default-DNS configuration — all against *your* chosen server. The server never changes behind your back; only the DNS escalates.
3. **Stability gate.** After verification, two further probes a few seconds apart must pass with the same exit IP before the UI is allowed to say **Connected**.
4. **Self-healing sessions.** While connected, a watchdog probes the tunnel every ~25 seconds. If the tunnel silently dies (the native layer has *not* reported a stop), the app shows **Reconnecting** — never a false "Connected" — and rebuilds the session on the same server. A stop *you* initiate (app button, notification, Android Settings or quick tile) always wins instantly and nothing ever reconnects on its own.
5. **Live attempt log.** Every step is narrated on the Home screen in plain English — which DNS is being tried, which failed, and the success line appears *before* the Connected state.
6. **DNS you can audit.** Pick from 27 DNS providers in Settings (Cloudflare, Quad9, Control D, AdGuard, NextDNS, CleanBrowsing and more). The Home status card always shows the DNS **actually in use** — including when a fallback provider carried the connection instead of your pick.

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
- Android-only: on other platforms the switch is disabled with a
  note, and behaviour is unchanged.

## Server database

The server lists live in this repository and update **without an app update**:

- [`servers.json`](servers.json) — Free/WARP and custom servers (currently version 2, generated 2026-10-10). The app re-checks it about once an hour and shows the database version and "Last checked" time in Settings.
- [`stealth.json`](stealth.json) — optional private Stealth server list, merged into the app's pool when present.
- Stealth additionally syncs from public subscription feeds (about 450 curated servers ship with the app: Reality, Hysteria2, TLS, Shadowsocks and VMess tiers) and can import share links you paste yourself.

## What's new — version history

| Version | Date | Highlights |
|---|---|---|
| **2.3.4** | 2026-10-11 | **AdShield Embedded.** The AdShield ad-blocker now lives inside the app: one tap on the animated Home-screen switch blocks ads and trackers at the VPN session's DNS — no second app, no second VPN profile. V2Ray sessions get the full ~254,000-domain list (StevenBlack + HaGeZi Multi PRO + uBlock + curated ad-network lists, streaming EXTREME pack on) injected into the core's DNS; WireGuard/OpenVPN sessions switch to an ad-blocking DNS provider. The card shows the list size honestly — there is no fake per-query counter — and an animated connect button sweep while connecting. |
| **2.3.3** | 2026-10-11 | **OpenVPN Mega-Database.** The OpenVPN list grows from ~290 to ≈5,128 entries — the VPNGate rolling pool (hourly bot pool of ~4,900 servers, fetched via a cheap change-index and parsed off the UI thread), a handshake-verified liveness overlay, and VPNBook in four protocol variants. Stealth country grouping restored (full ISO country detection; flags, codes, English and Chinese names). Switching modes no longer disconnects a live VPN — the engine hand-over happens only when you tap Connect in another mode. The WireGuard notification is now an ongoing foreground-service notification that cannot be swiped away while connected. |
| 2.3.2 | 2026-10-11 | **Layout fix.** Server names render on one line again (a unified hand-built server tile replaces the ListTile rows whose trailing buttons starved the name of width), with rendered-geometry regression tests. |
| 2.3.1 | 2026-10-11 | **Batch B.** Favourites, recents and fastest-by-country picks; subscription import by URL; config sharing with QR codes; IPv6 leak hardening across all three engines. |
| 2.3.0 | 2026-10-11 | **More Servers.** Five new Stealth feeds (NoMoreWalls, MatinGhanbari, Au1rxx, sNSub, Barry-Far) — 22,476 unique servers measured live, a pool of 600 with quality-first selection and per-source labels. |
| 2.2.0 | 2026-10-10 | **Stealth Resilience.** DNS escalation tiers with the server fixed, stability gate before "Connected", watchdog self-healing with a Reconnecting state, live English attempt log, Settings "Privacy & Leak Protection" note with a shortcut to Android's VPN settings. |
| 2.1.5 | 2026-10-10 | Home status card shows the DNS actually in use for the live session. |
| 2.1.4 | 2026-10-10 | Regression fix: engine stop "echoes" are now attributed to the stop that caused them, so Stealth Auto and WARP connect on the first tap again. |
| 2.1.3 | 2026-10-10 | App reconciles its state with the real tunnel state on start/resume (no more stale "Connected"); Free mode gained its persistent notification with Disconnect. |
| 2.1.2 | 2026-10-10 | `flutter_v2ray_client` vendored and patched — the Stealth notification's own Disconnect button now actually stops the tunnel. |
| 2.1.1 | 2026-10-10 | Disconnect always sticks (search sessions cancel instantly), engine events scoped per engine (WARP no longer poisoned by stale events), Hysteria2 list fixed via cache schema v3, database freshness (1 h checks + "Last checked"). |
| 2.1.0 | 2026-10-10 | **Hysteria2** support through the bundled Xray core; DNS-over-tunnel fix (the resolver you pick is exercised through the tunnel); best-combination connect with end-to-end verification. |
| 2.0.2 | 2026-10-10 | Tap a connected server to disconnect; bigger Stealth pool (~9,400 links measured, Reality tier populated); `stealth.json` private-list support. |
| 2.0.1 | 2026-10-10 | First-tap disconnect fix, server health + latency sorting, **27-provider DNS selection** with speed test. |
| 2.0.0 | 2026-10-10 | **Stealth mode launch** with full UI redesign (animated connect button, glass UI), VLESS/Trojan/VMess unlocked, Stealth Auto ladder, manual link import. |
| 1.x | 2026-10-02 | Free Mode: WARP/WireGuard + OpenVPN, remote server database, Android phone + TV. |

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
