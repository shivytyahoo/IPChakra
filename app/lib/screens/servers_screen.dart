import 'dart:async';
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

/// Server list: Free (WARP) | OpenVPN (VPNGate + VPNBook + Mirror) |
/// Stealth (Xray) | Chakra.
class ServersScreen extends StatefulWidget {
  final ServerDatabase db;
  final VpnController vpn;
  final VpnGateService vpngate;
  final VpnBookService vpnbook;
  final OvpnMirrorService mirror;
  final V2RayService v2ray;
  final HealthService health;
  final VoidCallback onGoHome;

  const ServersScreen({
    super.key,
    required this.db,
    required this.vpn,
    required this.vpngate,
    required this.vpnbook,
    required this.mirror,
    required this.v2ray,
    required this.health,
    required this.onGoHome,
  });

  @override
  State<ServersScreen> createState() => ServersScreenState();
}

class ServersScreenState extends State<ServersScreen> {
  String _query = '';

  /// Active Stealth tier filter: 'All', 'Reality', 'Hysteria2',
  /// 'TLS', 'Shadowsocks', 'Custom' or 'Private'.
  String _stealthFilter = 'All';

  Timer? _healthDebounce;

  @override
  void initState() {
    super.initState();
    if (widget.vpngate.servers.isEmpty) widget.vpngate.load();
    if (widget.vpnbook.servers.isEmpty) widget.vpnbook.load();
    if (widget.mirror.servers.isEmpty) widget.mirror.load();
    if (widget.v2ray.servers.isEmpty) widget.v2ray.load();
    // Health-check servers incrementally as the source lists arrive.
    // The old one-shot check raced the feeds: the WARP list lands
    // almost instantly, so the check ran on that snapshot and the
    // stealth servers that arrived later stayed "unchecked" forever.
    // Listening to every source and checking only the servers that
    // have no result yet removes the race entirely.
    widget.db.addListener(_onSourcesChanged);
    widget.vpngate.addListener(_onSourcesChanged);
    widget.vpnbook.addListener(_onSourcesChanged);
    widget.mirror.addListener(_onSourcesChanged);
    widget.v2ray.addListener(_onSourcesChanged);
    _scheduleMissingCheck();
  }

  @override
  void dispose() {
    _healthDebounce?.cancel();
    widget.db.removeListener(_onSourcesChanged);
    widget.vpngate.removeListener(_onSourcesChanged);
    widget.vpnbook.removeListener(_onSourcesChanged);
    widget.mirror.removeListener(_onSourcesChanged);
    widget.v2ray.removeListener(_onSourcesChanged);
    super.dispose();
  }

  void _onSourcesChanged() => _scheduleMissingCheck();

