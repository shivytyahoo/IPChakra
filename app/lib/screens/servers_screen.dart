import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme.dart';
import '../models/vpn_server.dart';
import '../services/health_service.dart';
import '../services/openvpn_database.dart';
import '../services/ovpn_mirror_service.dart';
import '../services/server_database.dart';
import '../services/share_service.dart';
import '../services/user_lists_service.dart';
import '../services/v2ray_service.dart';
import '../services/vpnbook_service.dart';
import '../services/vpn_controller.dart';
import '../services/vpngate_pool_service.dart';
import '../services/vpngate_service.dart';

/// Server list: Free (WARP) | OpenVPN (VPNGate + Pool + VPNBook +
/// Mirror) | Stealth (Xray) | Chakra.
class ServersScreen extends StatefulWidget {
  final ServerDatabase db;
  final VpnController vpn;
  final VpnGateService vpngate;
  final VpnGatePoolService pool;
  final VpnBookService vpnbook;
  final OvpnMirrorService mirror;
  final V2RayService v2ray;
  final HealthService health;
  final UserListsService userLists;
  final VoidCallback onGoHome;

  const ServersScreen({
    super.key,
    required this.db,
    required this.vpn,
    required this.vpngate,
    required this.pool,
    required this.vpnbook,
    required this.mirror,
    required this.v2ray,
    required this.health,
    required this.userLists,
    required this.onGoHome,
  });

  @override
  State<ServersScreen> createState() => ServersScreenState();
}

class ServersScreenState extends State<ServersScreen> {
  String _query = '';

  /// Active Stealth tier filter: 'All', 'Reality', 'Hysteria2',
  /// 'TLS', 'Shadowsocks', 'Custom', 'Private', 'Favourites' or
  /// 'Recent'.
  String _stealthFilter = 'All';

  /// Active list filter on the Free tab: 'All', 'Favourites' or
  /// 'Recent'.
  String _freeFilter = 'All';

  /// Active list filter on the OpenVPN tab: 'All', 'Favourites' or
  /// 'Recent'.
  String _ovpnFilter = 'All';

  Timer? _healthDebounce;

  /// Countries whose OpenVPN group is expanded in the grouped
  /// list. Groups start collapsed, so a database of ~5,000 servers
  /// renders as a short list of country headers; a group's rows
  /// are built only while the group is expanded.
  final Set<String> _ovpnExpanded = {};

  /// How many rows of an expanded OpenVPN country group are shown
  /// before the "Show more" row (per country; the shared ordering
  /// puts the best servers first, so the first page is the useful
  /// part of a group with thousands of entries).
  final Map<String, int> _ovpnShown = {};
  static const _ovpnFirstPage = 100;
  static const _ovpnPageStep = 300;

