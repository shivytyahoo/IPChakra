import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/theme.dart';
import '../models/vpn_server.dart';
import '../services/health_service.dart';
import '../services/ovpn_mirror_service.dart';
import '../services/server_database.dart';
import '../services/v2ray_service.dart';
import '../services/vpnbook_service.dart';
import '../services/vpn_controller.dart';
import '../services/vpngate_service.dart';

/// Server list: Free (WARP) | OpenVPN (VPNGate+VPNBook+Mirror) | V2Ray | Chakra.
class ServersScreen extends StatefulWidget {
  final ServerDatabase db;
  final VpnController vpn;
  final VpnGateService vpngate;
  final VpnBookService vpnbook;
  final OvpnMirrorService mirror;
  final V2RayService v2ray;
  final HealthService health;
  final VoidCallback onGoHome;

  const ServersScreen(
      {super.key,
      required this.db,
      required this.vpn,
      required this.vpngate,
      required this.vpnbook,
      required this.mirror,
      required this.v2ray,
      required this.health,
      required this.onGoHome});

  @override
  State<ServersScreen> createState() => ServersScreenState();
}

class ServersScreenState extends State<ServersScreen> {
  String _query = '';
  bool _autoChecked = false;

  @override
  void initState() {
    super.initState();
    if (widget.vpngate.servers.isEmpty) widget.vpngate.load();
    if (widget.vpnbook.servers.isEmpty) widget.vpnbook.load();
    if (widget.mirror.servers.isEmpty) widget.mirror.load();
    if (widget.v2ray.servers.isEmpty) widget.v2ray.load();
    // App khulne pe saare servers ka health check (background me).
    _autoHealthCheck();
  }

  /// Saare sources ke servers ek list me.
  List<VpnServer> _allServers() => [
        ...widget.db.free,
        ...widget.vpngate.servers,
        ...widget.vpnbook.servers,
        ...widget.mirror.servers,
        ...widget.v2ray.servers,
      ];

  Future<void> _autoHealthCheck() async {
    // Pehle server lists aane do (max ~30s), phir health check.
    for (var i = 0; i < 30; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      if (_allServers().isNotEmpty) break;
    }
    if (!mounted || _autoChecked) return;
    _autoChecked = true;
    await widget.health.checkAll(_allServers());
  }