  /// Debounced trigger for the incremental health check: source lists
  /// notify several times while loading, so wait for a quiet moment,
  /// then probe whatever is still unchecked.
  void _scheduleMissingCheck() {
    _healthDebounce?.cancel();
    _healthDebounce = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      unawaited(widget.health.checkMissing(_allServers()));
    });
  }

  /// Servers from every source in one list.
  List<VpnServer> _allServers() => [
    ...widget.db.free,
    ...widget.vpngate.servers,
    ...widget.vpnbook.servers,
    ...widget.mirror.servers,
    ...widget.v2ray.servers,
  ];

  /// From the AppBar refresh button: reload the lists and re-run the
  /// health check.
  Future<void> refreshAll() async {
    widget.health.reset();
    await Future.wait([
      widget.db.load(forceRefresh: true),
      widget.vpngate.load(forceRefresh: true),
      widget.vpnbook.load(forceRefresh: true),
      widget.mirror.load(forceRefresh: true),
      widget.v2ray.load(forceRefresh: true),
    ]);
    await widget.health.checkAll(_allServers());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '✓ ${widget.health.workingCount} working • '
            '✗ ${widget.health.deadCount} dead',
          ),
        ),
      );
    }
  }

  /// Combined list from every OpenVPN source.
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
      // On Windows only WireGuard/WARP works - the OpenVPN and Xray
      // plugins have no Windows support.
      if (!isDesktop) const Tab(text: '🌍 OpenVPN'),
      if (!isDesktop) const Tab(text: '🕵️ Stealth'),
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
                    if (!isDesktop)
                      RefreshIndicator(
                        onRefresh: _refreshOpenvpn,
                        child: _openvpnList(),
                      ),
                    if (!isDesktop)
                      RefreshIndicator(
                        onRefresh: _refreshStealth,
                        child: _stealthList(),
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
          content: Text('${widget.db.free.length} free servers loaded.'),
        ),
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

  Future<void> _refreshStealth() async {
    await widget.v2ray.load(forceRefresh: true);
  }

  // ── Free (WARP) ───────────────────────────────────────────────
  Widget _freeList() {
    final servers = widget.db.free;
    if (servers.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 80),
          Center(
            child: Text(
              'No free servers were found.\nPull down to refresh.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: servers.length,
      itemBuilder: (context, i) =>
          _FadeIn(index: i, child: _warpCard(servers[i])),
    );
  }

  Widget _warpCard(VpnServer s) {
    return ListenableBuilder(
      listenable: widget.vpn,
      builder: (context, _) {
        final isCurrent =
            widget.vpn.server?.id == s.id &&
            widget.vpn.state == VpnState.connected;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          margin: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: isCurrent
                ? ChakraTheme.green.withValues(alpha: 0.10)
                : ChakraTheme.card,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isCurrent
                  ? ChakraTheme.green
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: ListTile(
            onTap: () => _connectTo(s),
            leading: Text(s.flag, style: const TextStyle(fontSize: 30)),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    s.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                _healthBadge(s),
              ],
            ),
            subtitle: Text(
              isCurrent
                  ? 'Connected • Tap to disconnect'
                  : 'WARP Free • WireGuard',
              style: TextStyle(
                color: isCurrent ? ChakraTheme.green : Colors.white54,
                fontSize: 12,
              ),
            ),
            trailing: isCurrent
                ? const Chip(
                    label: Text('Connected'),
                    backgroundColor: ChakraTheme.green,
                  )
                : ElevatedButton(
                    onPressed: () => _connectTo(s),
                    child: const Text('Connect'),
                  ),
          ),
        );
      },
    );
  }

  // ── OpenVPN (combined) ────────────────────────────────────────
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
    final anyLoading =
        widget.vpngate.loading ||
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
                'No OpenVPN servers were found.\nPull down to refresh.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ),
        ],
      );
    }
    // Group by country.
    final groups = <String, List<VpnServer>>{};
    for (final s in all) {
      groups.putIfAbsent(s.country, () => []).add(s);
    }
    final q = _query.trim().toLowerCase();
    final names = groups.keys.toList()..sort();
    final filtered = q.isEmpty
        ? names
        : names.where((c) => c.toLowerCase().contains(q)).toList();
    // Fastest first inside each group: measured probe latency wins,
    // the API-reported ping is the fallback (shared ordering helper).
    for (final name in groups.keys.toList()) {
      groups[name] = sortByHealthAndLatency(groups[name]!, widget.health);
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _searchBox('Search by country… (for example India, Japan)'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(
            '${all.length} servers • ${groups.length} countries • VPNGate + VPNBook + Mirror',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ),
        _healthSummary(),
        for (var i = 0; i < filtered.length; i++)
          _FadeIn(
            index: i,
            child: _countryGroup(filtered[i], groups[filtered[i]]!),
          ),
      ],
    );
  }

  // ── Stealth (Xray) ────────────────────────────────────────────

  /// Servers matching the active Stealth filter chip.
  List<VpnServer> _filteredStealth(List<VpnServer> all) {
    switch (_stealthFilter) {
      case 'Custom':
        return all.where((s) => s.source == 'custom').toList();
      case 'Private':
        return all.where((s) => s.source == 'private').toList();
      case 'All':
        return all;
      default:
        return all.where((s) => s.tier == _stealthFilter).toList();
    }
  }

  /// Stealth Auto candidates in the shared order: working servers
  /// fastest first (measured latency), then unchecked servers in
  /// tier order, dead servers last.
  List<VpnServer> _stealthCandidates() =>
      sortByHealthAndLatency(widget.v2ray.servers, widget.health);

  Future<void> _connectStealthAuto() async {
    final servers = widget.v2ray.servers;
    if (servers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No stealth servers are available yet.')),
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
    widget.vpn.setMode(AppMode.stealth);
    await widget.vpn.connectStealthAuto(candidates);
    if (!mounted) return;
    _showDnsFallbackNote();
    widget.onGoHome();
  }

  /// When a stealth connect succeeded with a fallback DNS, say so
  /// honestly instead of silently using a different resolver than
  /// the one the user selected.
  void _showDnsFallbackNote() {
    final note = widget.vpn.dnsFallbackNote;
    if (note == null || widget.vpn.state != VpnState.connected) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(note)));
  }

  /// Summary line built from the per-tier counts, for example:
  /// "128 servers • Reality 3 • TLS 41 • Shadowsocks 84 • Xray core".
  String _stealthSummary() {
    final counts = widget.v2ray.tierCounts;
    final parts = <String>['${widget.v2ray.servers.length} servers'];
    for (final tier in ['Reality', 'Hysteria2', 'TLS', 'Shadowsocks', 'VMess']) {
      final n = counts[tier] ?? 0;
      if (n > 0) parts.add('$tier $n');
    }
    parts.add('Xray core');
    return parts.join(' • ');
  }

  Widget _stealthAutoCard() {
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            ChakraTheme.violet.withValues(alpha: 0.28),
            ChakraTheme.cyan.withValues(alpha: 0.16),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ChakraTheme.violet.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          const Icon(Icons.visibility_off, color: Colors.white),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Stealth Auto',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                SizedBox(height: 2),
                Text(
                  'Tries Reality, Hysteria2, TLS and Shadowsocks '
                  'servers with the fastest working DNS until a '
                  'combination is verified.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _connectStealthAuto,
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  Widget _stealthChips() {
    const filters = [
      'All',
      'Reality',
      'Hysteria2',
      'TLS',
      'Shadowsocks',
      'Custom',
      'Private',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final f in filters)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(f),
                  selected: _stealthFilter == f,
                  onSelected: (selected) =>
                      setState(() => _stealthFilter = selected ? f : 'All'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showImportDialog() async {
    final controller = TextEditingController();
    final link = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Import stealth server'),
          content: TextField(
            controller: controller,
            maxLines: 4,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: 'Paste a vless://, trojan://, vmess:// or ss:// link',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(controller.text),
              child: const Text('Import'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (link == null || link.trim().isEmpty || !mounted) return;
    final added = await widget.v2ray.addCustomLink(link.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == null
              ? 'That link could not be parsed. Check it and try again.'
              : 'Stealth server imported.',
        ),
      ),
    );
  }

  Future<void> _removeCustomServer(VpnServer s) async {
    await widget.v2ray.removeCustomServer(s);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Imported server removed.')));
  }

  Widget _stealthList() {
    return ListenableBuilder(
      listenable: widget.v2ray,
      builder: (context, _) {
        final v = widget.v2ray;
        if (v.loading && v.servers.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (v.servers.isEmpty) {
          // Keep the Stealth Auto card visible in the empty state too,
          // so the tab never looks dead when the feed could not load.
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              _stealthAutoCard(),
              const SizedBox(height: 36),
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    v.error ??
                        'The stealth server list could not be loaded.\n'
                            'Pull down to try again.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white54),
                  ),
                ),
              ),
            ],
          );
        }
        // Header stays visible in both flat (filtered) and grouped
        // (All) layouts.
        final header = <Widget>[
          _searchBox('Search by country…'),
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 8,
                    horizontal: 4,
                  ),
                  child: Text(
                    _stealthSummary(),
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_link),
                tooltip: 'Import stealth server',
                color: ChakraTheme.cyan,
                onPressed: _showImportDialog,
              ),
            ],
          ),
          _healthSummary(),
          _stealthAutoCard(),
          _stealthChips(),
        ];
        if (_stealthFilter != 'All') {
          // Flat list of the servers matching the active filter,
          // fastest first (shared ordering helper).
          final matching =
              sortByHealthAndLatency(_filteredStealth(v.servers), widget.health);
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              ...header,
              if (matching.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      'No servers match this filter.',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              else
                for (var i = 0; i < matching.length; i++)
                  _FadeIn(index: i, child: _serverRow(matching[i])),
            ],
          );
        }
        final groups = <String, List<VpnServer>>{};
        for (final s in v.servers) {
          groups.putIfAbsent(s.country, () => []).add(s);
        }
        // Fastest first inside each country group.
        for (final name in groups.keys.toList()) {
          groups[name] = sortByHealthAndLatency(groups[name]!, widget.health);
        }
        final q = _query.trim().toLowerCase();
        final names = groups.keys.toList()..sort();
        final filtered = q.isEmpty
            ? names
            : names.where((c) => c.toLowerCase().contains(q)).toList();
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            ...header,
            for (var i = 0; i < filtered.length; i++)
              _FadeIn(
                index: i,
                child: _countryGroup(filtered[i], groups[filtered[i]]!),
              ),
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
        final ms = widget.health.latencyOf(s.id);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: c,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (ms != null) ...[
              const SizedBox(width: 4),
              Text(
                '• $ms ms',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// Summary strip above the list: how many servers are working/dead.
  Widget _healthSummary() {
    return ListenableBuilder(
      listenable: widget.health,
      builder: (context, _) {
        final h = widget.health;
        if (!h.checking && h.lastChecked == null) {
          return const SizedBox.shrink();
        }
        final text = h.checking
            ? 'Health check is running… ✓${h.workingCount} ✗${h.deadCount}'
            : '✓ ${h.workingCount} working • ✗ ${h.deadCount} dead';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(
            text,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        );
      },
    );
  }

  Widget _searchBox(String hint) {
    return TextField(
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
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
    'v2ray': 'Stealth',
    'custom': 'Imported',
    'private': 'Private',
  };

  /// Colour for a Stealth tier badge.
  static Color _tierColor(String tier) {
    switch (tier) {
      case 'Reality':
        return ChakraTheme.emerald;
      case 'Hysteria2':
        return Colors.deepOrangeAccent;
      case 'TLS':
        return ChakraTheme.cyan;
      case 'Shadowsocks':
        return ChakraTheme.violet;
      case 'VMess':
        return ChakraTheme.amber;
      case 'Custom':
        return Colors.pinkAccent;
      case 'Private':
        return Colors.tealAccent;
      default:
        return Colors.white54;
    }
  }

  static Widget _badge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  /// Badges shown next to a server name: the Stealth tier (Reality,
  /// TLS, Shadowsocks, VMess) and a Custom badge for imported servers.
  Widget _tierBadges(VpnServer s) {
    final badges = <Widget>[];
    if (s.isStealth && s.tier.isNotEmpty) {
      badges.add(_badge(s.tier, _tierColor(s.tier)));
    }
    if (s.source == 'custom') {
      badges.add(_badge('Custom', _tierColor('Custom')));
    }
    if (s.source == 'private') {
      badges.add(_badge('Private', _tierColor('Private')));
    }
    if (badges.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < badges.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          badges[i],
        ],
        const SizedBox(width: 6),
      ],
    );
  }

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
        title: Text(
          country,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${servers.length} servers',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        children: [for (final srv in servers) _serverRow(srv)],
      ),
    );
  }

  Widget _serverRow(VpnServer s) {
    return ListenableBuilder(
      listenable: widget.vpn,
      builder: (context, _) {
        final isCurrent =
            widget.vpn.server?.id == s.id &&
            widget.vpn.state == VpnState.connected;
        final src = _sourceLabel[s.source] ?? s.source;
        final isCustom = s.source == 'custom';
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            color: isCurrent
                ? ChakraTheme.green.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: ListTile(
            dense: true,
            onTap: () => _connectTo(s),
            title: Row(
              children: [
                Expanded(
                  child: Text(s.name, style: const TextStyle(fontSize: 13)),
                ),
                _tierBadges(s),
                _healthBadge(s),
              ],
            ),
            subtitle: Text(
              isCurrent
                  ? '${s.note}\n$src • Connected • Tap to disconnect'
                  : '${s.note}\n$src',
              style: TextStyle(
                color: isCurrent ? ChakraTheme.green : Colors.white54,
                fontSize: 11,
              ),
            ),
            isThreeLine: true,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isCurrent)
                  const Chip(
                    label: Text('Connected', style: TextStyle(fontSize: 11)),
                    backgroundColor: ChakraTheme.green,
                  )
                else
                  ElevatedButton(
                    onPressed: () => _connectTo(s),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(70, 32),
                      padding: EdgeInsets.zero,
                    ),
                    child: const Text(
                      'Connect',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                if (isCustom)
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Remove imported server',
                    color: Colors.white54,
                    onPressed: () => _removeCustomServer(s),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Chakra ────────────────────────────────────────────────────
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
              color: ChakraTheme.violet.withValues(alpha: 0.35),
            ),
          ),
          child: const Row(
            children: [
              Icon(Icons.lock_clock, color: ChakraTheme.violet),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Chakra Mode is in the trial phase — residential '
                  'IPs will rotate every few minutes. Coming soon!',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
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
                'There are no Chakra servers in the server '
                'database yet.',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          )
        else
          for (var i = 0; i < servers.length; i++)
            _FadeIn(index: i, child: _warpCard(servers[i])),
      ],
    );
  }

  Future<void> _connectTo(VpnServer s) async {
    // Tapping the server that is already connected (or still
    // connecting) disconnects instead of restarting the same tunnel,
    // and the user stays on this screen.
    if (shouldToggleDisconnect(
        widget.vpn.state, widget.vpn.server?.id, s.id)) {
      await widget.vpn.disconnect();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Disconnected')),
      );
      return;
    }
    if (s.protocol == 'v2ray') {
      // A manually picked Stealth server: switch to Stealth Mode so
      // the Home screen state matches the active engine.
      widget.vpn.setMode(AppMode.stealth);
    } else if (s.protocol == 'wireguard' && s.warp) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_server', s.id);
      widget.vpn.setMode(AppMode.free);
    }
    await widget.vpn.connect(s);
    if (!mounted) return;
    _showDnsFallbackNote();
    widget.onGoHome();
  }
}

/// Lightweight staggered entrance for list items: fades in and slides
/// up slightly, with a per-index delay capped so long lists stay cheap
/// and snappy.
class _FadeIn extends StatelessWidget {
  final int index;
  final Widget child;

  const _FadeIn({required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    const stepMs = 45;
    const animMs = 300;
    final delay = (index * stepMs).clamp(0, 270);
    final total = animMs + delay;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: total),
      builder: (context, value, child) {
        final raw = (value * total - delay) / animMs;
        final t = raw.clamp(0.0, 1.0);
        final eased = 1 - (1 - t) * (1 - t) * (1 - t);
        return Opacity(
          opacity: eased,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - eased)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
