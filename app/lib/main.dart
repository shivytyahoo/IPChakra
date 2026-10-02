import 'dart:async';
import 'package:flutter/material.dart';
import 'core/theme.dart';
import 'services/health_service.dart';
import 'services/ovpn_mirror_service.dart';
import 'services/server_database.dart';
import 'services/v2ray_service.dart';
import 'services/vpnbook_service.dart';
import 'services/vpngate_service.dart';
import 'services/warp_service.dart';
import 'services/vpn_controller.dart';
import 'screens/home_screen.dart';
import 'screens/servers_screen.dart';
import 'screens/settings_screen.dart';

void main() {
  runApp(const IPChakraApp());
}

class IPChakraApp extends StatefulWidget {
  const IPChakraApp({super.key});

  @override
  State<IPChakraApp> createState() => _IPChakraAppState();
}

class _IPChakraAppState extends State<IPChakraApp> {
  late final ServerDatabase db;
  late final VpnGateService vpngate;
  late final VpnBookService vpnbook;
  late final OvpnMirrorService mirror;
  late final V2RayService v2ray;
  late final HealthService health;
  late final WarpService warp;
  late final VpnController vpn;
  bool _loading = true;
  int _tab = 0;
  final _serversKey = GlobalKey<ServersScreenState>();

  @override
  void initState() {
    super.initState();
    db = ServerDatabase();
    vpngate = VpnGateService();
    vpnbook = VpnBookService();
    mirror = OvpnMirrorService();
    v2ray = V2RayService();
    health = HealthService();
    warp = WarpService();
    vpn = VpnController(warp);
    _boot();
  }

  Future<void> _boot() async {
    // Database + free identity ready; baaki lists background me.
    await db.load();
    // WARP register me network fail ho to app splash pe atki na rahe.
    try {
      await warp
          .ensureRegistered()
          .timeout(const Duration(seconds: 25));
    } catch (_) {
      // WARP baad me retry hoga; app khulne do.
    }
    unawaited(vpngate.load());
    unawaited(vpnbook.load());
    unawaited(mirror.load());
    unawaited(v2ray.load());
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    vpn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'IPChakra',
      debugShowCheckedModeBanner: false,
      theme: ChakraTheme.dark(),
      home: _loading
          ? const _Splash()
          : Scaffold(
              appBar: AppBar(
                title: const Text('🌀 IPChakra'),
                centerTitle: true,
                actions: [
                  // Servers tab pe refresh button: lists + health check
                  if (_tab == 1)
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Servers refresh karo',
                      onPressed: () =>
                          _serversKey.currentState?.refreshAll(),
                    ),
                ],
              ),
              body: IndexedStack(
                index: _tab,
                children: [
                  HomeScreen(db: db, vpn: vpn),
                  ServersScreen(
                      key: _serversKey,
                      db: db,
                      vpn: vpn,
                      vpngate: vpngate,
                      vpnbook: vpnbook,
                      mirror: mirror,
                      v2ray: v2ray,
                      health: health,
                      onGoHome: () => setState(() => _tab = 0)),
                  SettingsScreen(db: db, vpn: vpn),
                ],
              ),
              bottomNavigationBar: BottomNavigationBar(
                currentIndex: _tab,
                onTap: (i) => setState(() => _tab = i),
                items: const [
                  BottomNavigationBarItem(
                      icon: Icon(Icons.home), label: 'Home'),
                  BottomNavigationBarItem(
                      icon: Icon(Icons.dns), label: 'Servers'),
                  BottomNavigationBarItem(
                      icon: Icon(Icons.settings), label: 'Settings'),
                ],
              ),
            ),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('🌀', style: TextStyle(fontSize: 64)),
            SizedBox(height: 12),
            Text('IPChakra',
                style:
                    TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            SizedBox(height: 16),
            CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}
