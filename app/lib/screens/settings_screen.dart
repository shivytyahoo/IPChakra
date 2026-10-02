import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../services/server_database.dart';
import '../services/vpn_controller.dart';

/// Settings + About + database status.
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
            _section('Server Database', [
              ListTile(
                leading: const Icon(Icons.cloud_download,
                    color: ChakraTheme.cyan),
                title: Text('Version ${db.version}'),
                subtitle: Text(
                    db.updated.isNotEmpty
                        ? 'Updated: ${db.updated}'
                        : 'Bundled list use ho rahi hai',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12)),
                trailing: TextButton(
                  onPressed: () => _refreshDb(context),
                  child: const Text('Refresh'),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  'Source: ${db.source}',
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            _section('VPN Engine', [
              const ListTile(
                leading:
                    Icon(Icons.shield, color: ChakraTheme.green),
                title: Text('WireGuard'),
                subtitle: Text(
                    'Modern, fast aur secure protocol.',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              ),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Windows pe connect karne ke liye app ko Administrator '
                  'ke roop me chalana hoga (WireGuard ki requirement hai).',
                  style:
                      TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            _section('Free Identity', [
              ListTile(
                leading:
                    const Icon(Icons.key, color: ChakraTheme.amber),
                title: const Text('Nayi Free ID banao'),
                subtitle: const Text(
                    'Free mode ki identity reset karta hai.',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
                trailing: TextButton(
                  onPressed: () => _resetIdentity(context),
                  child: const Text('Reset'),
                ),
              ),
            ]),
            const SizedBox(height: 12),
            _section('About', [
              const ListTile(
                leading: Text('🌀', style: TextStyle(fontSize: 28)),
                title: Text('IPChakra',
                    style: TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 18)),
                subtitle: Text(
                    'Version 1.0.0\n\nFree Mode: unlimited fast VPN.\n'
                    'Chakra Mode: rotating residential IP — jald aa raha hai.',
                    style: TextStyle(
                        color: Colors.white54, fontSize: 12)),
              ),
            ]),
            const SizedBox(height: 24),
            const Center(
              child: Text('Made by Shiv',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ),
          ],
        );
      },
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: ChakraTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: ChakraTheme.cyan)),
          ),
          ...children,
        ],
      ),
    );
  }

  Future<void> _refreshDb(BuildContext context) async {
    await db.load(forceRefresh: true);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Database refreshed — version ${db.version} (${db.source}).')));
    }
  }

  Future<void> _resetIdentity(BuildContext context) async {
    await vpn.warp.resetIdentity();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Free identity reset ho gayi.')));
    }
  }
}