  @override
  void initState() {
    super.initState();
    if (widget.vpngate.servers.isEmpty) widget.vpngate.load();
    if (widget.pool.servers.isEmpty) widget.pool.load();
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
    widget.pool.addListener(_onSourcesChanged);
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
    widget.pool.removeListener(_onSourcesChanged);
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
    ...widget.pool.servers,
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
      widget.pool.load(forceRefresh: true),
      widget.vpnbook.load(forceRefresh: true),
      widget.mirror.load(forceRefresh: true),
      widget.v2ray.load(forceRefresh: true),
    ]);
    await widget.health.checkAll(_allServers());
    // A complete refresh has just rebuilt every source list, so
    // this is the one moment the full id universe is known:
    // favourites/recents whose servers are genuinely gone from the
    // pool are dropped silently here (and only here — a partial
    // load must never prune an id whose source has not loaded yet).
    await widget.userLists
        .pruneTo(_allServers().map((s) => s.id).toSet());
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

  List<VpnServer>? _mergedOvpnCache;
  List<Object>? _mergedOvpnInputs;

  /// The OpenVPN database: every source's servers merged into one
  /// list, deduplicated by endpoint (the official API and the
  /// rolling pool list many of the same relays) with the liveness
  /// registry's verified hint applied. Memoized on the identity of
  /// the source lists and the overlay set — the merge runs over
  /// ~5,000 entries, and this getter is read on every rebuild,
  /// including the health checker's progressive updates, where the
  /// inputs have not changed.
  List<VpnServer> get _openvpnServers {
    final inputs = <Object>[
      widget.vpngate.servers,
      widget.pool.servers,
      widget.vpnbook.servers,
      widget.mirror.servers,
      widget.pool.verifiedAliveKeys,
    ];
    final cache = _mergedOvpnCache;
    final prev = _mergedOvpnInputs;
    if (cache != null &&
        prev != null &&
        prev.length == inputs.length &&
        [
          for (var i = 0; i < inputs.length; i++)
            identical(inputs[i], prev[i]),
        ].every((same) => same)) {
      return cache;
    }
    final merged = mergeOpenvpnServers(
      [
        widget.vpngate.servers,
        widget.pool.servers,
        widget.vpnbook.servers,
        widget.mirror.servers,
      ],
      verifiedAliveKeys: widget.pool.verifiedAliveKeys,
    );
    _mergedOvpnCache = merged;
    _mergedOvpnInputs = inputs;
    return merged;
  }

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
      widget.pool.load(forceRefresh: true),
      widget.vpnbook.load(forceRefresh: true),
      widget.mirror.load(forceRefresh: true),
    ]);
  }

  Future<void> _refreshStealth() async {
    await widget.v2ray.load(forceRefresh: true);
  }

  // ── Free (WARP) ───────────────────────────────────────────────
  Widget _freeList() {
    return ListenableBuilder(
      listenable: widget.userLists,
      builder: (context, _) {
        final all = widget.db.free;
        if (all.isEmpty) {
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
        final List<VpnServer> servers = switch (_freeFilter) {
          'Favourites' =>
            all.where((s) => widget.userLists.isFavourite(s.id)).toList(),
          'Recent' => _recentOrdered(all),
          _ => all,
        };
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _listFilterChips(
              current: _freeFilter,
              onChanged: (v) => setState(() => _freeFilter = v),
            ),
            if (servers.isEmpty)
              _emptyFilterText(_freeFilter)
            else
              for (var i = 0; i < servers.length; i++)
                _FadeIn(index: i, child: _warpCard(servers[i])),
          ],
        );
      },
    );
  }

  /// The one layout every server row in this app is built from
  /// (v2.3.2). Until v2.3.1 both row widgets were Material ListTiles,
  /// which size their leading and trailing slots first at full
  /// intrinsic width and hand the title/subtitle only the leftover:
  /// once Batch B put share + favourite buttons next to Connect in
  /// the trailing slot, the leftover text slot at phone width
  /// collapsed below the intrinsic width of the health badge sitting
  /// in the title Row, the Expanded server name was allocated ~0 dp
  /// and names wrapped one character per line (Shiv's S25
  /// screenshots, 2026-10-11). This hand-built layout makes that
  /// squeeze impossible by construction:
  ///   * the name owns its whole line (an [Expanded] whose only
  ///     neighbour is the compact favourite button), single line,
  ///     ellipsis for genuinely long names;
  ///   * the status line (health badge + badges + meta text) gets
  ///     the full text-column width;
  ///   * the action buttons live on their own right-aligned footer
  ///     line, where they can never take width from any text.
  /// New row variants must be built on this skeleton, never on a
  /// ListTile with buttons in its trailing slot.
  Widget _serverTile({
    required VpnServer s,
    required bool isCurrent,
    required TextStyle nameStyle,
    required double radius,
    required String metaFirstLine,
    String? metaSecondLine,
    Widget? leading,
    bool showBadges = false,
    double metaFontSize = 11,
  }) {
    final metaStyle = TextStyle(
      color: isCurrent ? ChakraTheme.green : Colors.white54,
      fontSize: metaFontSize,
    );
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => _connectTo(s),
        borderRadius: BorderRadius.circular(radius),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (leading != null) ...[
                leading,
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Name line.
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: nameStyle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        _favButton(s),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Status line: health badge, tier/source badges,
                    // then the first meta line with the remaining
                    // width — it ellipsizes instead of squeezing the
                    // badge or the name.
                    Row(
                      children: [
                        _healthBadge(s),
                        if (showBadges) _tierBadges(s),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            metaFirstLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: metaStyle,
                          ),
                        ),
                      ],
                    ),
                    if (metaSecondLine != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          metaSecondLine,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: metaStyle,
                        ),
                      ),
                    const SizedBox(height: 8),
                    // Footer actions: share, (remove), connect.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        _shareButton(s),
                        if (s.source == 'custom')
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: 'Remove imported server',
                            color: Colors.white54,
                            style: IconButton.styleFrom(
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              padding: const EdgeInsets.all(6),
                              minimumSize: const Size(32, 32),
                            ),
                            onPressed: () => _removeCustomServer(s),
                          ),
                        const SizedBox(width: 6),
                        if (isCurrent)
                          const Chip(
                            label: Text(
                              'Connected',
                              style: TextStyle(fontSize: 11),
                            ),
                            backgroundColor: ChakraTheme.green,
                          )
                        else
                          ElevatedButton(
                            onPressed: () => _connectTo(s),
                            style: ElevatedButton.styleFrom(
                              // Shrink-wrap so the footer line stays
                              // exactly as tall as the button, not the
                              // padded 48 dp tap target.
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              minimumSize: const Size(76, 34),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                            child: const Text(
                              'Connect',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
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
          child: _serverTile(
            s: s,
            isCurrent: isCurrent,
            radius: 14,
            nameStyle: const TextStyle(fontWeight: FontWeight.bold),
            leading: Text(s.flag, style: const TextStyle(fontSize: 30)),
            metaFontSize: 12,
            metaFirstLine: isCurrent
                ? 'Connected • Tap to disconnect'
                : 'WARP Free • WireGuard',
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
        listenable: widget.pool,
        builder: (context, _) => ListenableBuilder(
          listenable: widget.vpnbook,
          builder: (context, _) => ListenableBuilder(
            listenable: widget.mirror,
            builder: (context, _) => ListenableBuilder(
              // Health is a list-level input too, not just a row
              // badge: the Working filter's membership changes as
              // verdicts land, and it must fill live.
              listenable: Listenable.merge([widget.userLists, widget.health]),
              builder: (context, _) => _openvpnBody(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _openvpnBody() {
    final all = _openvpnServers;
    final anyLoading =
        widget.vpngate.loading ||
        widget.pool.loading ||
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
    final chips = _listFilterChips(
      current: _ovpnFilter,
      onChanged: (v) => setState(() => _ovpnFilter = v),
      includeWorking: true,
    );
    if (_ovpnFilter == 'Recent') {
      // Recents are a flat shortlist in recency order — grouping by
      // country would bury the order the user cares about.
      final recents = _recentOrdered(all);
      return ListView(
        padding: const EdgeInsets.all(12),
        children: [
          chips,
          if (recents.isEmpty)
            _emptyFilterText('Recent')
          else
            for (var i = 0; i < recents.length; i++)
              _FadeIn(index: i, child: _serverRow(recents[i])),
        ],
      );
    }
    final pool = switch (_ovpnFilter) {
      'Favourites' =>
        all.where((s) => widget.userLists.isFavourite(s.id)).toList(),
      'Working' => workingServers(all, widget.health),
      _ => all,
    };
    // Group by country.
    final groups = <String, List<VpnServer>>{};
    for (final s in pool) {
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
    // The grouped list is FLATTENED and built lazily: with ~5,000
    // servers in the database, an eager ListView of country cards
    // (the pre-pool structure) would construct every row of every
    // group up front. Here each country contributes one header
    // item, and its rows become items only while the group is
    // expanded — and even then only the visible page of rows, with
    // a "Show more" item for the rest. ListView.builder inflates
    // just the items on screen, so the list scrolls smoothly at
    // any database size.
    final items = <_OvpnItem>[
      _OvpnWidget(chips),
      _OvpnWidget(_searchBox('Search by country… (for example India, Japan)')),
      _OvpnWidget(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Text(
            '${pool.length} servers • ${groups.length} countries • VPNGate + Pool + VPNBook + Mirror',
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ),
      ),
      _OvpnWidget(_healthSummary()),
      if ((_ovpnFilter == 'Favourites' || _ovpnFilter == 'Working') &&
          pool.isEmpty)
        _OvpnWidget(_emptyFilterText(_ovpnFilter)),
    ];
    for (final country in filtered) {
      final servers = groups[country]!;
      items.add(_OvpnHeader(country, servers));
      if (_ovpnExpanded.contains(country)) {
        items.add(_OvpnFastest(country, servers));
        final shown = _ovpnShown[country] ?? _ovpnFirstPage;
        final page = shown < servers.length ? shown : servers.length;
        for (var i = 0; i < page; i++) {
          items.add(_OvpnRow(servers[i]));
        }
        if (page < servers.length) {
          items.add(_OvpnMore(country, page, servers.length));
        }
      }
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      itemBuilder: (context, i) => _ovpnItemWidget(items[i]),
    );
  }

  Widget _ovpnItemWidget(_OvpnItem item) {
    return switch (item) {
      _OvpnWidget(:final widget) => widget,
      _OvpnHeader(:final country, :final servers) =>
        _ovpnGroupHeader(country, servers),
      _OvpnFastest(:final country, :final servers) => Padding(
          padding: const EdgeInsets.only(left: 12),
          child: _fastestTile(country, servers),
        ),
      _OvpnRow(:final server) => Padding(
          padding: const EdgeInsets.only(left: 12),
          child: _serverRow(server),
        ),
      _OvpnMore(:final country, :final shown, :final total) => Padding(
          padding: const EdgeInsets.only(left: 12),
          child: TextButton(
            onPressed: () => setState(
              () => _ovpnShown[country] = shown + _ovpnPageStep,
            ),
            child: Text(
              'Show more — $shown of $total shown',
              style: const TextStyle(color: ChakraTheme.cyan, fontSize: 12),
            ),
          ),
        ),
    };
  }

  /// A country group header for the OpenVPN list: flag, country
  /// name and the group's server count, with an expand chevron.
  /// Tapping toggles the group's rows in the flattened list.
  Widget _ovpnGroupHeader(String country, List<VpnServer> servers) {
    final expanded = _ovpnExpanded.contains(country);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: ChakraTheme.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() {
          if (expanded) {
            _ovpnExpanded.remove(country);
          } else {
            _ovpnExpanded.add(country);
          }
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Text(servers.first.flag, style: const TextStyle(fontSize: 30)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      country,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${servers.length} servers',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                expanded ? Icons.expand_less : Icons.expand_more,
                color: Colors.white54,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Stealth (Xray) ────────────────────────────────────────────

  /// Servers matching the active Stealth filter chip.
  List<VpnServer> _filteredStealth(List<VpnServer> all) {
    switch (_stealthFilter) {
      case 'Working':
        return workingServers(all, widget.health);
      case 'Custom':
        return all.where((s) => s.source == 'custom').toList();
      case 'Private':
        return all.where((s) => s.source == 'private').toList();
      case 'Favourites':
        return all
            .where((s) => widget.userLists.isFavourite(s.id))
            .toList();
      case 'Recent':
        // Order is applied at render time (recency order); the
        // membership is the full list.
        return all;
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
      await widget.health
          .checkMissing(servers.take(60).toList(), priority: true);
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
      'Working',
      'Reality',
      'Hysteria2',
      'TLS',
      'Shadowsocks',
      'Custom',
      'Private',
      'Favourites',
      'Recent',
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

  /// "Add subscription" dialog: the user names their own
  /// subscription and pastes its URL. The service validates both,
  /// fetches immediately, and merges the servers into the Stealth
  /// list under the chosen name.
  Future<void> _showAddSubscriptionDialog() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Add subscription'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'For example: My provider',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: urlController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Subscription URL',
                  hintText: 'https://…',
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Your subscription is fetched now and refreshed '
                'together with the built-in lists. Its servers '
                'appear in the Stealth list under this name.',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Add'),
            ),
          ],
        );
      },
    );
    final name = nameController.text;
    final url = urlController.text;
    nameController.dispose();
    urlController.dispose();
    if (confirmed != true || !mounted) return;
    final error =
        await widget.v2ray.addSubscription(name: name, url: url);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    final addedName = name.trim();
    final count = widget.v2ray.subscriptionServerCount(addedName);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count == 0
              ? 'Subscription added. No servers were fetched yet — '
                  'it will retry on the next refresh.'
              : 'Subscription added — $count servers.',
        ),
      ),
    );
  }

  Future<void> _removeSubscription(String name) async {
    await widget.v2ray.removeSubscription(name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Subscription removed.')),
    );
  }

  /// The user's subscriptions, one row each: name, server count,
  /// the traffic/expiry line when the provider reported one, and
  /// an honest note when the last refresh failed (the pool keeps
  /// serving the last good list meanwhile).
  Widget _subscriptionsBlock(V2RayService v) {
    if (v.subscriptions.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: ChakraTheme.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: [
          for (final sub in v.subscriptions)
            Builder(
              builder: (context) {
                final status = v.statusOf(sub.name);
                final userinfoLine = status.userinfo?.describe() ?? '';
                return ListTile(
                  dense: true,
                  leading: const Icon(
                    Icons.rss_feed,
                    color: ChakraTheme.cyan,
                    size: 20,
                  ),
                  title: Text(
                    sub.name,
                    // Subscription names are user-chosen and can be
                    // long: keep the title on one line (v2.3.2 sweep).
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${v.subscriptionServerCount(sub.name)} servers',
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 11,
                        ),
                      ),
                      if (userinfoLine.isNotEmpty)
                        Text(
                          userinfoLine,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      if (status.refreshFailed)
                        const Text(
                          'Last refresh failed — showing the last '
                          'good list',
                          style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Remove subscription',
                    color: Colors.white54,
                    onPressed: () => _removeSubscription(sub.name),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _stealthList() {
    return ListenableBuilder(
      // Health included: the Working filter fills live as the
      // background sweep lands verdicts.
      listenable:
          Listenable.merge([widget.v2ray, widget.userLists, widget.health]),
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
                icon: const Icon(Icons.rss_feed),
                tooltip: 'Add subscription',
                color: ChakraTheme.cyan,
                onPressed: _showAddSubscriptionDialog,
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
          _subscriptionsBlock(v),
        ];
        if (_stealthFilter != 'All' && _stealthFilter != 'Working') {
          // Flat list of the servers matching the active filter.
          // Tier filters keep the shared fastest-first ordering;
          // Recent is shown in recency order instead. ('Working'
          // takes the grouped path below, like 'All' — Shiv wants
          // the working set country-wise, fastest first.)
          final matching = _stealthFilter == 'Recent'
              ? _recentOrdered(_filteredStealth(v.servers))
              : sortByHealthAndLatency(
                  _filteredStealth(v.servers),
                  widget.health,
                );
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              ...header,
              if (matching.isEmpty)
                (_stealthFilter == 'Favourites' ||
                        _stealthFilter == 'Recent')
                    ? _emptyFilterText(_stealthFilter)
                    : const Padding(
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
        final groupedPool = _stealthFilter == 'Working'
            ? workingServers(v.servers, widget.health)
            : v.servers;
        final groups = <String, List<VpnServer>>{};
        for (final s in groupedPool) {
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
            if (_stealthFilter == 'Working' && groups.isEmpty)
              _emptyFilterText('Working')
            else
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

  /// The All / Favourites / Recent filter chips used by the Free
  /// and OpenVPN tabs (the Stealth tab has its own chip row). The
  /// OpenVPN tab also gets 'Working' — the auto-collected set of
  /// servers the health checks have verified, country-grouped and
  /// fastest-first like the full list (the Free tab's WARP entries
  /// are anycast, always working, so the filter means nothing
  /// there and is not offered).
  Widget _listFilterChips({
    required String current,
    required ValueChanged<String> onChanged,
    bool includeWorking = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      // Scrollable like the Stealth chip row: a plain Row of chips
      // overflows on narrow screens or large font scales (v2.3.2).
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final f in [
              'All',
              if (includeWorking) 'Working',
              'Favourites',
              'Recent',
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(f),
                  selected: current == f,
                  onSelected: (selected) {
                    if (selected) onChanged(f);
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The servers from [pool] that appear in the user's recents, in
  /// recency order (newest first). Ids whose servers are not in
  /// [pool] (another tab, or gone) are simply skipped.
  List<VpnServer> _recentOrdered(List<VpnServer> pool) {
    final byId = {for (final s in pool) s.id: s};
    return [
      for (final id in widget.userLists.recents)
        if (byId[id] != null) byId[id]!,
    ];
  }

  /// Empty-state text for a Favourites/Recent/Working filter with
  /// nothing in it yet.
  Widget _emptyFilterText(String filter) {
    final text = switch (filter) {
      'Favourites' =>
        'No favourites yet.\nTap the star on any server to add it here.',
      'Working' =>
        'No working servers found yet.\nHealth checks run automatically '
            'in the background — working servers will appear here as '
            'they are found.',
      _ =>
        'No recent connections yet.\nServers you connect to will appear here.',
    };
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54),
        ),
      ),
    );
  }

  /// The star toggle on a server row: filled amber when the server
  /// is a favourite, an outline otherwise. Persists by stable id.
  Widget _favButton(VpnServer s) {
    return ListenableBuilder(
      listenable: widget.userLists,
      builder: (context, _) {
        final fav = widget.userLists.isFavourite(s.id);
        return IconButton(
          // Compact: a server-row button must never take the default
          // 48 dp slot — row width is the scarcest resource on a
          // phone (see _serverTile).
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.all(6),
            minimumSize: const Size(32, 32),
          ),
          icon: Icon(
            fav ? Icons.star : Icons.star_border,
            size: 20,
            color: fav ? Colors.amber : Colors.white54,
          ),
          tooltip: fav ? 'Remove from favourites' : 'Add to favourites',
          onPressed: () => widget.userLists.toggleFavourite(s.id),
        );
      },
    );
  }

  /// The share button on a server row: opens the share sheet
  /// (share / copy / QR for share links).
  Widget _shareButton(VpnServer s) {
    return IconButton(
      // Compact for the same reason as the favourite button: row
      // buttons must stay small next to the text they serve.
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.all(6),
        minimumSize: const Size(32, 32),
      ),
      icon: const Icon(Icons.share, size: 19),
      tooltip: 'Share server',
      color: Colors.white54,
      onPressed: () => showServerShareSheet(context, s),
    );
  }

  /// Connect the fastest working server in a country group, using
  /// the health/latency data the list already sorts by. When no
  /// server in the group has been measured working yet, say so
  /// instead of guessing.
  Future<void> _connectFastest(
    String country,
    List<VpnServer> servers,
  ) async {
    final pick = pickFastestInGroup(servers, widget.health);
    if (pick == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No working server has been measured in this country '
            'yet — the health check may still be running.',
          ),
        ),
      );
      return;
    }
    await _connectTo(pick);
  }

  /// The "Connect fastest" row at the top of a country group.
  Widget _fastestTile(String country, List<VpnServer> servers) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.bolt, color: Colors.amber, size: 20),
      title: const Text(
        'Connect fastest',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        'The lowest-latency working server in $country',
        style: const TextStyle(color: Colors.white54, fontSize: 11),
      ),
      onTap: () => _connectFastest(country, servers),
    );
  }

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
        } else if (w == null && s.externalVerified) {
          // Not yet checked by the app itself, but an independent
          // registry verified this server alive with a real
          // OpenVPN handshake — a stronger hint than "unchecked",
          // and never shown once the app has its own verdict.
          c = Colors.tealAccent;
          label = 'verified';
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
    'vpngate-pool': 'VPNGate Pool',
    'vpnbook': 'VPNBook',
    'mirror': 'Mirror',
    'v2ray': 'Stealth',
    'snsub': 'sNSub',
    'au1rxx': 'Au1rxx',
    'epodonios': 'Epodonios',
    'eternity': 'Eternity',
    'submerge': 'Sub Merge',
    'pawdroid': 'Pawdroid',
    'matin': 'MatinGhanbari',
    'nomorewalls': 'NoMoreWalls',
    'barryfar': 'Barry-Far',
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
        children: [
          _fastestTile(country, servers),
          for (final srv in servers) _serverRow(srv),
        ],
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
        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          decoration: BoxDecoration(
            color: isCurrent
                ? ChakraTheme.green.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: _serverTile(
            s: s,
            isCurrent: isCurrent,
            radius: 10,
            nameStyle: const TextStyle(fontSize: 13),
            showBadges: true,
            metaFirstLine: s.note,
            metaSecondLine: isCurrent
                ? '$src • Connected • Tap to disconnect'
                : src,
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

/// One item of the flattened OpenVPN country list (see
/// [ServersScreenState._openvpnBody]): the list is built lazily
/// from these lightweight descriptors, so row widgets are only
/// ever constructed for the items on screen.
sealed class _OvpnItem {
  const _OvpnItem();
}

/// A fixed header widget (filter chips, search box, summaries).
class _OvpnWidget extends _OvpnItem {
  final Widget widget;
  const _OvpnWidget(this.widget);
}

/// A country group header (flag, name, server count, chevron).
class _OvpnHeader extends _OvpnItem {
  final String country;
  final List<VpnServer> servers;
  const _OvpnHeader(this.country, this.servers);
}

/// The "Connect fastest" row at the top of an expanded group.
class _OvpnFastest extends _OvpnItem {
  final String country;
  final List<VpnServer> servers;
  const _OvpnFastest(this.country, this.servers);
}

/// One server row of an expanded group.
class _OvpnRow extends _OvpnItem {
  final VpnServer server;
  const _OvpnRow(this.server);
}

/// The "Show more" row at the end of an expanded group's visible
/// page of rows.
class _OvpnMore extends _OvpnItem {
  final String country;
  final int shown;
  final int total;
  const _OvpnMore(this.country, this.shown, this.total);
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
