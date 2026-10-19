import 'dart:async';

import '../models/vpn_server.dart';
import 'health_service.dart';

/// The always-on background health sweep Shiv asked for: while the
/// app is open, EVERY server gets checked on its own — no tab has
/// to be visited and no button pressed.
///
/// Before this, the automatic check only ran inside the Servers
/// screen (and only for the sources that had loaded when it
/// fired), so a user who stayed on Home and tapped Connect met a
/// pool with no verdicts at all — the connect search then had to
/// discover dead servers one slow tunnel attempt at a time, which
/// is why it could sit at "Connecting…" for minutes.
///
/// The sweeper simply calls [HealthService.checkMissing] over the
/// whole universe (supplied by [collect], stealth and free first,
/// the big OpenVPN pool last) on a slow cycle. The health service
/// itself decides what actually needs probing — missing or stale
/// verdicts only, persisted results honoured — so after the first
/// full pass the cycles are nearly free, and a connect always
/// finds the freshest picture the app has. Lifecycle is the
/// owner's job: start while the app is foregrounded, stop when it
/// is not (probing a backgrounded app would waste battery for
/// badges nobody is looking at).
class HealthSweeper {
  HealthSweeper({
    required this.health,
    required this.collect,
    this.interval = const Duration(seconds: 45),
  });

  final HealthService health;

  /// The full server universe, in the order verdicts matter most:
  /// the lists a connect draws from first, the bulk pool last.
  /// Called fresh every pass, so sources that load late join the
  /// sweep on their own.
  final List<VpnServer> Function() collect;

  /// Pause between passes. A pass over a fully-fresh universe
  /// returns almost immediately; this is a re-scan cadence, not a
  /// probe budget.
  final Duration interval;

  bool _running = false;
  bool get running => _running;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  void stop() {
    _running = false;
  }

  Future<void> _loop() async {
    while (_running) {
      try {
        await health.checkMissing(collect());
      } catch (_) {
        // A sweep is best-effort; the next cycle retries.
      }
      // Wait out the interval in short steps so stop() is prompt.
      var waited = Duration.zero;
      const step = Duration(seconds: 1);
      while (_running && waited < interval) {
        await Future<void>.delayed(step);
        waited += step;
      }
    }
  }
}
