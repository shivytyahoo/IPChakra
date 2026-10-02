import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/theme.dart';
import '../models/vpn_server.dart';
import '../services/server_database.dart';
import '../services/vpn_controller.dart';

/// Home: big Chakra dial + mode switch + status card.
class HomeScreen extends StatefulWidget {
  final ServerDatabase db;
  final VpnController vpn;

  const HomeScreen({super.key, required this.db, required this.vpn});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _toggle() async {
    final vpn = widget.vpn;
    if (vpn.state == VpnState.connected ||
        vpn.state == VpnState.connecting) {
      // connecting ke dauraan tap = cancel (hang se bachne ke liye)
      await vpn.disconnect();
      return;
    }
    if (vpn.state == VpnState.disconnecting) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final lastId = prefs.getString('last_server');
    VpnServer? server = lastId != null ? widget.db.byId(lastId) : null;
    server ??= widget.db.free.isNotEmpty ? widget.db.free.first : null;
    if (server == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Koi free server nahi mila. Servers tab me refresh karo.')),
      );
      return;
    }
    await prefs.setString('last_server', server.id);
    await vpn.connect(server);
  }

  String _sessionTime() {
    final c = widget.vpn.connectedAt;
    if (c == null) return '—';
    final d = DateTime.now().difference(c);
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.vpn,
      builder: (context, _) {
        final vpn = widget.vpn;
        final connected = vpn.state == VpnState.connected;
        final busy = vpn.state == VpnState.connecting ||
            vpn.state == VpnState.disconnecting;
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _modeSwitch(),
                const SizedBox(height: 28),
                _chakraDial(connected, busy, vpn),
                const SizedBox(height: 24),
                if (vpn.lastError != null) _errorCard(vpn.lastError!),
                _statusCard(connected, busy),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _modeSwitch() {
    return ListenableBuilder(
      listenable: widget.vpn,
      builder: (context, _) {
        final free = widget.vpn.mode == AppMode.free;
        return Container(
          decoration: BoxDecoration(
            color: ChakraTheme.card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white10),
          ),
          padding: const EdgeInsets.all(4),
          child: Row(
            children: [
              Expanded(
                  child: _modeChip('⚡ Free Mode', free, () => _setMode(true))),
              Expanded(
                  child: _modeChip('🌀 Chakra Mode', !free, () => _setMode(false))),
            ],
          ),
        );
      },
    );
  }

  Widget _modeChip(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          gradient: active ? ChakraTheme.brandGradient : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: active ? Colors.white : Colors.white60)),
        ),
      ),
    );
  }

  Future<void> _setMode(bool free) async {
    final vpn = widget.vpn;
    if (vpn.state == VpnState.connected) {
      await vpn.disconnect();
    }
    vpn.setMode(free ? AppMode.free : AppMode.chakra);
    if (!free && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Chakra Mode abhi trial me hai — Free Mode se connect karo.')),
      );
    }
  }

  Widget _chakraDial(bool connected, bool busy, VpnController vpn) {
    return GestureDetector(
      onTap: _toggle,
      child: SizedBox(
        width: 240,
        height: 240,
        child: Stack(
          alignment: Alignment.center,
          children: [
            CustomPaint(
              size: const Size(240, 240),
              painter: _ChakraPainter(
                  connected: connected, busy: busy, now: DateTime.now()),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  connected
                      ? Icons.shield_outlined
                      : busy
                          ? Icons.hourglass_top
                          : Icons.power_settings_new,
                  size: 44,
                  color: connected
                      ? ChakraTheme.green
                      : busy
                          ? ChakraTheme.amber
                          : Colors.white54,
                ),
                const SizedBox(height: 6),
                Text(
                  connected
                      ? 'Connected'
                      : busy
                          ? (vpn.state == VpnState.connecting
                              ? 'Connecting…\n(tap to cancel)'
                              : 'Disconnecting…')
                          : 'Tap to Connect',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorCard(String err) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ChakraTheme.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ChakraTheme.red.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: ChakraTheme.red),
          const SizedBox(width: 8),
          Expanded(
              child: Text(err,
                  style: const TextStyle(color: Colors.white70, fontSize: 13))),
        ],
      ),
    );
  }

  Widget _statusCard(bool connected, bool busy) {
    final vpn = widget.vpn;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ChakraTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          _row('Status',
              connected ? '● Connected' : busy ? '◌ Working…' : '○ Offline'),
          const Divider(color: Colors.white10),
          _row('Server', vpn.server?.name ?? 'Auto (fastest free)'),
          _row('IP', vpn.exitIp ?? '—'),
          _row('Protocol', _protocolLabel(vpn.server)),
          _row('Session', _sessionTime()),
        ],
      ),
    );
  }

  String _protocolLabel(VpnServer? s) {
    switch (s?.protocol) {
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

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// The rotating Chakra ring.
class _ChakraPainter extends CustomPainter {
  final bool connected;
  final bool busy;
  final DateTime now;

  _ChakraPainter(
      {required this.connected, required this.busy, required this.now});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    const spokes = 12;
    final rotation = now.millisecondsSinceEpoch / 1000.0 * (busy ? 2.0 : 0.25);

    for (int i = 0; i < spokes; i++) {
      final a = rotation + i * 2 * pi / spokes;
      final outer = Offset(c.dx + r * cos(a), c.dy + r * sin(a));
      final inner = Offset(
          c.dx + (r - 26) * cos(a), c.dy + (r - 26) * sin(a));
      final paint = Paint()
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round
        ..color = (connected
                ? Color.lerp(ChakraTheme.violet, ChakraTheme.cyan, i / spokes)!
                : Colors.white.withValues(alpha: 0.14 + 0.1 * (i % 2)))
            .withValues(alpha: connected || busy ? 1.0 : 0.55);
      canvas.drawLine(inner, outer, paint);
    }

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = connected
          ? ChakraTheme.green.withValues(alpha: 0.7)
          : Colors.white24;
    canvas.drawCircle(c, r - 6, ring);
    canvas.drawCircle(c, r - 32, ring);
  }

  @override
  bool shouldRepaint(covariant _ChakraPainter old) =>
      old.connected != connected ||
      old.busy != busy ||
      old.now != now;
}