  /// Refresh button (AppBar) se: lists + health check dobara.
  Future<void> refreshAll() async {
    widget.health.reset();
    await Future.wait([
      widget.db.load(forceRefresh: true),
      widget.vpngate.load(forceRefresh: true),
      widget.vpnbook.load(forceRefresh: true),
      widget.mirror.load(forceRefresh: true),
      widget.v2ray.load(forceRefresh: true),
    ]);
    _autoChecked = true;
    await widget.health.checkAll(_allServers());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                '✓ ${widget.health.workingCount} working • '
                '✗ ${widget.health.deadCount} dead')),
      );
    }
  }

  /// Saare OpenVPN sources ka combined list.
  List<VpnServer> get _openvpnServers => [
        ...widget.vpngate.servers,
        ...widget.vpnbook.servers,
        ...widget.mirror.servers,
      ];

  @override
  Widget build(BuildContext context) {
    final isDesktop = Platform.isWindows;
    final tabs = [
      const Tab(text: '⚡ Free'),
      // Windows pe sirf WireGuard/WARP chalta hai — OpenVPN/V2Ray ke plugins
      // me Windows support nahi hai.
      if (!isDesktop) const Tab(text: '🌍 OpenVPN'),
      if (!isDesktop) const Tab(text: '🚀 V2Ray'),
      const Tab(text: '🌀 Chakra'),
    ];
    return ListenableBuilder(
      listenable: widget.db,
      builder: (context, _) {
        return DefaultTabController(
          length: tabs.length,
          child: Column(
            children: [
              TabBar(
                indicatorColor: ChakraTheme.cyan,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white54,
                isScrollable: true,
                tabAlignment: TabAlignment.center,
                tabs: tabs,
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    RefreshIndicator(
                      onRefresh: _refreshFree,
                      child: _freeList(),
                    ),
                    RefreshIndicator(
                      onRefresh: _refreshOpenvpn,
                      child: _openvpnList(),
                    ),
                    if (!isDesktop)
                      RefreshIndicator(
                        onRefresh: _refreshV2ray,
                        child: _v2rayList(),
                      ),
                    _chakraList(),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _refreshFree() async {
    await widget.db.load(forceRefresh: true);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('${widget.db.free.length} free server load ho gaye.')),
      );
    }
  }

  Future<void> _refreshOpenvpn() async {
    await Future.wait([
      widget.vpngate.load(forceRefresh: true),
      widget.vpnbook.load(forceRefresh: true),
      widget.mirror.load(forceRefresh: true),
    ]);
  }

  Future<void> _refreshV2ray() async {
    await widget.v2ray.load(forceRefresh: true);
  }

  // ── ⚡ Free (WARP) ──────────────────────────────────────────────
  Widget _freeList() {
    final servers = widget.db.free;
    if (servers.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 80),
          Center(
              child: Text(
                  'Koi free server nahi mila.\nNeeche kheench ke refresh karo.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54))),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: servers.length,
      itemBuilder: (context, i) => _warpCard(servers[i]),
    );
  }

  Widget _warpCard(VpnServer s) {
    return ListenableBuilder(
      listenable: widget.vpn,
      builder: (context, _) {
        final isCurrent = widget.vpn.server?.id == s.id &&
            widget.vpn.state == VpnState.connected;
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 6),
          color: ChakraTheme.card,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(
                color: isCurrent
                    ? ChakraTheme.green
                    : Colors.white.withValues(alpha: 0.08)),
          ),
          child: ListTile(
            leading: Text(s.flag, style: const TextStyle(fontSize: 30)),
            title: Row(
              children: [
                Expanded(
                  child: Text(s.name,
                      style:
                          const TextStyle(fontWeight: FontWeight.bold)),
                ),
                _healthBadge(s),
              ],
            ),
            subtitle: const Text('WARP Free • WireGuard',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            trailing: isCurrent
                ? const Chip(
                    label: Text('Connected'),
                    backgroundColor: ChakraTheme.green)
                : ElevatedButton(
                    onPressed: () => _connectTo(s),
                    child: const Text('Connect'),
                  ),
          ),
        );
      },
    );
  }

  // ── 🌍 OpenVPN (combined) ───────────────────────────────────────
  Widget _openvpnList() {
    return ListenableBuilder(
      listenable: widget.vpngate,
      builder: (context, _) => ListenableBuilder(
        listenable: widget.vpnbook,
        builder: (context, _) => ListenableBuilder(
          listenable: widget.mirror,
          builder: (context, _) => _openvpnBody(),
        ),
      ),
    );
  }

  Widget _openvpnBody() {
    final all = _openvpnServers;
    final anyLoading = widget.vpngate.loading ||
        widget.vpnbook.loading ||
        widget.mirror.loading;
    if (all.isEmpty && anyLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (all.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 60),
          Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Koi OpenVPN server nahi mila.\nNeeche kheench ke refresh karo.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ),
        ],
      );
    }
    // country-wise group
    final groups = <String, List<VpnServer>>{};
    for (final s in all) {
      groups.putIfAbsent(s.country, () => []).add(s);
    }
    final q = _query.trim().toLowerCase();
    final names = groups.keys.toList()..sort();
    final filtered = q.isEmpty
        ? names
        : names.where((c) => c.toLowerCase().contains(q)).toList();
    // har group me ping wale pehle
    for (final list in groups.values) {
      list.sort(
          (a, b) => (a.pingMs ?? 9999).compareTo(b.pingMs ?? 9999));
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _searchBox('Country search karo… (jaise India, Japan)'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(
            '${all.length} servers • ${groups.length} countries • VPNGate + VPNBook + Mirror',
            style:
                const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ),
        _healthSummary(),
        for (final c in filtered) _countryGroup(c, groups[c]!),
      ],
    );
  }

  // ── 🚀 V2Ray ────────────────────────────────────────────────────
  Widget _v2rayList() {
    return ListenableBuilder(
      listenable: widget.v2ray,
      builder: (context, _) {
        final v = widget.v2ray;
        if (v.loading && v.servers.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (v.servers.isEmpty) {
          return ListView(
            children: [
              const SizedBox(height: 60),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    v.error ??
                        'V2Ray list load nahi hui.\nNeeche kheench ke dobara try karo.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54),
                  ),
                ),
              ),
            ],
          );
        }
        final groups = <String, List<VpnServer>>{};
        for (final s in v.servers) {
          groups.putIfAbsent(s.country, () => []).add(s);
        }
        final q = _query.trim().toLowerCase();
        final names = groups.keys.toList()..sort();
        final filtered = q.isEmpty
            ? names
            : names.where((c) => c.toLowerCase().contains(q)).toList();
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _searchBox('Country search karo…'),
            Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Text(
                '${v.servers.length} servers • ${groups.length} countries • Xray (Shadowsocks)',
                style: const TextStyle(
                    color: Colors.white38, fontSize: 11),
              ),
            ),
            _healthSummary(),
            for (final c in filtered) _countryGroup(c, groups[c]!),
          ],
        );
      },
    );
  }

  // ── shared widgets ──────────────────────────────────────────────

  /// Server health badge: 🟢 working / 🔴 dead / ⚪ checking.
  Widget _healthBadge(VpnServer s) {
    return ListenableBuilder(
      listenable: widget.health,
      builder: (context, _) {
        final w = widget.health.isWorking(s.id);
        final checking = widget.health.isChecking(s.id);
        final Color c;
        final String label;
        if (checking || (w == null && widget.health.checking)) {
          c = Colors.grey;
          label = 'checking';
        } else if (w == null) {
          c = Colors.white24;
          label = 'unchecked';
        } else if (w) {
          c = Colors.greenAccent;
          label = 'working';
        } else {
          c = Colors.redAccent;
          label = 'dead';
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: c, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: c,
                    fontSize: 10,
                    fontWeight: FontWeight.w600)),
          ],
        );
      },
    );
  }

  /// Upar summary patti: kitne working / dead.
  Widget _healthSummary() {
    return ListenableBuilder(
      listenable: widget.health,
      builder: (context, _) {
        final h = widget.health;
        if (!h.checking && h.lastChecked == null) {
          return const SizedBox.shrink();
        }
        final text = h.checking
            ? 'Health check chal raha hai… ✓${h.workingCount} ✗${h.deadCount}'
            : '✓ ${h.workingCount} working • ✗ ${h.deadCount} dead';
        return Padding(
          padding:
              const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(
            text,
            style: const TextStyle(
                color: Colors.white38, fontSize: 11),
          ),
        );
      },
    );
  }
  Widget _searchBox(String hint) {
    return TextField(
      decoration: InputDecoration(
        hintText: hint,
        hintStyle:
            const TextStyle(color: Colors.white38, fontSize: 13),
        prefixIcon: const Icon(Icons.search, color: Colors.white38),
        filled: true,
        fillColor: ChakraTheme.card,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
      style: const TextStyle(color: Colors.white),
      onChanged: (v) => setState(() => _query = v),
    );
  }

  static const _sourceLabel = {
    'vpngate': 'VPNGate',
    'vpnbook': 'VPNBook',
    'mirror': 'Mirror',
    'v2ray': 'V2Ray',
  };

  Widget _countryGroup(String country, List<VpnServer> servers) {
    final s = servers.first;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: ChakraTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: ExpansionTile(
        leading: Text(s.flag, style: const TextStyle(fontSize: 30)),
        title: Text(country,
            style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text('${servers.length} servers',
            style:
                const TextStyle(color: Colors.white54, fontSize: 12)),
        children: [for (final srv in servers) _serverRow(srv)],
      ),
    );
  }

  Widget _serverRow(VpnServer s) {
    return ListenableBuilder(
      listenable: widget.vpn,
      builder: (context, _) {
        final isCurrent = widget.vpn.server?.id == s.id &&
            widget.vpn.state == VpnState.connected;
        final src = _sourceLabel[s.source] ?? s.source;
        return ListTile(
          dense: true,
          title: Row(
            children: [
              Expanded(
                  child: Text(s.name,
                      style: const TextStyle(fontSize: 13))),
              _healthBadge(s),
            ],
          ),
          subtitle: Text('${s.note}\n$src',
              style: const TextStyle(
                  color: Colors.white54, fontSize: 11)),
          isThreeLine: true,
          trailing: isCurrent
              ? const Chip(
                  label:
                      Text('Connected', style: TextStyle(fontSize: 11)),
                  backgroundColor: ChakraTheme.green)
              : ElevatedButton(
                  onPressed: () => _connectTo(s),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(70, 32),
                    padding: EdgeInsets.zero,
                  ),
                  child: const Text('Connect',
                      style: TextStyle(fontSize: 12)),
                ),
        );
      },
    );
  }

  // ── 🌀 Chakra ───────────────────────────────────────────────────
  Widget _chakraList() {
    final servers = widget.db.chakra;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: ChakraTheme.violet.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: ChakraTheme.violet.withValues(alpha: 0.35)),
          ),
          child: const Row(
            children: [
              Icon(Icons.lock_clock, color: ChakraTheme.violet),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Chakra Mode trial phase me hai — residential IP '
                  'har kuch minute me rotate hoga. Jald aa raha hai!',
                  style:
                      TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        if (servers.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
                child: Text(
                    'Server database me abhi Chakra server nahi hain.',
                    style: TextStyle(color: Colors.white54))),
          )
        else
          for (final s in servers) _warpCard(s),
      ],
    );
  }

  Future<void> _connectTo(VpnServer s) async {
    if (s.protocol == 'wireguard' && s.warp) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_server', s.id);
      widget.vpn.setMode(AppMode.free);
    }
    await widget.vpn.connect(s);
    widget.onGoHome();
  }
}
