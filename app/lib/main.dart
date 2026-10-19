import 'dart:async';

import 'package:flutter/material.dart';

import 'core/app_version.dart';
import 'core/theme.dart';
import 'services/adshield_service.dart';
import 'services/health_service.dart';
import 'services/health_sweeper.dart';
import 'services/ovpn_mirror_service.dart';
import 'services/server_database.dart';
import 'services/user_lists_service.dart';
import 'services/v2ray_service.dart';
import 'services/vpnbook_service.dart';
import 'services/vpngate_pool_service.dart';
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

class _IPChakraAppState extends State<IPChakraApp>
    with WidgetsBindingObserver {
  late final ServerDatabase db;
  late final VpnGateService vpngate;
  late final VpnGatePoolService pool;
  late final VpnBookService vpnbook;
  late final OvpnMirrorService mirror;
  late final V2RayService v2ray;
  late final HealthService health;
  late final WarpService warp;
  late final UserListsService userLists;
  late final VpnController vpn;
  late final AdShieldService adShield;
  late final HealthSweeper _sweeper;
  bool _loading = true;
  int _tab = 0;
  final _serversKey = GlobalKey<ServersScreenState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    db = ServerDatabase();
    vpngate = VpnGateService();
    pool = VpnGatePoolService();
    vpnbook = VpnBookService();
    mirror = OvpnMirrorService();
    v2ray = V2RayService();
    health = HealthService();
    warp = WarpService();
    userLists = UserListsService();
    adShield = AdShieldService();
    vpn = VpnController(warp, userLists: userLists, adShield: adShield);
    // The background health sweep: while the app is open, every
    // server gets checked on its own — the connect lists first,
    // the bulk OpenVPN pool last — so a connect never has to
    // discover dead servers one slow attempt at a time.
    _sweeper = HealthSweeper(
      health: health,
      collect: () => [
        ...v2ray.servers,
        ...db.free,
        ...vpngate.servers,
        ...vpnbook.servers,
        ...mirror.servers,
        ...pool.servers,
      ],
    );
    _boot();
  }

  Future<void> _boot() async {
    // First launch after an upgrade: force-refresh the server lists
    // once, so caches written by an older build never survive it.
    final upgraded = await consumeFirstLaunchAfterUpgrade();
    // Database and free identity first; the remaining lists load in
    // the background.
    await db.load(forceRefresh: upgraded);
    // Last-known health verdicts: the lists open with their badges
    // and ordering already in place, and the background check only
    // re-probes what is missing or stale.
    await health.loadPersisted();
    // With the last-known verdicts in place, the background sweep
    // takes over: it fills the gaps and keeps verdicts fresh for
    // as long as the app stays in the foreground.
    _sweeper.start();
    // If WARP registration fails on a bad network, do not stay stuck
    // on the splash screen.
    try {
      await warp.ensureRegistered().timeout(const Duration(seconds: 25));
    } catch (_) {
      // WARP retries later; let the app open.
    }
    unawaited(userLists.load());
    // AdShield: switch state loads first, then the bundled domain
    // lists in the background; startup never waits for them.
    unawaited(adShield.init());
    unawaited(vpngate.load());
    unawaited(pool.load());
    unawaited(vpnbook.load());
    unawaited(mirror.load());
    unawaited(v2ray.load(forceRefresh: upgraded));
    if (mounted) setState(() => _loading = false);
    // Startup ground-truth check: if this process ever claims a
    // live session, prove it against the native engines before the
    // user can act on a stale claim.
    unawaited(vpn.reconcileNativeState());
  }

  /// Every return to the foreground re-proves the "Connected"
  /// claim against the native engines: a tunnel stopped from a
  /// notification, Settings or a quick-settings tile while the app
  /// was away must flip the UI to Disconnected, even if the stop
  /// event itself never reached the app.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(vpn.reconcileNativeState());
      _sweeper.start();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      // No badges are on screen while the app is away; probing
      // then would only spend battery.
      _sweeper.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sweeper.stop();
    vpn.dispose();
    adShield.dispose();
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
                  // On the Servers tab: refresh the lists and re-run
                  // the health check.
                  if (_tab == 1)
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Refresh servers',
                      onPressed: () => _serversKey.currentState?.refreshAll(),
                    ),
                ],
              ),
              body: IndexedStack(
                index: _tab,
                children: [
                  HomeScreen(
                      db: db,
                      vpn: vpn,
                      v2ray: v2ray,
                      health: health,
                      adshield: adShield),
                  ServersScreen(
                    key: _serversKey,
                    db: db,
                    vpn: vpn,
                    vpngate: vpngate,
                    pool: pool,
                    vpnbook: vpnbook,
                    mirror: mirror,
                    v2ray: v2ray,
                    health: health,
                    userLists: userLists,
                    onGoHome: () => setState(() => _tab = 0),
                  ),
                  SettingsScreen(db: db, vpn: vpn),
                ],
              ),
              bottomNavigationBar: BottomNavigationBar(
                currentIndex: _tab,
                onTap: (i) => setState(() => _tab = i),
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.home),
                    label: 'Home',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.dns),
                    label: 'Servers',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.settings),
                    label: 'Settings',
                  ),
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
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Gradient ring spinner.
            Container(
              width: 88,
              height: 88,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: ChakraTheme.brandGradient,
                boxShadow: ChakraTheme.glowViolet,
              ),
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Container(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: ChakraTheme.bg,
                  ),
                  child: const Center(
                    child: SizedBox(
                      width: 34,
                      height: 34,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          ChakraTheme.cyan,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'IPChakra',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Free • Stealth • Chakra',
              style: TextStyle(fontSize: 12, color: ChakraTheme.textDim),
            ),
          ],
        ),
      ),
    );
  }
}
