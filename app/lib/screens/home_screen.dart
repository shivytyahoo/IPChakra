import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme.dart';
import '../models/vpn_server.dart';
import '../services/health_service.dart';
import '../services/server_database.dart';
import '../services/share_service.dart';
import '../services/v2ray_service.dart';
import '../services/vpn_controller.dart';
import '../widgets/animated_background.dart';
import '../widgets/connect_button.dart';

/// Home: mode switch, the hero connect button, a live status pill and a
/// glass info card (status, server, IP, protocol, session, traffic).
class HomeScreen extends StatefulWidget {
  final ServerDatabase db;
  final VpnController vpn;
  final V2RayService v2ray;
  final HealthService health;

  const HomeScreen({
    super.key,
    required this.db,
    required this.vpn,
    required this.v2ray,
    required this.health,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  Timer? _tick;
  late final AnimationController _dotPulse;
  VpnServer? _lastServer;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _dotPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _loadLastServer();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _dotPulse.dispose();
    super.dispose();
  }

  Future<void> _loadLastServer() async {
    final prefs = await SharedPreferences.getInstance();
    final lastId = prefs.getString('last_server');
    if (!mounted || lastId == null) return;
    setState(() => _lastServer = widget.db.byId(lastId));
  }

  // ── connect / disconnect ──────────────────────────────────────

  Future<void> _toggle() async {
    final vpn = widget.vpn;
    if (vpn.state == VpnState.connected ||
        vpn.state == VpnState.connecting ||
        vpn.state == VpnState.reconnecting) {
      // A tap while connecting (or while a session is being
      // restored) cancels the attempt — the user's disconnect
      // always wins over any connect or heal in flight.
      await vpn.disconnect();
      return;
    }
    if (vpn.state == VpnState.disconnecting) return;
    if (toggleShouldReset(vpn.state)) {
      // A tap in the error state is a reset to a clean disconnected
      // state, never the start of a new connection.
      await vpn.disconnect();
      return;
    }
    switch (vpn.mode) {
      case AppMode.chakra:
        _showSnack(
          'Chakra Mode is in trial — rotating residential IPs are '
          'coming soon. Use Free or Stealth Mode to connect.',
        );
        return;
      case AppMode.stealth:
        await _connectStealth();
        return;
      case AppMode.free:
        await _connectFree();
        return;
    }
  }

  Future<void> _connectFree() async {
    final prefs = await SharedPreferences.getInstance();
    final lastId = prefs.getString('last_server');
    VpnServer? server = lastId != null ? widget.db.byId(lastId) : null;
    server ??= widget.db.free.isNotEmpty ? widget.db.free.first : null;
    if (server == null) {
      _showSnack(
        'No free server was found. Refresh the list on the Servers tab.',
      );
      return;
    }
    await prefs.setString('last_server', server.id);
    if (mounted) setState(() => _lastServer = server);
    await widget.vpn.connect(server);
  }

  /// Stealth candidates in the shared order: working servers fastest
  /// first (measured latency), then unchecked servers in tier order,
  /// dead servers last.
  List<VpnServer> _stealthCandidates() =>
      sortByHealthAndLatency(widget.v2ray.servers, widget.health);

  Future<void> _connectStealth() async {
    if (widget.v2ray.servers.isEmpty) {
      await widget.v2ray.load();
    }
    final servers = widget.v2ray.servers;
    if (servers.isEmpty) {
      _showSnack(
        'No stealth servers are available yet. Open the Servers tab '
        'and refresh the Stealth list.',
      );
      return;
    }
    // Stealth Auto must choose from measured servers, not guesses: if
    // fewer than half the stealth servers have a health result yet,
    // probe a first batch now (bounded, so this stays snappy).
    final measured =
        servers.where((s) => widget.health.isWorking(s.id) != null).length;
    if (measured * 2 < servers.length) {
      await widget.health.checkMissing(servers.take(60).toList());
    }
    // Dead servers are excluded — unless every candidate is dead.
    final candidates = aliveOrAll(_stealthCandidates(), widget.health);
    await widget.vpn.connectStealthAuto(candidates);
    // If a fallback DNS won the search, say so honestly.
    final note = widget.vpn.dnsFallbackNote;
    if (note != null && widget.vpn.state == VpnState.connected) {
      _showSnack(note);
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _setMode(AppMode mode) {
    final vpn = widget.vpn;
    if (vpn.mode == mode) return;
    // Mode switching is pure navigation and must NEVER tear down
    // a live tunnel (v2.3.3 — S25 report: connecting in Stealth
    // and then tapping the Free tab disconnected the VPN). The
    // session state, the connected server and the running engine
    // are left completely untouched here. The engine handover
    // happens only when the user explicitly taps Connect in the
    // new mode: every connect path funnels through
    // VpnController._connectOnce, which stops the old engine
    // cleanly (its stop echoes are consumed as self-stops) before
    // starting the new one.
    vpn.setMode(mode);
    if (mode == AppMode.chakra) {
      _showSnack(
        'Chakra Mode is in trial — rotating residential IPs are '
        'coming soon. Use Free or Stealth Mode to connect.',
      );
    }
  }

  // ── formatting helpers ────────────────────────────────────────

  String _sessionTime() {
    final c = widget.vpn.connectedAt;
    if (c == null) return '—';
    final d = DateTime.now().difference(c);
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _formatSpeed(int bytesPerSecond) =>
      '${_formatBytes(bytesPerSecond)}/s';

  /// Traffic is only real on the V2Ray engine; other engines report
  /// nothing, so show a dash instead of inventing numbers.
  String _trafficValue({required bool download}) {
    final vpn = widget.vpn;
    if (vpn.server?.protocol != 'v2ray') return '—';
    final speed = download ? vpn.downSpeed : vpn.upSpeed;
    final total = download ? vpn.downTotal : vpn.upTotal;
    return '${_formatSpeed(speed)} • ${_formatBytes(total)} total';
  }

  /// What the DNS row of the status card shows. Only a connected
  /// session has a DNS in use at all, so every other state shows a
  /// dash, like the neighbouring rows. For Stealth the value is
  /// the provider of the verified (server, DNS) combination — the
  /// selected provider when it worked, the fallback provider when
  /// it did not — and for Free it is the selected provider, which
  /// is written into the tunnel configuration at connect time.
  /// OpenVPN servers push their own DNS and the app can neither
  /// override nor read it back, so the row says so honestly.
  String _dnsLabel() {
    final vpn = widget.vpn;
    if (vpn.state != VpnState.connected) return '—';
    final server = vpn.server;
    if (server == null) return '—';
    if (server.protocol == 'openvpn') return 'Server provided';
    final dns = vpn.effectiveDns;
    if (dns == null) return '—';
    return '${dns.name} · ${dns.primary}';
  }

  String _protocolLabel(VpnServer? s) {
    if (s == null) return '—';
    if (s.isStealth) {
      // Derived from the actually selected server's share link, so the
      // label always names the real scheme (VLESS, Trojan, VMess or
      // Shadowsocks) and, when known, its stealth tier.
      final scheme = _schemeLabel(s.shareLink);
      if (scheme == null) {
        return s.tier.isNotEmpty ? 'Stealth • ${s.tier}' : 'Stealth';
      }
      final tierSuffix = s.tier.isNotEmpty && s.tier != scheme
          ? ' • ${s.tier}'
          : '';
      return 'Stealth • $scheme$tierSuffix';
    }
    switch (s.protocol) {
      case 'openvpn':
        return 'OpenVPN';
      case 'v2ray':
        return 'V2Ray';
      case 'wireguard':
        return 'WireGuard';
      default:
        return '—';
    }
  }

  /// Human-readable scheme name for a stealth share link.
  String? _schemeLabel(String? link) {
    if (link == null) return null;
    if (link.startsWith('vless://')) return 'VLESS';
    if (link.startsWith('trojan://')) return 'Trojan';
    if (link.startsWith('vmess://')) return 'VMess';
    if (link.startsWith('ss://')) return 'Shadowsocks';
    if (link.startsWith('hysteria2://') || link.startsWith('hy2://')) {
      return 'Hysteria2';
    }
    return null;
  }

  VpnStateVisual _visualFor(VpnState s) {
    switch (s) {
      case VpnState.connected:
        return VpnStateVisual.connected;
      case VpnState.connecting:
      case VpnState.reconnecting:
        return VpnStateVisual.connecting;
      case VpnState.disconnecting:
        return VpnStateVisual.disconnecting;
      case VpnState.disconnected:
      case VpnState.error:
        return VpnStateVisual.disconnected;
    }
  }

  // ── build ─────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.vpn, widget.v2ray, widget.health]),
      builder: (context, _) {
        final vpn = widget.vpn;
        final connected = vpn.state == VpnState.connected;
        return AnimatedBackground(
          connected: connected,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _modeSwitch(),
                    const SizedBox(height: 30),
                    ConnectButton(state: _visualFor(vpn.state), onTap: _toggle),
                    const SizedBox(height: 22),
                    _statusPill(),
                    _attemptLogCard(),
                    const SizedBox(height: 18),
                    _infoCard(),
                    if (connected && vpn.server != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: TextButton.icon(
                          icon: const Icon(Icons.share, size: 16),
                          label: const Text('Share this server'),
                          onPressed: () =>
                              showServerShareSheet(context, vpn.server!),
                        ),
                      ),
                    const SizedBox(height: 14),
                    _quickCard(),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      transitionBuilder: (child, anim) => SizeTransition(
                        sizeFactor: anim,
                        child: FadeTransition(opacity: anim, child: child),
                      ),
                      child: vpn.lastError != null
                          ? Padding(
                              key: const ValueKey('error'),
                              padding: const EdgeInsets.only(top: 14),
                              child: _errorCard(vpn.lastError!),
                            )
                          : const SizedBox.shrink(key: ValueKey('no-error')),
                    ),
                    const SizedBox(height: 22),
                    const Center(
                      child: Text(
                        'Made with ❤️ by Shiv',
                        style: TextStyle(
                          color: ChakraTheme.textDim,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── mode segmented control ────────────────────────────────────

  Widget _modeSwitch() {
    final modes = AppMode.values; // free, stealth, chakra
    final activeIndex = modes.indexOf(widget.vpn.mode);
    const labels = ['Free', 'Stealth', 'Chakra'];
    const icons = [Icons.bolt, Icons.visibility_off, Icons.cached];
    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: ChakraTheme.glassFill,
        borderRadius: BorderRadius.circular(ChakraTheme.radiusMd),
        border: Border.all(color: ChakraTheme.glassBorder),
      ),
      padding: const EdgeInsets.all(4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segWidth = constraints.maxWidth / modes.length;
          return Stack(
            children: [
              // Sliding indicator behind the active segment.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                left: activeIndex * segWidth,
                top: 0,
                bottom: 0,
                width: segWidth,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: ChakraTheme.brandGradient,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: ChakraTheme.glowViolet,
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < modes.length; i++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _setMode(modes[i]),
                        child: Center(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                icons[i],
                                size: 15,
                                color: i == activeIndex
                                    ? Colors.white
                                    : ChakraTheme.textDim,
                              ),
                              const SizedBox(width: 5),
                              // Scale down instead of overflowing on
                              // narrow screens.
                              Flexible(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    labels[i],
                                    maxLines: 1,
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                      color: i == activeIndex
                                          ? Colors.white
                                          : ChakraTheme.textDim,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  // ── status pill ───────────────────────────────────────────────

  Widget _statusPill() {
    final vpn = widget.vpn;
    final active = vpn.state == VpnState.connected ||
        vpn.state == VpnState.connecting ||
        vpn.state == VpnState.reconnecting;
    final dotColor = vpn.state == VpnState.connected
        ? ChakraTheme.emerald
        : vpn.state == VpnState.connecting ||
              vpn.state == VpnState.reconnecting ||
              vpn.state == VpnState.disconnecting
        ? ChakraTheme.amber
        : Colors.white38;
    var text = vpn.stateLabel();
    // During a stealth combination search (or a self-heal), show
    // honestly what is being tried instead of a bare "Connecting…".
    if ((vpn.state == VpnState.connecting ||
            vpn.state == VpnState.reconnecting) &&
        vpn.statusNote != null) {
      text = vpn.statusNote!;
    }
    final server = vpn.server;
    if (vpn.state == VpnState.connected && server != null) {
      text = '$text • ${server.name}';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: ChakraTheme.glassFill,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: ChakraTheme.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _dotPulse,
            builder: (context, _) {
              final pulse = active ? _dotPulse.value : 0.0;
              return Container(
                width: 9 + 2 * pulse,
                height: 9 + 2 * pulse,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dotColor.withValues(
                    alpha: active ? 1 - 0.35 * pulse : 1,
                  ),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: dotColor.withValues(alpha: 0.55),
                            blurRadius: 8 + 6 * pulse,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
              );
            },
          ),
          const SizedBox(width: 9),
          Flexible(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Text(
                text,
                key: ValueKey(text),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: ChakraTheme.textMain,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── live attempt log ──────────────────────────────────────────

  /// The stealth attempt log: the last few lines of what the
  /// connect (or self-heal) is doing, narrated as it happens —
  /// which DNS is being tried, which one failed, and the line that
  /// confirms stability before the state flips to Connected. Kept
  /// for the whole session; empty (and therefore hidden) outside
  /// stealth activity.
  Widget _attemptLogCard() {
    final log = widget.vpn.attemptLog;
    if (log.isEmpty) return const SizedBox.shrink();
    final lines = log.length <= 5 ? log : log.sublist(log.length - 5);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: ChakraTheme.glassFill,
          borderRadius: BorderRadius.circular(ChakraTheme.radiusMd),
          border: Border.all(color: ChakraTheme.glassBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Text(
                  line,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── glass info card ───────────────────────────────────────────

  Widget _infoCard() {
    final vpn = widget.vpn;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: ChakraTheme.glassFill,
        borderRadius: BorderRadius.circular(ChakraTheme.radiusLg),
        border: Border.all(color: ChakraTheme.glassBorder),
      ),
      child: Column(
        children: [
          _row('Status', vpn.stateLabel()),
          const Divider(color: Colors.white10, height: 14),
          _row('Server', vpn.server?.name ?? 'Auto (fastest available)'),
          _row('IP address', vpn.exitIp ?? '—'),
          _row('Protocol', _protocolLabel(vpn.server)),
          _row('DNS', _dnsLabel()),
          _row('Session time', _sessionTime()),
          const Divider(color: Colors.white10, height: 14),
          _row('Download', _trafficValue(download: true)),
          _row('Upload', _trafficValue(download: false)),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Text(label, style: const TextStyle(color: ChakraTheme.textDim)),
          const SizedBox(width: 12),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, anim) =>
                  FadeTransition(opacity: anim, child: child),
              child: Text(
                value,
                key: ValueKey(value),
                textAlign: TextAlign.right,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: ChakraTheme.textMain,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── quick card (stealth / free / chakra) ──────────────────────

  Widget _quickCard() {
    final vpn = widget.vpn;
    final IconData icon;
    final String title;
    final String subtitle;
    switch (vpn.mode) {
      case AppMode.stealth:
        icon = Icons.visibility_off;
        title = 'Stealth Auto';
        final candidates = _stealthCandidates();
        subtitle = candidates.isEmpty
            ? 'Servers load automatically when you connect.'
            : 'Next up: ${candidates.first.name} • '
                  '${candidates.length} stealth servers ready';
        break;
      case AppMode.chakra:
        icon = Icons.lock_clock;
        title = 'Chakra Mode';
        subtitle = 'Rotating residential IPs are in trial and coming soon.';
        break;
      case AppMode.free:
        icon = Icons.history;
        title = 'Last server';
        final fallback = widget.db.free.isNotEmpty
            ? widget.db.free.first.name
            : 'Auto (fastest free)';
        subtitle = vpn.server?.name ?? _lastServer?.name ?? fallback;
        break;
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ChakraTheme.glassFill,
        borderRadius: BorderRadius.circular(ChakraTheme.radiusMd),
        border: Border.all(color: ChakraTheme.glassBorder),
      ),
      child: Row(
        children: [
          Icon(icon, color: ChakraTheme.cyan, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    subtitle,
                    key: ValueKey(subtitle),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: ChakraTheme.textDim,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── error card ────────────────────────────────────────────────

  Widget _errorCard(String err) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ChakraTheme.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(ChakraTheme.radiusMd),
        border: Border.all(color: ChakraTheme.red.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: ChakraTheme.red),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              err,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
