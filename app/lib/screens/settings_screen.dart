import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../services/dns_service.dart';
import '../services/server_database.dart';
import '../services/system_settings.dart';
import '../services/vpn_controller.dart';

/// Human "Last checked" formatting, e.g. "10 Oct 2026, 09:12",
/// without pulling in a date-formatting package.
String formatLastChecked(DateTime t) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.day} ${months[t.month - 1]} ${t.year}, '
      '${two(t.hour)}:${two(t.minute)}';
}

/// Settings, About and database status, in glass sections.
class SettingsScreen extends StatelessWidget {
  final ServerDatabase db;
  final VpnController vpn;

  const SettingsScreen({super.key, required this.db, required this.vpn});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: db,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _FadeIn(
              index: 0,
              child: _section('Server Database', [
                ListTile(
                  leading: const Icon(
                    Icons.cloud_download,
                    color: ChakraTheme.cyan,
                  ),
                  title: Text('Version ${db.version}'),
                  subtitle: Text(
                    [
                      if (db.updated.isNotEmpty) 'Updated: ${db.updated}',
                      if (db.generated.isNotEmpty)
                        'Generated: ${db.generated}',
                      if (db.updated.isEmpty && db.generated.isEmpty)
                        'Using the bundled server list.',
                    ].join('\n'),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  trailing: TextButton(
                    onPressed: () => _refreshDb(context),
                    child: const Text('Refresh'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: Text(
                    'Source: ${db.source}'
                    '${db.lastChecked != null ? ' • Last checked: ${formatLastChecked(db.lastChecked!)}' : ''}',
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            _FadeIn(
              index: 1,
              child: _section('VPN Engine', [
                const ListTile(
                  leading: Icon(Icons.shield, color: ChakraTheme.green),
                  title: Text('WireGuard'),
                  subtitle: Text(
                    'A modern, fast and secure protocol.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                const ListTile(
                  leading: Icon(Icons.visibility_off, color: ChakraTheme.cyan),
                  title: Text('Stealth (Xray)'),
                  subtitle: Text(
                    'Reality, Hysteria2, TLS and Shadowsocks servers '
                    'for restrictive networks.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'On Windows, run the app as Administrator to '
                    'connect (a WireGuard requirement).',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            const _FadeIn(index: 2, child: _DnsSection()),
            const SizedBox(height: 12),
            _FadeIn(
              index: 3,
              child: _section('Privacy & Leak Protection', [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Text(
                    'IPChakra itself does not block your traffic when '
                    'a tunnel drops. For system-level leak protection, '
                    'Android offers a lockdown: in the system VPN '
                    'settings, turn on "Always-on VPN" for IPChakra '
                    'and enable "Block connections without VPN". '
                    'While it is on, Android blocks all network '
                    'traffic unless the VPN is connected, so nothing '
                    'can leak outside the tunnel.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.settings, size: 18),
                      label: const Text('Open system VPN settings'),
                      onPressed: () => _openSystemVpnSettings(context),
                    ),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            _FadeIn(
              index: 4,
              child: _section('Free Identity', [
                ListTile(
                  leading: const Icon(Icons.key, color: ChakraTheme.amber),
                  title: const Text('Create a new free identity'),
                  subtitle: const Text(
                    'Resets the identity used by Free Mode.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  trailing: TextButton(
                    onPressed: () => _resetIdentity(context),
                    child: const Text('Reset'),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            _FadeIn(
              index: 5,
              child: _section('About', [
                const ListTile(
                  leading: Icon(
                    Icons.donut_large,
                    color: ChakraTheme.violet,
                    size: 30,
                  ),
                  title: Text(
                    'IPChakra',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  subtitle: Text(
                    'Version 2.2.0\n\n'
                    'Free Mode: unlimited fast VPN.\n'
                    'Stealth Mode: Reality, Hysteria2, TLS and '
                    'Shadowsocks servers that stay working on '
                    'restrictive networks. Every stealth connection '
                    'is verified with the fastest working DNS before '
                    'it is shown as connected.\n'
                    'Chakra Mode: rotating residential IPs — '
                    'coming soon.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 24),
            const _FadeIn(
              index: 6,
              child: Center(
                child: Text(
                  'Made with ❤️ by Shiv',
                  style: TextStyle(
                    color: ChakraTheme.amber,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: ChakraTheme.glassFill,
        borderRadius: BorderRadius.circular(ChakraTheme.radiusLg),
        border: Border.all(color: ChakraTheme.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: ChakraTheme.cyan,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Future<void> _refreshDb(BuildContext context) async {
    await db.load(forceRefresh: true);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Database refreshed — version ${db.version} (${db.source}).',
          ),
        ),
      );
    }
  }

  Future<void> _openSystemVpnSettings(BuildContext context) async {
    final opened = await SystemSettings.openVpnSettings();
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The system VPN settings could not be opened on this '
            'device. You can find them under Android Settings, '
            'in the VPN section.',
          ),
        ),
      );
    }
  }

  Future<void> _resetIdentity(BuildContext context) async {
    await vpn.warp.resetIdentity();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Free identity has been reset.')),
      );
    }
  }
}

/// The "DNS Server" settings section: a radio list of every built-in
/// public DNS provider, plus a real speed test that measures each
/// provider's DNS response time and re-sorts the list fastest-first.
class _DnsSection extends StatefulWidget {
  const _DnsSection();

  @override
  State<_DnsSection> createState() => _DnsSectionState();
}

class _DnsSectionState extends State<_DnsSection> {
  final DnsService _dns = DnsService();

  @override
  void initState() {
    super.initState();
    _dns.load();
  }

  @override
  void dispose() {
    _dns.dispose();
    super.dispose();
  }

  static Color _tagColor(String tag) {
    switch (tag) {
      case 'Fast':
        return ChakraTheme.cyan;
      case 'Ad blocking':
        return ChakraTheme.violet;
      case 'Family':
        return ChakraTheme.amber;
      case 'Malware blocking':
        return ChakraTheme.emerald;
      default:
        return Colors.white54;
    }
  }

  Widget _tagChip(String tag) {
    final color = _tagColor(tag);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        tag,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  /// The measured result shown at the trailing edge of a row:
  /// "82 ms", "timeout", or nothing before the first test.
  Widget? _resultLabel(DnsProvider p) {
    if (!_dns.results.containsKey(p.id)) {
      return _dns.testing
          ? const Text('…', style: TextStyle(color: Colors.white38))
          : null;
    }
    final ms = _dns.results[p.id];
    if (ms == null) {
      return const Text(
        'timeout',
        style: TextStyle(color: ChakraTheme.red, fontSize: 12),
      );
    }
    return Text(
      '$ms ms',
      style: const TextStyle(
        color: ChakraTheme.emerald,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _dns,
      builder: (context, _) {
        return Container(
          decoration: BoxDecoration(
            color: ChakraTheme.glassFill,
            borderRadius: BorderRadius.circular(ChakraTheme.radiusLg),
            border: Border.all(color: ChakraTheme.glassBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(
                  'DNS Server',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: ChakraTheme.cyan,
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(
                  'Used by Free (WireGuard) and Stealth (Xray) '
                  'connections. OpenVPN servers provide their own DNS, '
                  'so this choice does not apply to them.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: Row(
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.speed, size: 18),
                      label: Text(
                        _dns.testing ? 'Testing…' : 'Test DNS speed',
                      ),
                      onPressed: _dns.testing ? null : _dns.testAll,
                    ),
                    if (_dns.hasResults) ...[
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Sorted by measured speed, fastest first.',
                          style: TextStyle(
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              RadioGroup<String>(
                groupValue: _dns.selected.id,
                onChanged: (v) {
                  if (v != null) _dns.select(DnsService.byId(v));
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final p in _dns.displayProviders)
                      RadioListTile<String>(
                        value: p.id,
                        dense: true,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 8),
                        title: Row(
                          children: [
                            Expanded(
                              child: Text(
                                p.name,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                            _tagChip(p.tag),
                          ],
                        ),
                        subtitle: Text(
                          p.note.isEmpty
                              ? p.displayServers
                              : '${p.displayServers} • ${p.note}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                        secondary: _resultLabel(p),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
            ],
          ),
        );
      },
    );
  }
}

/// Lightweight staggered entrance: fades in and slides up slightly,
/// with a per-index delay capped so long screens stay snappy.
class _FadeIn extends StatelessWidget {
  final int index;
  final Widget child;

  const _FadeIn({required this.index, required this.child});

  @override
  Widget build(BuildContext context) {
    const stepMs = 70;
    const animMs = 320;
    final delay = (index * stepMs).clamp(0, 280);
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
            offset: Offset(0, 14 * (1 - eased)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
