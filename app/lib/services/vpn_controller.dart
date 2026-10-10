import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_v2ray_client/flutter_v2ray.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wireguard_flutter/wireguard_flutter.dart';
import 'package:wireguard_flutter/wireguard_flutter_platform_interface.dart';
import '../core/net.dart';
import '../models/vpn_server.dart';
import 'dns_combo.dart';
import 'dns_service.dart';
import 'hysteria_config.dart';
import 'stealth_link.dart';
import 'tunnel_verifier.dart';
import 'vpngate_service.dart';
import 'warp_service.dart';

enum VpnState {
  disconnected,
  connecting,
  connected,
  disconnecting,

  /// A live Stealth session whose tunnel died silently (the native
  /// engine never reported a stop — the watchdog's through-tunnel
  /// probes stopped answering) and is being restored on the SAME
  /// server by the escalation ladder. Distinct from [connected]
  /// (the tunnel is not usable right now and the UI must not claim
  /// it is) and from [disconnected] (the session's intent is still
  /// alive: only the user, or the ladder giving up, ends it).
  reconnecting,
  error,
}

enum AppMode { free, stealth, chakra }

/// Whether a native "connected" event may be honoured right now.
///
/// Native engines keep emitting status events after the user has
/// disconnected — most visibly the V2Ray plugin, whose periodic traffic
/// ticks carry state CONNECTED. Such an event is only meaningful while
/// a connection attempt or session is actually live, i.e. the state is
/// [VpnState.connecting] or [VpnState.connected] AND a server is still
/// selected. In every other state (disconnected, disconnecting, error,
/// or no server) the event is stale and must be ignored, otherwise a
/// late tick resurrects the UI to "Connected" after the user tapped
/// disconnect (the v2.0.0 first-tap-disconnect bug).
bool shouldHonorConnectedEvent(VpnState state, bool hasActiveServer) =>
    hasActiveServer &&
    (state == VpnState.connecting || state == VpnState.connected);

/// Whether a native transitional ("connecting") event may move the UI
/// to the connecting state. Only while an attempt or session is live;
/// a stale event arriving after disconnect must not resurrect it.
bool shouldHonorConnectingEvent(VpnState state) =>
    state == VpnState.connecting || state == VpnState.connected;

/// Whether tapping a server row should DISCONNECT instead of connect.
///
/// Tapping the server that is already connected — or the one whose
/// connection attempt is still in flight — is a disconnect request.
/// Tapping any other row (or any row while disconnected, disconnecting
/// or in the error state) is a connect request.
bool shouldToggleDisconnect(
        VpnState state, String? currentId, String tappedId) =>
    currentId != null &&
    currentId == tappedId &&
    (state == VpnState.connected || state == VpnState.connecting);

/// Whether a stealth search loop may continue after an await.
///
/// The combination search loops (Stealth Auto and the verified manual
/// connect) run many sequential attempts and poll the state while
/// they wait. Their only stop signal used to be the per-attempt
/// counter, which a user disconnect also bumps — so the loop could
/// not tell "the user tapped disconnect" from "this attempt failed":
/// it waited out its deadline and started the NEXT combination,
/// reconnecting against the user's explicit tap (the v2.1.0
/// "disconnect never sticks" bug). The loops therefore capture an
/// operation-session token at entry and re-check it after every
/// await and on every poll tick; any new user intent (disconnect or
/// a fresh connect) increments the token and the loops abort
/// immediately and silently.
bool autoShouldContinue({
  required int session,
  required int currentSession,
}) =>
    session == currentSession;

/// Whether a native event from [engine] may change the connection
/// state while [activeEngine] is the engine that is connecting or
/// connected (null when none is).
///
/// All three engines' callbacks feed ONE state machine. Without
/// scoping, a DISCONNECTED event from an engine that was just stopped
/// (every connect stops all engines first) can land during another
/// engine's attempt and fail it; the genuine "connected" event that
/// follows is then rejected by the connected-event guard because the
/// state is already error — the v2.1.0 "WARP errors and never shows
/// Connected" bug. Events only count from the active engine.
bool shouldHonorEngineEvent(String? activeEngine, String engine) =>
    activeEngine != null && activeEngine == engine;

/// Whether a power-button tap in [state] must reset to a clean
/// disconnected state instead of starting a new connection. In the
/// error state a tap reads to the user as "make it stop", and
/// falling through to connect made it look like the button
/// reconnected on its own.
bool toggleShouldReset(VpnState state) => state == VpnState.error;

/// Whether a DISCONNECTED-style event from the active engine should
/// be treated as a *user* disconnect (the native side was stopped
/// from outside the app — a VPN notification action, Android
/// Settings, or a quick-settings tile) rather than as a
/// connect-attempt failure.
///
/// - When fully [VpnState.connected] no connect attempt is running,
///   so a stop can only have come from outside: always a native stop.
/// - When [VpnState.reconnecting] a self-heal ladder is running,
///   but the same rule as the search applies: a stop that is not one
///   of the controller's own (those are consumed as echoes before
///   this predicate is consulted) came from outside and ends the
///   session — the self-heal must never resurrect a tunnel the user
///   stopped from the notification mid-heal.
/// - While a Stealth Auto / verified search is running
///   ([searchRunning]), the search owns the state machine, and a stop
///   mid-search must cancel the whole search — never advance it to
///   the next combination. Same family as the in-app disconnect.
/// - During a manual single connect (connecting, no search), a stop
///   event keeps the failure semantics so the user still sees why
///   the server did not connect.
bool isNativeStopEvent({
  required VpnState state,
  required bool searchRunning,
}) =>
    state == VpnState.connected ||
    state == VpnState.reconnecting ||
    (state == VpnState.connecting && searchRunning);

/// How long a DISCONNECTED-style event can still be the echo of a
/// stop this controller issued itself. A stop's event follows the
/// stop within a second or two on a healthy device; the window is
/// generous so a heavily loaded device cannot push a genuine echo
/// past it, yet short enough that a stale marker can never shadow a
/// real session for long (a session's own Connected event clears
/// its engine's markers the moment the tunnel is up — see
/// [VpnController._markConnected]).
const Duration selfStopEchoWindow = Duration(seconds: 20);

/// Whether a DISCONNECTED-style event arriving at [now] can still
/// be attributed to a self-issued stop recorded at [issuedAt].
///
/// Every engine answers a stop with a DISCONNECTED-style event:
/// the V2Ray plugin broadcasts one from `stopCore()` even when no
/// core was running, and the WireGuard plugin emits a `disconnected`
/// stage for every `stopVpn`. Those echoes carry no provenance, so
/// before this mechanism existed, an echo delivered late — after
/// the next connect attempt had already claimed its engine — was
/// indistinguishable from an external stop: mid-search it cancelled
/// the whole search as a "native stop", in the connected/verify
/// window it tore the attempt down, and in a manual connect it was
/// routed as the attempt's failure (the v2.1.3 Stealth Auto churn
/// and the WARP first-tap failure). The controller therefore
/// records every stop it issues, per engine, and consumes exactly
/// one echo per recorded stop.
bool isSelfStopEcho({required DateTime? issuedAt, required DateTime now}) =>
    issuedAt != null &&
    !now.isBefore(issuedAt) &&
    now.difference(issuedAt) <= selfStopEchoWindow;

/// What one native engine reports about its own tunnel right now,
/// from a synchronous ground-truth query (never from a cached
/// event): the tunnel is verifiably [up], verifiably [down], or
/// the query could not decide ([unknown] — engine not initialised,
/// a transitional native state, or the query failed).
enum NativeTunnelStatus { up, down, unknown }

/// What the start/resume reconciliation should do about a mismatch
/// between the app's state and the native ground truth.
enum ReconcileAction { none, teardownToDisconnected }

/// Reconciliation decision: when may the app keep claiming a live
/// session, and when must it tear the session down to plain
/// disconnected (the v2.1.2 S25 bug: the tunnel was stopped from
/// the VPN notification, the news never reached the app, and the
/// UI kept showing "Connected" with the old server/IP)?
///
/// The rule set is deliberately one-directional:
/// - Native [NativeTunnelStatus.up] or [NativeTunnelStatus.unknown]
///   never changes anything — a query that cannot prove the tunnel
///   is down must never kill a live session.
/// - App fully connected + native verifiably down ⇒ teardown. A
///   settled session has no attempt machinery left running, so a
///   down tunnel can only mean the native side was stopped from
///   outside; the teardown is the native-stop one (never an error,
///   never a reconnect).
/// - App connecting + native down ⇒ teardown only as a last-resort
///   net: no stealth search may be running (between combinations
///   the engine is legitimately down) and the attempt must already
///   be older than the connect settle window (before that, "down"
///   is the normal not-yet-up reading and the attempt's own
///   watchdog owns the outcome).
/// - Every other app state makes no claim about a tunnel, so there
///   is nothing to reconcile.
ReconcileAction reconcileAction({
  required VpnState appState,
  required NativeTunnelStatus native,
  required bool searchRunning,
  required Duration connectingFor,
}) {
  if (native != NativeTunnelStatus.down) return ReconcileAction.none;
  if (appState == VpnState.connected) {
    return ReconcileAction.teardownToDisconnected;
  }
  if (appState == VpnState.connecting &&
      !searchRunning &&
      connectingFor >= const Duration(seconds: 45)) {
    return ReconcileAction.teardownToDisconnected;
  }
  return ReconcileAction.none;
}

/// Poore app ka VPN brain: connect/disconnect + state.
///
/// Teen engine:
/// - WireGuard (WARP free + custom) — Android, TV, Windows
/// - OpenVPN (VPNGate, VPNBook, Mirror) — Android, TV
/// - V2Ray/Xray (free ss links) — Android, TV
///
/// Hang-proof design:
/// - har native call pe timeout (koi await kabhi infinite nahi)
/// - generation counter: purana attempt naya aate hi cancel
/// - watchdog: callback na aaye to native poll + IP-change se verify
class VpnController extends ChangeNotifier {
  final WireGuardFlutterInterface _wg;
  late final OpenVPN _ovpn;
  late final V2ray _v2ray;
  final WarpService warp;

  VpnState state = VpnState.disconnected;
  AppMode mode = AppMode.free;
  VpnServer? currentServer;
  String? currentIp;
  String? errorMsg;
  DateTime? connectedAt;

  /// The DNS provider actually carrying the live session, recorded
  /// at the moment the connection was established. For Stealth it
  /// is the provider of the (server, DNS) combination that passed
  /// through-tunnel verification — the user's selected provider
  /// when it worked, the fallback provider when it did not. For
  /// Free (WireGuard) it is the selected provider, which is
  /// written into the tunnel configuration at connect time and is
  /// therefore effective by construction. OpenVPN sessions leave
  /// it null: those servers push their own DNS, which the app can
  /// neither override nor read back. It is cleared on every
  /// teardown path (disconnect, native stop, failure,
  /// reconciliation) alongside [currentServer] and [currentIp],
  /// so a dead session's DNS can never be attributed to a new one.
  DnsProvider? effectiveDns;

  /// Latest traffic/status snapshot reported by the V2Ray engine.
  V2RayStatus? v2rayStatus;

  /// Honest progress detail while a stealth connect searches for a
  /// working (server, DNS) combination, e.g. "Trying Berlin with
  /// Quad9 DNS (2/6)…". Null when no search is running; the Home
  /// screen shows it in place of the plain state label.
  String? statusNote;

  /// Set after a stealth connect that succeeded with a fallback DNS
  /// instead of the user's selected provider, so the UI can say so
  /// honestly, e.g. "Connected with Google DNS because the selected
  /// DNS (Quad9) did not work with this server." Null otherwise.
  String? dnsFallbackNote;

  /// The DNS provider the in-flight stealth attempt must use,
  /// overriding the persisted selection (combination search).
  DnsProvider? _dnsOverride;

  /// Exit address measured just before the current stealth attempt
  /// started; the verification gate compares the tunnel's exit
  /// against it.
  String? _lastBaselineIp;

  void _setStatusNote(String? note) {
    statusNote = note;
    notifyListeners();
  }

  /// Kaunsa engine chal raha hai: 'wireguard' | 'openvpn' | 'v2ray' | null
  String? _activeEngine;

  /// Har connect/disconnect pe badhta hai; purane async kaam isse
  /// check karke khud cancel ho jaate hain.
  int _attempt = 0;
  bool _isCurrent(int a) => a == _attempt;

  /// Operation-session token for the stealth search loops. Captured
  /// by a loop at entry ([autoShouldContinue]); incremented by every
  /// new user intent — disconnect() and connect() — which is how a
  /// running loop learns that the user has taken over.
  int _autoSession = 0;

  /// Session of the stealth search loop currently running, or null.
  /// Guards against two loops running at once and fighting over the
  /// engines; cleared by the owning loop when it exits.
  int? _autoRunningSession;

  /// Per-engine timestamps of stops THIS controller issued whose
  /// DISCONNECTED-style echo has not been delivered yet (see
  /// [isSelfStopEcho]). A stop echo is consumed one-for-one: the
  /// first matching event after the stop is the echo; any further
  /// stop event is genuine (an external stop, or the live
  /// attempt's own verdict) and is routed normally.
  final Map<String, List<DateTime>> _selfStopEchoes = {};

  /// Record a stop this controller is about to issue to [engine],
  /// so the DISCONNECTED-style event it produces can be recognised
  /// as a self-stop echo when it arrives — whenever it arrives.
  void _noteSelfStop(String engine) {
    final echoes = _selfStopEchoes.putIfAbsent(engine, () => <DateTime>[]);
    final now = DateTime.now();
    echoes.removeWhere((t) => !isSelfStopEcho(issuedAt: t, now: now));
    echoes.add(now);
  }

  /// If [engine] still owes this controller a stop echo, consume
  /// one and return true: the event being routed is that echo, not
  /// news about the live attempt, and must change nothing.
  bool _consumeSelfStopEcho(String engine) {
    final echoes = _selfStopEchoes[engine];
    if (echoes == null || echoes.isEmpty) return false;
    final now = DateTime.now();
    echoes.removeWhere((t) => !isSelfStopEcho(issuedAt: t, now: now));
    if (echoes.isEmpty) return false;
    echoes.removeAt(0);
    return true;
  }

  /// Test-only view: how many stop echoes [engine] still owes.
  @visibleForTesting
  int debugPendingSelfStopEchoes(String engine) =>
      _selfStopEchoes[engine]?.length ?? 0;

  /// Whether a native event from [engine] may change the state now.
  bool _honorEngineEvent(String engine) =>
      shouldHonorEngineEvent(_activeEngine, engine);

  /// Test-only view of the operation-session token.
  @visibleForTesting
  int get debugAutoSession => _autoSession;

  /// Test-only: whether a stealth search loop is running.
  @visibleForTesting
  bool get debugAutoRunning => _autoRunningSession != null;

  /// Test-only: claim an active engine, as the connect paths do.
  @visibleForTesting
  void debugSetActiveEngine(String? engine) => _activeEngine = engine;

  /// Test-only seam: deliver a DISCONNECTED-style event from
  /// [engine] exactly as the native callbacks route it (the caller
  /// is responsible for engine scoping, as in the real callbacks).
  @visibleForTesting
  void debugNativeDisconnected(String engine) =>
      _onEngineDisconnected(engine, 'debug failure message');

  /// Test-only seam: pretend the platform is Android, so the
  /// engine connect paths (which refuse to run anywhere else) can
  /// be exercised by the event-sequence tests. Never set in
  /// production.
  @visibleForTesting
  bool debugForceAndroid = false;

  bool get _isAndroid => debugForceAndroid || Platform.isAndroid;

  /// Test-only seam: deliver a V2Ray status event with the given
  /// state string ('CONNECTED', 'DISCONNECTED', …) exactly as the
  /// plugin's status channel delivers it.
  @visibleForTesting
  void debugV2rayStatus(String state) => _onV2rayStatus(V2RayStatus(
        duration: '00:00:00',
        uploadSpeed: 0,
        downloadSpeed: 0,
        upload: 0,
        download: 0,
        state: state,
      ));

  /// Test-only seam: deliver a WireGuard stage event ('connected',
  /// 'disconnected', …) exactly as the plugin's stage stream
  /// delivers it.
  @visibleForTesting
  void debugWgStage(String stage) => _onStage(stage);

  /// Test-only seam: replace the through-tunnel combination
  /// verification (which needs a live Xray core) with a stub.
  @visibleForTesting
  Future<bool> Function(DnsProvider dns)? debugComboVerifier;

  /// Test-only seam: replace the connect-time DNS provider
  /// measurement (which needs live UDP) with a stub returning a
  /// provider-id -> round-trip-milliseconds map (null = the
  /// provider did not answer).
  @visibleForTesting
  Future<Map<String, int?>> Function()? debugMeasureProviders;

  /// The connect-time DNS measurement, through the test seam when
  /// one is installed.
  Future<Map<String, int?>> _measureProviders() =>
      debugMeasureProviders?.call() ?? DnsService.measureAllProviders();

  // ── Stealth resilience (v2.2.0) ───────────────────────────────

  /// Whether a stealth connect/heal flow currently holds the
  /// "Connected" claim behind its gates. While held, the V2Ray
  /// engine's CONNECTED events only record [_gatedTunnelUp]; the
  /// public state stays at connecting/reconnecting until the
  /// combination has passed through-tunnel verification AND the
  /// stability gate, and [_confirmStealthConnected] flips it.
  bool _stealthGateHeld = false;

  /// The gated engine's tunnel is up (its CONNECTED event arrived)
  /// but the public state has deliberately not flipped yet.
  bool _gatedTunnelUp = false;

  /// Whether a self-heal ladder is running for a live session.
  /// While true, the attempt machinery's connecting/disconnecting
  /// writes are presented as [VpnState.reconnecting] (see
  /// [_setState]) — the session is being restored, not freshly
  /// connected, and not given up.
  bool _healing = false;

  /// The live attempt log shown on Home during a stealth connect
  /// or heal: one short English line per step, in order ("Trying …",
  /// "… did not answer through the tunnel.", "Connection stable —
  /// connected with …"). Kept for the whole session (success does
  /// not wipe it); cleared when a fresh connect starts and after a
  /// disconnect. Bounded so a long heal history cannot grow it
  /// without limit.
  final List<String> _attemptLog = [];

  /// The attempt log, oldest first. Home renders the last few lines.
  List<String> get attemptLog => List.unmodifiable(_attemptLog);

  static const int _attemptLogCap = 60;

  void _logLine(String line) {
    _attemptLog.add(line);
    if (_attemptLog.length > _attemptLogCap) {
      _attemptLog.removeRange(0, _attemptLog.length - _attemptLogCap);
    }
    notifyListeners();
  }

  void _clearAttemptLog() {
    if (_attemptLog.isEmpty) return;
    _attemptLog.clear();
    notifyListeners();
  }

  /// How to name one attempt's DNS choice inside a log sentence:
  /// the provider's name, or "the default DNS" for the Tier-3
  /// built-in default choice.
  static String _dnsAttemptLabel(DnsProvider dns) =>
      DnsService.isDefaultDns(dns) ? 'the default DNS' : dns.name;

  /// [_dnsAttemptLabel] at the start of a sentence.
  static String _dnsAttemptLabelSentence(DnsProvider dns) {
    final label = _dnsAttemptLabel(dns);
    return label.isEmpty
        ? label
        : '${label[0].toUpperCase()}${label.substring(1)}';
  }

  /// Per-attempt connect deadlines for the stealth flows. The raw
  /// attempt keeps its own longer settle window in the background;
  /// the escalation moves on at these bounds so a dead combination
  /// cannot eat the whole budget. Manual connect: at most 8
  /// attempts (selected + up to 6 measured + default) → a worst
  /// case of roughly three minutes before the winner's
  /// verification and stability gate. Stealth Auto keeps the 12 s
  /// bound its ladder has always used.
  static const _manualAttemptDeadline = Duration(seconds: 20);
  static const _autoAttemptDeadline = Duration(seconds: 12);

  /// Stability gate parameters (see [stabilityGatePassed]): two
  /// further probes through the verified tunnel, spaced a few
  /// seconds apart, both of which must answer with the same exit
  /// address before Connected may be shown.
  static const stabilityProbeCount = 2;
  static const stabilityProbeSpacing = Duration(seconds: 3);

  /// Session watchdog parameters: while a Stealth session is
  /// connected, a cheap through-tunnel liveness probe runs at this
  /// interval; this many consecutive failures declare the tunnel
  /// silently dead and start a self-heal on the same server.
  static const watchdogInterval = Duration(seconds: 25);
  static const watchdogFailureThreshold = 2;

  Timer? _watchdogTimer;
  int _watchdogFailures = 0;
  bool _watchdogProbeInFlight = false;

  /// Test-only seam: replace one stability-gate probe (which needs
  /// a live Xray core) with a stub returning the probe's DNS
  /// verdict and observed exit address.
  @visibleForTesting
  Future<({bool dnsOk, String? exitIp})> Function(DnsProvider dns)?
      debugStabilityProbe;

  /// Test-only seam: replace one watchdog liveness probe with a
  /// stub (true = the session is alive).
  @visibleForTesting
  Future<bool> Function()? debugWatchdogProbe;

  /// Test-only seam: the exit address the stubbed combination
  /// verifier is modelled to have observed (the production
  /// verifier records it in [currentIp] on success).
  @visibleForTesting
  String? debugVerifiedExitIp;

  /// Test-only seam: append one line to the attempt log, as the
  /// connect/heal narration does.
  @visibleForTesting
  void debugAddLogLine(String line) => _logLine(line);

  /// Test-only seam: shrink the stability probe spacing.
  @visibleForTesting
  Duration? debugStabilitySpacing;

  /// Test-only seam: shrink the watchdog interval.
  @visibleForTesting
  Duration debugWatchdogInterval = watchdogInterval;

  /// Test-only: whether the session watchdog timer is running.
  @visibleForTesting
  bool get debugWatchdogRunning => _watchdogTimer != null;

  /// Test-only: whether a self-heal ladder is running.
  @visibleForTesting
  bool get debugHealing => _healing;

  /// Test-only: run one watchdog probe cycle now, exactly as the
  /// watchdog timer does.
  @visibleForTesting
  Future<void> debugWatchdogTick() => _watchdogTick();

  static const _opTimeout = Duration(seconds: 30);
  static const _settleTimeout = Duration(seconds: 40);

  /// UI ke liye chhote naam.
  VpnServer? get server => currentServer;
  String? get exitIp => currentIp;
  String? get lastError => errorMsg;

  /// Live V2Ray traffic counters (bytes / bytes-per-second); zero when
  /// the V2Ray engine has not reported a status yet.
  int get upSpeed => v2rayStatus?.uploadSpeed ?? 0;
  int get downSpeed => v2rayStatus?.downloadSpeed ?? 0;
  int get upTotal => v2rayStatus?.upload ?? 0;
  int get downTotal => v2rayStatus?.download ?? 0;

  void setMode(AppMode m) {
    mode = m;
    notifyListeners();
  }

  /// Custom server ke liye bani local public key - ise apne VPS pe
  /// peer ke roop me add karna hota hai (Settings me dikhegi).
  String? customClientPubKey;

  bool _inited = false;

  /// [wgEngine] is a test-only seam: the event-sequence tests
  /// inject a fake WireGuard engine because the plugin's desktop
  /// implementation shells out to `sudo wg`, which no test host
  /// provides. Production always uses the plugin's real engine.
  VpnController(this.warp, {WireGuardFlutterInterface? wgEngine})
      : _wg = wgEngine ?? WireGuardFlutter.instance {
    _ovpn = OpenVPN(onVpnStageChanged: _onOvpnStage);
    _v2ray = V2ray(onStatusChanged: _onV2rayStatus);
  }

  Future<void> _init() async {
    if (_inited) return;
    await _wg.initialize(interfaceName: 'ipchakra0');
    _wg.vpnStageSnapshot.listen(_onStage);
    if (_isAndroid) {
      // Dono VPN plugins Android pe hain; Windows pe sirf WireGuard.
      await _ovpn.initialize(
        providerBundleIdentifier: 'com.ipchakra.app',
        localizedDescription: 'IPChakra',
        groupIdentifier: 'group.com.ipchakra.app',
      );
      await _v2ray.initialize(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_launcher',
      );
    }
    _inited = true;
  }

  // ── native callbacks ────────────────────────────────────────────

  /// V2Ray engine ke status events (state: CONNECTED / CONNECTING / DISCONNECTED).
  void _onV2rayStatus(V2RayStatus status) {
    // Traffic/status data always updates; state transitions are
    // scoped to the active engine, so a stale event from an engine
    // that is not connecting cannot poison the live attempt.
    v2rayStatus = status;
    if (!_honorEngineEvent('v2ray')) return;
    switch (status.state.toUpperCase()) {
      case 'CONNECTED':
        _markConnected();
        break;
      case 'CONNECTING':
      case 'STARTING':
        // Only while an attempt is live — a stale event after
        // disconnect must not resurrect the connecting state.
        if (shouldHonorConnectingEvent(state)) {
          _setState(VpnState.connecting);
        }
        break;
      case 'DISCONNECTED':
      case 'STOPPED':
        _onEngineDisconnected('v2ray', 'V2Ray server se connect nahi ho paya.');
        break;
      default:
        break;
    }
  }

  void _onStage(dynamic event) {
    // State transitions are scoped to the active engine (WireGuard).
    if (!_honorEngineEvent('wireguard')) return;
    // wireguard_flutter VpnStage enum bhejta hai, jaise 'VpnStage.connected'.
    final raw = event.toString();
    final s = raw.contains('.') ? raw.split('.').last : raw;
    switch (s) {
      case 'connected':
        _markConnected();
        break;
      case 'connecting':
      case 'preparing':
      case 'authenticating':
      case 'waitingConnection':
      case 'reconnect':
        if (shouldHonorConnectingEvent(state)) {
          _setState(VpnState.connecting);
        }
        break;
      case 'disconnecting':
        if (state != VpnState.disconnected) _setState(VpnState.disconnecting);
        break;
      case 'denied':
        _fail('System ne VPN permission deny kar di.');
        break;
      case 'disconnected':
      case 'noConnection':
      case 'exiting':
        _onEngineDisconnected(
            'wireguard', 'WireGuard tunnel establish nahi hua.');
        break;
      default:
        break;
    }
  }

  /// OpenVPN engine ke stage events.
  void _onOvpnStage(VPNStage stage, String rawStage) {
    // State transitions are scoped to the active engine (OpenVPN).
    if (!_honorEngineEvent('openvpn')) return;
    switch (stage) {
      case VPNStage.connected:
        _markConnected();
        break;
      case VPNStage.connecting:
      case VPNStage.prepare:
      case VPNStage.authenticating:
      case VPNStage.authentication:
      case VPNStage.wait_connection:
      case VPNStage.vpn_generate_config:
      case VPNStage.get_config:
      case VPNStage.tcp_connect:
      case VPNStage.udp_connect:
      case VPNStage.assign_ip:
      case VPNStage.resolve:
        // Stale/transitional events after disconnect are ignored.
        if (shouldHonorConnectingEvent(state)) {
          _setState(VpnState.connecting);
        }
        break;
      case VPNStage.disconnecting:
        if (state != VpnState.disconnected) _setState(VpnState.disconnecting);
        break;
      case VPNStage.denied:
        _fail('System ne VPN permission deny kar di.');
        break;
      case VPNStage.error:
        _fail('OpenVPN connect nahi ho paya. Koi aur server try karo.');
        break;
      case VPNStage.disconnected:
        _onEngineDisconnected(
            'openvpn', 'Server ne connection kaat di. Koi aur server try karo.');
        break;
      default:
        break;
    }
  }

  /// When the current connecting attempt began; null unless the
  /// state is connecting. The reconciliation's stale-attempt net
  /// measures the attempt's age from this.
  DateTime? _connectingSince;

  void _setState(VpnState s) {
    // While a self-heal is running, the escalation ladder drives
    // the same attempt machinery as a fresh connect; its
    // connecting/disconnecting writes — and the disconnected
    // write of its internal between-attempt teardowns — are
    // presented as [VpnState.reconnecting] so the UI keeps saying
    // "this live session is being restored" instead of flickering
    // through fresh-connect states. Every path that ENDS a heal
    // clears _healing before its own final state write (the heal
    // ladder when it gives up, a user disconnect, a native stop),
    // and the success write (connected) and failure write (error)
    // are never remapped, so a terminal state is never masked.
    var effective = s;
    if (_healing &&
        (s == VpnState.connecting ||
            s == VpnState.disconnecting ||
            s == VpnState.disconnected)) {
      effective = VpnState.reconnecting;
    }
    if (effective == VpnState.connecting &&
        state != VpnState.connecting) {
      _connectingSince = DateTime.now();
    } else if (effective != VpnState.connecting) {
      _connectingSince = null;
    }
    state = effective;
    notifyListeners();
  }

  /// A native "connected" event arrived — set the timer and state
  /// together. (Previously the callback set the state but connectedAt
  /// stayed null, so the session timer showed a dash.)
  ///
  /// Guarded by [shouldHonorConnectedEvent]: engines keep emitting
  /// status events after the user disconnects (the V2Ray plugin's
  /// periodic traffic ticks carry CONNECTED), and an unguarded event
  /// resurrects the UI to "Connected" over a tunnel that is already
  /// down. Stale events are ignored entirely.
  void _markConnected() {
    // Stealth resilience gate (v2.2.0): while a stealth flow holds
    // the gate, the engine's CONNECTED event proves only that a
    // tunnel exists — not that it carries traffic, and not that it
    // will still be alive when the user opens a site. Record the
    // tunnel as up for the attempt machinery and let verification
    // plus the stability gate decide; the public state must not
    // flip to Connected here. (The event still supersedes pending
    // stop echoes for the engine, exactly as below.)
    if (_stealthGateHeld && _activeEngine == 'v2ray') {
      if (currentServer == null) return;
      _selfStopEchoes.remove('v2ray');
      _gatedTunnelUp = true;
      notifyListeners();
      return;
    }
    if (!shouldHonorConnectedEvent(state, currentServer != null)) return;
    // A live tunnel supersedes every pending stop echo for its
    // engine: from here on, a DISCONNECTED from this engine is
    // genuine news (an external stop or a real drop), never an
    // echo of a stop issued before this session came up. This is
    // what keeps a settled session's notification stop working
    // even though earlier connects issued stops of their own.
    final engine = _activeEngine;
    if (engine != null) _selfStopEchoes.remove(engine);
    connectedAt ??= DateTime.now();
    _setState(VpnState.connected);
    unawaited(_refreshIp());
  }

  /// Test-only seam: simulate a native "connected" event arriving
  /// from any engine, exactly as the native callbacks deliver it.
  @visibleForTesting
  void debugHandleNativeConnectedEvent() => _markConnected();

  void _fail(String msg) {
    _stopWatchdog();
    errorMsg = msg;
    // A failed attempt has no live session, so it has no DNS in
    // use either — never leave a previous session's provider
    // recorded behind an error state.
    effectiveDns = null;
    _setState(VpnState.error);
  }

  String _short(Object e) {
    if (e is TimeoutException) return 'Server se jawab nahi aaya (timeout).';
    final s = e.toString().replaceFirst('Exception: ', '');
    return s.length > 140 ? '${s.substring(0, 140)}…' : s;
  }

  // ── connect / disconnect ────────────────────────────────────────

  /// Connect to [server]. Stealth (V2Ray) servers go through the
  /// verified (server, DNS) combination flow — a stealth tunnel is
  /// only ever reported connected after real traffic and real name
  /// resolution have been proven through it. Every other engine
  /// connects directly, exactly as before.
  Future<void> connect(VpnServer server) async {
    // A fresh user connect is a new intent: any stealth search loop
    // still running from an earlier tap aborts at its next check.
    ++_autoSession;
    // A fresh connect starts a fresh attempt log.
    _clearAttemptLog();
    if (server.protocol == 'v2ray') {
      await _connectStealthVerified(server);
      return;
    }
    await _connectOnce(server);
  }

  /// One raw connect attempt with no DNS combination logic.
  /// Returns true when the attempt reached the connected state.
  Future<bool> _connectOnce(VpnServer server) async {
    final myAttempt = ++_attempt;
    // No engine is active while the previous tunnels are torn down:
    // their stop events are ignored instead of failing this attempt.
    // The engine being started claims the slot in its connect path.
    _activeEngine = null;
    try {
      await _init().timeout(const Duration(seconds: 20));
    } catch (e) {
      if (_isCurrent(myAttempt)) _fail('VPN engine start nahi hua: ${_short(e)}');
      return false;
    }
    if (!_isCurrent(myAttempt)) return false;

    // Pichla tunnel (agar aadha-adhoora hai) bina hang ke band karo.
    _setState(VpnState.disconnecting);
    await _stopAllEngines();
    if (!_isCurrent(myAttempt)) return false;

    currentServer = server;
    errorMsg = null;
    customClientPubKey = null;
    connectedAt = null;
    effectiveDns = null;
    _setState(VpnState.connecting);

    // Verify ke liye connect se pehle wala IP.
    final ipBefore = await _safeIp();
    _lastBaselineIp = ipBefore;

    try {
      await _startEngine(server).timeout(_opTimeout);
    } catch (e) {
      await _stopAllEngines();
      if (_isCurrent(myAttempt)) {
        _fail('Connect nahi ho paya: ${_short(e)} Doosra server try karo.');
      }
      return false;
    }
    if (!_isCurrent(myAttempt)) return false;

    // WireGuard (WARP): startVpn return == tunnel up (purana working behavior,
    // instant). OpenVPN/V2Ray: callback / poll / IP-verify ka intezaar.
    if (_activeEngine == 'wireguard') {
      _markConnected();
      return true;
    }

    final ok = await _waitForConnected(myAttempt, ipBefore);
    if (!_isCurrent(myAttempt)) return false;
    if (ok) {
      _markConnected();
      return true;
    }
    await _stopAllEngines();
    if (_isCurrent(myAttempt)) {
      _fail('Server se connect nahi ho paya. Doosra server try karo.');
    }
    return false;
  }

  /// Verify the live tunnel for one (server, DNS) combination
  /// through the core's SOCKS inbound: a real DNS answer from the
  /// combination's resolver AND a real hostname fetch returning the
  /// tunnel's exit address. See [comboVerified] for the gate.
  Future<bool> _verifyCombination(DnsProvider dns) async {
    final verifierOverride = debugComboVerifier;
    if (verifierOverride != null) {
      final ok = await verifierOverride(dns);
      // Model the production verifier's side effect — recording
      // the tunnel exit it observed — when a test provides one, so
      // the stability gate's exit-stability check has something
      // real to compare against.
      if (ok && debugVerifiedExitIp != null) {
        currentIp = debugVerifiedExitIp;
      }
      return ok;
    }
    try {
      final result = await TunnelVerifier.verify(resolverIp: dns.primary)
          .timeout(const Duration(seconds: 8));
      final ok = comboVerified(
        dnsOk: result.dnsOk,
        fetchOk: result.exitIp != null,
        tunnelIp: result.exitIp,
        baselineIp: _lastBaselineIp,
      );
      if (ok) currentIp = result.exitIp;
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// One stability-gate probe through the live tunnel: a DNS
  /// answer via the combination's resolver plus an exit-address
  /// fetch — the same checks as verification, run again after a
  /// pause. Through the test seams when they are installed.
  Future<({bool dnsOk, String? exitIp})> _stabilityProbe(
    DnsProvider dns,
    String? verifiedExitIp,
  ) async {
    final seam = debugStabilityProbe;
    if (seam != null) return seam(dns);
    if (debugComboVerifier != null) {
      // Only the combination verifier is stubbed (the pre-v2.2.0
      // test harness): a combination that verifies is modelled as
      // stable. A test that models an unstable combination
      // installs [debugStabilityProbe] explicitly.
      return (dnsOk: true, exitIp: verifiedExitIp);
    }
    try {
      final result = await TunnelVerifier.verify(resolverIp: dns.primary)
          .timeout(const Duration(seconds: 8));
      return (dnsOk: result.dnsOk, exitIp: result.exitIp);
    } catch (_) {
      return (dnsOk: false, exitIp: null);
    }
  }

  /// Run the stability gate for a just-verified combination:
  /// [stabilityProbeCount] further probes, spaced apart, all of
  /// which must answer through the tunnel with the verification's
  /// own exit address (see [stabilityGatePassed]).
  Future<bool> _passesStabilityGate({
    required DnsProvider dns,
    required String? verifiedExitIp,
    required bool Function() alive,
  }) async {
    final probes = <({bool dnsOk, String? exitIp})>[];
    for (var i = 0; i < stabilityProbeCount; i++) {
      await Future.delayed(debugStabilitySpacing ?? stabilityProbeSpacing);
      if (!alive()) return false;
      probes.add(await _stabilityProbe(dns, verifiedExitIp));
      if (!probes.last.dnsOk) break; // the gate fails on length alone
    }
    return stabilityGatePassed(
      probes: probes,
      verifiedExitIp: verifiedExitIp,
      requiredProbes: stabilityProbeCount,
    );
  }

  /// Whether the in-flight attempt's tunnel is up: either the
  /// public state already flipped (ungated engines), or the engine
  /// reported CONNECTED while the stealth gate holds the claim.
  bool _attemptTunnelUp(VpnServer server) =>
      currentServer?.id == server.id &&
      (state == VpnState.connected ||
          (_stealthGateHeld && _gatedTunnelUp));

  /// The one place a gated stealth session becomes Connected: the
  /// combination passed verification AND the stability gate, the
  /// success line is already in the log, so flip the state, record
  /// the DNS that is actually carrying the session, and arm the
  /// session watchdog. [connectedAt] is only set when unset — a
  /// self-healed session keeps its original start time, because
  /// the session itself never ended.
  void _confirmStealthConnected(DnsProvider dns) {
    _stealthGateHeld = false;
    _gatedTunnelUp = false;
    effectiveDns = dns;
    connectedAt ??= DateTime.now();
    _setState(VpnState.connected);
    _startWatchdog();
  }

  /// The honest note shown when a session connected with a DNS
  /// other than the user's selected provider.
  String _fallbackNote(
    DnsProvider dns,
    DnsProvider selected, {
    required bool manual,
  }) {
    final where = manual ? 'with this server' : 'on this network';
    if (DnsService.isDefaultDns(dns)) {
      return 'Connected with the default DNS because the selected '
          'DNS (${selected.name}) did not work $where.';
    }
    // Provider names that already end in "DNS" ("Google Public
    // DNS") take no suffix; the rest read naturally with one.
    final winner =
        dns.name.endsWith('DNS') ? dns.name : '${dns.name} DNS';
    return 'Connected with $winner because the selected DNS '
        '(${selected.name}) did not work $where.';
  }

  /// One gated stealth attempt: start (server, [dns]) behind the
  /// gate, wait for its tunnel within [deadline], verify it through
  /// the tunnel, then hold it to the stability gate. Returns true
  /// only when the session is now Connected with this combination
  /// (the success line is logged BEFORE the state flips). Every
  /// failure is logged in plain English and the attempt is torn
  /// down cleanly; an abort (the user's intent moved on, per
  /// [alive]) returns false silently. [note], when given, becomes
  /// the status pill text for the attempt's duration; [heal]
  /// selects the heal wording for the success line.
  Future<bool> _attemptStealthCombo({
    required VpnServer server,
    required DnsProvider dns,
    required bool Function() alive,
    required Duration deadline,
    required bool heal,
    String? note,
  }) async {
    final label = _dnsAttemptLabel(dns);
    _dnsOverride = dns;
    _gatedTunnelUp = false;
    if (note != null) _setStatusNote(note);
    _logLine('Trying ${server.name} with $label…');

    // Start the raw connect flow without awaiting it to completion
    // (mirrors the Stealth Auto ladder): its own bookkeeping runs
    // under the attempt counter, and the wrapper's teardown cancels
    // it if this attempt is given up on.
    final f = _connectOnce(server);
    unawaited(f.then((_) {}, onError: (_) {}));

    final watch = Stopwatch()..start();
    var up = false;
    while (watch.elapsed < deadline) {
      // The user's disconnect wins instantly, not at the deadline.
      if (!alive()) return false;
      if (_attemptTunnelUp(server)) {
        up = true;
        break;
      }
      // Fail fast on a real error from this attempt. Errors are
      // only trusted after a short grace period so a stale error
      // state from a previous attempt cannot abort this one
      // instantly.
      if (state == VpnState.error &&
          watch.elapsed > const Duration(milliseconds: 1500)) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 250));
    }
    if (!up && _attemptTunnelUp(server)) up = true;
    if (!alive()) return false;

    if (!up) {
      _logLine('The tunnel did not come up with $label.');
      await _disconnect(userIntent: false);
      return false;
    }
    if (!await _verifyCombination(dns)) {
      if (!alive()) return false;
      _logLine(
          '${_dnsAttemptLabelSentence(dns)} did not answer through the tunnel.');
      await _disconnect(userIntent: false);
      return false;
    }
    if (!alive()) return false;

    // Verified — but a tunnel that dies seconds later is worse
    // than no tunnel (it invites the user to browse unprotected
    // under a "Connected" claim), so hold the claim until the
    // combination also proves it can stay up.
    final verifiedExitIp = currentIp;
    _logLine('Tunnel verified with $label. Checking stability…');
    final stable = await _passesStabilityGate(
      dns: dns,
      verifiedExitIp: verifiedExitIp,
      alive: alive,
    );
    if (!alive()) return false;
    if (!stable) {
      _logLine('The tunnel with $label did not stay stable.');
      await _disconnect(userIntent: false);
      return false;
    }

    // Narrate first, then connect: the log's final line precedes
    // the state flip it announces.
    _logLine(heal
        ? 'Reconnected with $label.'
        : 'Connection stable — connected with $label.');
    _confirmStealthConnected(dns);
    return true;
  }

  /// Manual stealth connect: the server is the user's pick and
  /// never changes; the DNS escalates until a combination holds —
  /// Tier 1 the selected provider, Tier 2 the other answering
  /// providers in measured speed order, Tier 3 the built-in
  /// default DNS treatment (see [manualEscalationAttempts]).
  /// "Connected" is declared only for a combination that passed
  /// verification and the stability gate.
  Future<void> _connectStealthVerified(VpnServer server) async {
    // Capture the operation session: if the user disconnects or
    // starts a different connect while this search runs, the token
    // moves on and this loop aborts at its next check — silently,
    // because the user's action owns the state from then on.
    final session = ++_autoSession;
    _autoRunningSession = session;
    bool alive() =>
        autoShouldContinue(session: session, currentSession: _autoSession);
    // The gate is held for the whole escalation: no attempt may
    // show Connected before its verification + stability gate.
    _stealthGateHeld = true;
    try {
      final selected = await DnsService.loadSelected();
      if (!alive()) return;
      dnsFallbackNote = null;
      _setStatusNote('Finding the fastest DNS + server…');
      final measured = await _measureProviders();
      if (!alive()) return;
      final attempts =
          manualEscalationAttempts(selected: selected, measured: measured);
      for (final dns in attempts) {
        if (!alive()) return;
        final connected = await _attemptStealthCombo(
          server: server,
          dns: dns,
          alive: alive,
          deadline: _manualAttemptDeadline,
          heal: false,
          note: 'Trying ${server.name} with ${_dnsAttemptLabel(dns)}…',
        );
        if (!alive()) return;
        if (connected) {
          if (dns.id != selected.id) {
            dnsFallbackNote = _fallbackNote(dns, selected, manual: true);
          }
          _dnsOverride = null;
          _setStatusNote(null);
          return;
        }
      }
      if (!alive()) return;
      _dnsOverride = null;
      _setStatusNote(null);
      _fail('This server could not be kept connected — not with the '
          'selected DNS, not with any other measured DNS, and not '
          'with the default DNS. Please try another server.');
    } finally {
      _stealthGateHeld = false;
      _gatedTunnelUp = false;
      if (_autoRunningSession == session) _autoRunningSession = null;
    }
  }

  /// User-initiated disconnect: cancels any in-flight connect
  /// attempt AND any running stealth search loop.
  Future<void> disconnect() => _disconnect(userIntent: true);

  /// Shared teardown. [userIntent] is true only for a real user
  /// disconnect (or an equivalent fresh intent): it moves the
  /// operation-session token, which is what stops a stealth search
  /// loop at its next check. The loops' own between-attempts cleanup
  /// passes false — cancelling itself would be a bug of its own.
  Future<void> _disconnect({required bool userIntent}) async {
    ++_attempt; // any in-flight connect attempt is cancelled
    if (userIntent) ++_autoSession; // any stealth search loop aborts
    _stopWatchdog();
    if (userIntent) {
      // A user disconnect ends everything, including a running
      // self-heal and the attempt log it was writing. Internal
      // between-attempt teardowns (userIntent false) touch
      // neither: the loop that owns them is still in charge.
      _healing = false;
      _clearAttemptLog();
    }
    _setState(VpnState.disconnecting);
    // Clear the session BEFORE stopping the engines: a native
    // callback racing the stop then sees no active server, and its
    // "connected" event is ignored by the _markConnected guard
    // instead of resurrecting the session.
    currentServer = null;
    currentIp = null;
    connectedAt = null;
    effectiveDns = null;
    // The disconnect owns the UI now: clear the search bookkeeping
    // so no stale progress or fallback note survives it.
    _dnsOverride = null;
    statusNote = null;
    dnsFallbackNote = null;
    await _stopAllEngines();
    _activeEngine = null;
    _setState(VpnState.disconnected);
  }

  /// Shared routing for a DISCONNECTED-style event from [engine]
  /// (already engine-scoped by the caller via [_honorEngineEvent]).
  /// A native stop — the user stopped the VPN from the notification,
  /// Android Settings, or a quick-settings tile, which also covers
  /// the system revoking the VPN — is honoured exactly like an
  /// in-app disconnect via [_handleNativeStopped]; it must never
  /// surface as an error and never let a search continue. Any other
  /// disconnect during a manual connect keeps the existing failure
  /// semantics ([failureMessage]).
  void _onEngineDisconnected(String engine, String failureMessage) {
    // Provenance first: if this controller itself stopped the
    // engine and the resulting echo has not been delivered yet,
    // this event IS that echo. It says nothing about the live
    // attempt — consume it and change nothing. (Without this, a
    // late echo was read as an external native stop and cancelled
    // a running search, or failed a healthy attempt: the v2.1.3
    // Stealth Auto churn and WARP first-tap failure.)
    if (_consumeSelfStopEcho(engine)) return;
    if (isNativeStopEvent(
      state: state,
      searchRunning: _autoRunningSession != null,
    )) {
      unawaited(_handleNativeStopped(engine));
    } else if (state == VpnState.connecting) {
      _fail(failureMessage);
    } else if (state != VpnState.error && state != VpnState.disconnected) {
      _setState(VpnState.disconnected);
    }
  }

  /// Ground-truth reconciliation, run when the app starts and
  /// every time it returns to the foreground. If the controller
  /// believes a session is live (connected, or an attempt is in
  /// flight) it asks the active engine — synchronously, not via
  /// cached events — whether its tunnel actually exists, and if
  /// the native side verifiably has no tunnel it runs the
  /// native-stop teardown. This is the hard guarantee behind the
  /// v2.1.2 S25 fix: pushed status events can be missed (the V2Ray
  /// plugin's disconnected broadcast could be swallowed by its own
  /// stop path), so the UI's "Connected" claim is re-proven
  /// against the native truth at every foregrounding and can never
  /// survive a dead tunnel.
  Future<void> reconcileNativeState() async {
    if (state != VpnState.connected && state != VpnState.connecting) {
      return;
    }
    final engine = _activeEngine;
    if (engine == null) return;
    final attemptAtStart = _attempt;
    final native = await _queryNativeStatus(engine);
    // The world may have moved on while the query was in flight —
    // a new attempt, a user disconnect, or an engine switch all
    // make the answer stale; the newer flow owns the state then.
    if (_attempt != attemptAtStart || _activeEngine != engine) return;
    if (state != VpnState.connected && state != VpnState.connecting) {
      return;
    }
    final action = reconcileAction(
      appState: state,
      native: native,
      searchRunning: _autoRunningSession != null,
      connectingFor: _connectingSince == null
          ? Duration.zero
          : DateTime.now().difference(_connectingSince!),
    );
    if (action == ReconcileAction.teardownToDisconnected) {
      await _handleNativeStopped(engine);
    }
  }

  /// One engine's real current status, from whatever synchronous
  /// query its plugin exposes. Any failure to decide — including
  /// the engine never having been initialised in this process —
  /// is [NativeTunnelStatus.unknown], which the reconciliation
  /// treats as "no evidence", never as "down".
  Future<NativeTunnelStatus> _queryNativeStatus(String engine) async {
    try {
      switch (engine) {
        case 'v2ray':
          // No platform gate needed: the V2Ray engine can only be
          // the active engine on Android (its connect path throws
          // elsewhere), and a failed query reads as unknown anyway.
          final s = await _v2ray
              .getConnectionState()
              .timeout(const Duration(seconds: 5));
          switch (s) {
            case 'V2RAY_CONNECTED':
              return NativeTunnelStatus.up;
            case 'V2RAY_DISCONNECTED':
              return NativeTunnelStatus.down;
            default:
              return NativeTunnelStatus.unknown;
          }
        case 'wireguard':
          final stage =
              await _wg.stage().timeout(const Duration(seconds: 5));
          switch (stage) {
            case VpnStage.connected:
              return NativeTunnelStatus.up;
            case VpnStage.disconnected:
            case VpnStage.noConnection:
              return NativeTunnelStatus.down;
            default:
              return NativeTunnelStatus.unknown;
          }
        case 'openvpn':
          final up =
              await _ovpn.isConnected().timeout(const Duration(seconds: 5));
          return up ? NativeTunnelStatus.up : NativeTunnelStatus.down;
        default:
          return NativeTunnelStatus.unknown;
      }
    } catch (_) {
      return NativeTunnelStatus.unknown;
    }
  }

  /// Teardown for a native-side stop: identical in effect to a user
  /// disconnect. Both generation counters move — the attempt counter
  /// cancels any in-flight attempt bookkeeping and the session token
  /// aborts a running stealth search at its next check — the session
  /// fields are cleared, every engine is stopped (stopping the one
  /// that already stopped is a native no-op), and the state settles
  /// at disconnected. This path never raises an error and never
  /// starts anything.
  Future<void> _handleNativeStopped(String engine) async {
    ++_attempt;
    ++_autoSession;
    // A native stop is a full stop — identical to a user
    // disconnect. The watchdog stops and no self-heal may follow:
    // healing exists only for tunnels that died silently (failed
    // probes), never for a stop the native layer reported.
    _stopWatchdog();
    _healing = false;
    _clearAttemptLog();
    currentServer = null;
    currentIp = null;
    connectedAt = null;
    effectiveDns = null;
    _dnsOverride = null;
    statusNote = null;
    dnsFallbackNote = null;
    _setState(VpnState.disconnecting);
    await _stopAllEngines();
    _activeEngine = null;
    if (state == VpnState.disconnecting) {
      _setState(VpnState.disconnected);
    }
  }

  // ── session watchdog + self-heal (v2.2.0) ─────────────────────

  /// Arm the session watchdog for a live Stealth session. Called
  /// only from [_confirmStealthConnected]; every teardown path
  /// stops it (see [_stopWatchdog] call sites), so it can never
  /// outlive the session it watches.
  void _startWatchdog() {
    _stopWatchdog();
    if (_activeEngine != 'v2ray') return;
    _watchdogFailures = 0;
    _watchdogTimer = Timer.periodic(
      debugWatchdogInterval,
      (_) => unawaited(_watchdogTick()),
    );
  }

  void _stopWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    _watchdogFailures = 0;
  }

  /// One watchdog probe cycle. Only ever acts on a session that is
  /// fully Connected on the V2Ray engine with no heal running —
  /// every other state owns its own outcome.
  Future<void> _watchdogTick() async {
    if (_watchdogProbeInFlight) return;
    if (state != VpnState.connected ||
        _activeEngine != 'v2ray' ||
        _healing ||
        currentServer == null) {
      return;
    }
    _watchdogProbeInFlight = true;
    try {
      final ok = await _probeSessionLiveness();
      // The world may have moved on while the probe ran — a user
      // disconnect, a native stop (which tears down on its own
      // path and must never be healed), or a heal already started.
      if (state != VpnState.connected || _healing) return;
      if (ok) {
        _watchdogFailures = 0;
        return;
      }
      _watchdogFailures++;
      if (_watchdogFailures >= watchdogFailureThreshold) {
        _watchdogFailures = 0;
        unawaited(_healStealthSession());
      }
    } finally {
      _watchdogProbeInFlight = false;
    }
  }

  /// Whether the live session still carries traffic, proven
  /// through the tunnel's own SOCKS path (see [TunnelVerifier]):
  /// a DNS answer from the session's resolver AND an exit-address
  /// fetch. An exit address that merely CHANGED is not death (the
  /// exit node may have re-resolved); the recorded address simply
  /// follows it.
  Future<bool> _probeSessionLiveness() async {
    final seam = debugWatchdogProbe;
    if (seam != null) return seam();
    if (debugComboVerifier != null || debugStabilityProbe != null) {
      // Test harness with tunnel stubs installed: the session is
      // modelled alive unless a watchdog stub says otherwise.
      return true;
    }
    final dns = effectiveDns ?? DnsService.defaultDns;
    try {
      final result = await TunnelVerifier.verify(resolverIp: dns.primary)
          .timeout(const Duration(seconds: 10));
      if (!result.dnsOk || result.exitIp == null) return false;
      if (currentIp != null && result.exitIp != currentIp) {
        currentIp = result.exitIp;
        notifyListeners();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Restore a silently dead Stealth session on the SAME server:
  /// the [VpnState.reconnecting] presentation goes up, and the
  /// escalation ladder runs again for that server — the DNS that
  /// was working when the session dropped first, then the standard
  /// manual order (selected, measured alternatives, default).
  ///
  /// The heal-vs-stop distinction is the design's spine and is
  /// structural, not timed: this method is reachable ONLY from the
  /// watchdog after consecutive failed probes, in a state where
  /// the native layer has NOT reported a stop. A reported stop
  /// routes through [_handleNativeStopped] instead — full teardown,
  /// watchdog stopped, this ladder never starts, and the session
  /// token bump aborts this ladder if one is already running. The
  /// ladder itself runs under the operation-session token, so the
  /// user's own disconnect at any moment cancels it like any
  /// search.
  Future<void> _healStealthSession() async {
    final server = currentServer;
    if (server == null ||
        state != VpnState.connected ||
        _healing ||
        _autoRunningSession != null) {
      return;
    }
    // Run under the current session token (NOT a new intent): a
    // user disconnect or a fresh connect bumps it and aborts the
    // heal at its next check, exactly like a search.
    final session = _autoSession;
    _autoRunningSession = session;
    bool alive() =>
        autoShouldContinue(session: session, currentSession: _autoSession);
    _healing = true;
    _stealthGateHeld = true;
    _stopWatchdog();
    // The session's start time belongs to the session, not to any
    // single tunnel incarnation: internal teardowns between heal
    // attempts clear it, so keep it here and put it back on
    // success — a healed session's timer keeps counting from the
    // original connect.
    final sessionStartedAt = connectedAt;
    _setState(VpnState.reconnecting);
    _setStatusNote('Reconnecting to ${server.name}…');
    _logLine('Connection lost. Reconnecting to ${server.name}…');
    try {
      final lastDns = effectiveDns;
      final selected = await DnsService.loadSelected();
      if (!alive()) return;
      final measured = await _measureProviders();
      if (!alive()) return;
      final order = <DnsProvider>[
        ?lastDns,
        ...manualEscalationAttempts(selected: selected, measured: measured)
            .where((p) => p.id != lastDns?.id),
      ];
      for (final dns in order) {
        if (!alive()) return;
        final connected = await _attemptStealthCombo(
          server: server,
          dns: dns,
          alive: alive,
          deadline: _manualAttemptDeadline,
          heal: true,
        );
        if (!alive()) return;
        if (connected) {
          _dnsOverride = null;
          _setStatusNote(null);
          if (sessionStartedAt != null &&
              connectedAt != sessionStartedAt) {
            connectedAt = sessionStartedAt;
            notifyListeners();
          }
          return; // the watchdog was re-armed by the confirm flip
        }
      }
      if (!alive()) return;
      // The ladder is exhausted: the session cannot be restored.
      // Say so honestly and settle at a clean error — never leave
      // a "reconnecting" claim up over nothing.
      _healing = false;
      _dnsOverride = null;
      _setStatusNote(null);
      await _disconnect(userIntent: false);
      _fail('The connection to ${server.name} was lost and could '
          'not be restored. Please reconnect.');
    } finally {
      _healing = false;
      _stealthGateHeld = false;
      _gatedTunnelUp = false;
      if (_autoRunningSession == session) _autoRunningSession = null;
    }
  }

  /// Stealth Auto: find the best (server, DNS) combination and
  /// connect with it — verified end to end.
  ///
  /// The DNS providers are measured first (fast, parallel); the
  /// candidate order is the user's selected provider first when it
  /// answers, otherwise the fastest answering provider, then the
  /// next fastest. Servers keep their incoming order (last-good
  /// first, then health + latency). Combinations are built by
  /// [buildDnsServerCombos] and capped at 6. Each attempt runs
  /// through [_attemptStealthCombo] under the Connected gate: a
  /// ~12 second connect deadline, a real verification through the
  /// tunnel, and the stability gate — "connected" is declared only
  /// for a combination that carried a DNS answer and a hostname
  /// fetch and kept doing so across the gate's probes. If every
  /// combination fails, one Tier-3 attempt on the best candidate
  /// with the default DNS treatment runs before total failure is
  /// declared. Failed combinations are torn down cleanly before
  /// the next one is tried.
  Future<void> connectStealthAuto(List<VpnServer> candidates) async {
    if (candidates.isEmpty) {
      _fail('No stealth servers available yet. '
          'Open the Servers tab and refresh.');
      return;
    }
    // Re-entry guard: a second tap while a search is already running
    // must not start a competing loop — the two would take turns
    // connecting and disconnecting each other's attempts.
    if (_autoRunningSession != null) return;

    // Capture the operation session: a user disconnect (or a fresh
    // connect) moves the token, and this loop then aborts at its
    // next check — immediately and silently, with no further
    // connect, disconnect or state writes of its own.
    final session = ++_autoSession;
    _autoRunningSession = session;
    bool alive() =>
        autoShouldContinue(session: session, currentSession: _autoSession);
    // A fresh search starts a fresh attempt log, and holds the
    // Connected gate for its whole run (see _attemptStealthCombo).
    _clearAttemptLog();
    _stealthGateHeld = true;
    try {
      String? lastGoodId;
      try {
        final prefs = await SharedPreferences.getInstance();
        lastGoodId = prefs.getString('stealth_last_good');
      } catch (_) {
        // Persistence is best-effort; the given order is a fine fallback.
      }
      if (!alive()) return;

      final ordered = <VpnServer>[
        if (lastGoodId != null)
          ...candidates.where((s) => s.id == lastGoodId),
        ...candidates.where((s) => s.id != lastGoodId),
      ];

      dnsFallbackNote = null;
      _setStatusNote('Finding the fastest DNS + server…');
      final selected = await DnsService.loadSelected();
      final measured = await _measureProviders();
      if (!alive()) return;
      final dnsOrdered =
          orderDnsCandidates(selected: selected, measured: measured);
      final combos = buildDnsServerCombos(
        servers: ordered,
        dnsOrdered: dnsOrdered,
        fallbackDns: selected,
      );

      // Shared success bookkeeping for whichever attempt wins:
      // remember the winner for next time and note a DNS fallback
      // honestly.
      Future<void> onConnected(VpnServer server, DnsProvider dns) async {
        if (dns.id != selected.id) {
          dnsFallbackNote = _fallbackNote(dns, selected, manual: false);
        }
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('stealth_last_good', server.id);
        } catch (_) {
          // Remembering the winner is best-effort only.
        }
        _dnsOverride = null;
        _setStatusNote(null);
      }

      for (var i = 0; i < combos.length; i++) {
        if (!alive()) return;
        final (server, dns) = combos[i];
        final connected = await _attemptStealthCombo(
          server: server,
          dns: dns,
          alive: alive,
          deadline: _autoAttemptDeadline,
          heal: false,
          note: 'Trying ${server.name} with ${dns.name} DNS '
              '(${i + 1}/${combos.length})…',
        );
        if (!alive()) return;
        if (connected) {
          await onConnected(server, dns);
          return;
        }
      }

      // Tier 3 (v2.2.0): before declaring total failure, one
      // last-resort attempt on the best candidate with the default
      // DNS treatment — no custom DNS object in the configuration
      // at all. A network that defeats every named resolver can
      // still carry this.
      if (!alive()) return;
      final bestServer = combos.first.$1;
      final connectedDefault = await _attemptStealthCombo(
        server: bestServer,
        dns: DnsService.defaultDns,
        alive: alive,
        deadline: _autoAttemptDeadline,
        heal: false,
        note: 'Trying ${bestServer.name} with the default DNS…',
      );
      if (!alive()) return;
      if (connectedDefault) {
        await onConnected(bestServer, DnsService.defaultDns);
        return;
      }

      if (!alive()) return;
      _dnsOverride = null;
      _setStatusNote(null);
      _fail('No working server and DNS combination was found '
          '(${combos.length + 1} combinations tried, including the '
          'default DNS). This network may be blocking the available '
          'methods — try again later or pick a server manually.');
    } finally {
      _stealthGateHeld = false;
      _gatedTunnelUp = false;
      if (_autoRunningSession == session) _autoRunningSession = null;
    }
  }

  /// Teeno engines ko roko. Har ek pe timeout hai — koi bhi native
  /// call kabhi hang nahi karegi, chahe engine aadhi state me ho.
  Future<void> _stopAllEngines() async {
    // Every stop issued here makes its engine emit a
    // DISCONNECTED-style event. Record the stops BEFORE issuing
    // them, so those echoes are recognised as self-stops whenever
    // they are delivered — even if delivery only happens after a
    // later attempt has already claimed the engine (see
    // _onEngineDisconnected).
    _noteSelfStop('openvpn');
    _noteSelfStop('v2ray');
    _noteSelfStop('wireguard');
    try {
      _ovpn.disconnect(); // void — fire and forget
    } catch (_) {}
    try {
      await _v2ray.stopV2Ray().timeout(const Duration(seconds: 6));
    } catch (_) {}
    try {
      await _wg.stopVpn().timeout(const Duration(seconds: 6));
    } catch (_) {}
    // native ko saans lene do
    await Future.delayed(const Duration(milliseconds: 400));
  }

  /// Tunnel up hua ya nahi — callback ka intezaar + backup verify.
  Future<bool> _waitForConnected(int myAttempt, String? ipBefore) async {
    final deadline = DateTime.now().add(_settleTimeout);
    var lastProbe = DateTime.now().subtract(const Duration(seconds: 30));
    while (_isCurrent(myAttempt)) {
      if (state == VpnState.connected) return true;
      // Gated stealth attempt: the engine reported its tunnel up
      // and the gate is holding the public claim — that is this
      // wait's success (verification decides what happens next).
      if (_stealthGateHeld && _gatedTunnelUp) return true;
      if (state == VpnState.error || state == VpnState.disconnected) {
        return false;
      }
      if (DateTime.now().isAfter(deadline)) break;
      // Har ~8s me backup probe (callback miss ho gaya ho to).
      if (DateTime.now().difference(lastProbe).inSeconds >= 8) {
        lastProbe = DateTime.now();
        if (await _probeConnected(ipBefore)) return true;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    // Aakhri verify (bug: tunnel up hai par callback nahi aaya).
    return _isCurrent(myAttempt) && await _probeConnected(ipBefore);
  }

  /// Native se poochho: tunnel sach me up hai?
  Future<bool> _probeConnected(String? ipBefore) async {
    try {
      if (_activeEngine == 'openvpn') {
        if (await _ovpn.isConnected().timeout(const Duration(seconds: 5))) {
          return true;
        }
      }
      // WireGuard/V2Ray ke liye ground truth: exit IP badla ya nahi.
      final ip = await _safeIp();
      if (ip != null && ipBefore != null && ip != ipBefore) return true;
    } catch (_) {}
    return false;
  }

  Future<String?> _safeIp() async {
    try {
      return await fetchExitIp().timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    }
  }

  // ── engines ─────────────────────────────────────────────────────

  Future<void> _startEngine(VpnServer server) async {
    if (server.protocol == 'openvpn') {
      await _connectOvpn(server);
      return;
    }
    if (server.protocol == 'v2ray') {
      await _connectV2ray(server);
      return;
    }
    await _connectWireGuard(server);
  }

  /// VPNGate / VPNBook / Mirror se OpenVPN connect.
  ///
  /// IMPORTANT: openvpn_flutter ke native "connect" me result.success() call
  /// nahi hai — isliye iska Future kabhi complete nahi hota! Await karoge to
  /// hamesha hang. Fire-and-forget karo; success/failure stage callback +
  /// watchdog se aata hai.
  Future<void> _connectOvpn(VpnServer server) async {
    // Claim the engine slot first, before any await that could let
    // another engine's event interleave into this attempt.
    _activeEngine = 'openvpn';
    if (!_isAndroid) {
      throw Exception(
          'OpenVPN servers Windows pe abhi supported nahi hain. Free Mode (WARP) use karo.');
    }
    var config = server.ovpnConfig;
    // VPNBook/Mirror ka config on-demand aata hai.
    config ??= await server.configLoader?.call();
    if (config == null || config.isEmpty || !config.contains('<ca>')) {
      throw Exception('Is server ka OpenVPN config nahi mila.');
    }
    // Credentials plugin ke documented username/password params se jaate hain.
    // VPNGate: vpn/vpn. VPNBook: vpnbook + weekly password (server object me).
    // Mirror: auth nahi chahiye. (VPNBook config me inline creds bhi embedded
    // hain — backup.)
    final isVpnGate = server.source == 'vpngate';
    try {
      // Await MAT karo — native result.success() kabhi nahi bhejta.
      unawaited(_ovpn
          .connect(
            config,
            'IPChakra',
            username: server.authUsername ??
                (isVpnGate ? VpnGateService.username : null),
            password: server.authPassword ??
                (isVpnGate ? VpnGateService.password : null),
            certIsRequired: true,
          )
          .then((_) {}, onError: (_) {
        // Late async error — stage callback isko report kar chuka hoga.
      }));
    } catch (e) {
      // Synchronous throw (jaise "not initialized")
      throw Exception('OpenVPN start nahi hua: ${_short(e)}');
    }
  }

  /// V2Ray/Xray se connect (free ss links).
  Future<void> _connectV2ray(VpnServer server) async {
    // Claim the engine slot first, before any await (see _connectOvpn).
    _activeEngine = 'v2ray';
    if (!_isAndroid) {
      throw Exception(
          'V2Ray servers Windows pe abhi supported nahi hain. Free Mode (WARP) use karo.');
    }
    final link = server.shareLink;
    if (link == null || link.isEmpty) {
      throw Exception('Is server ka link nahi mila.');
    }
    final ok = await _v2ray.requestPermission().timeout(
          const Duration(seconds: 20),
          onTimeout: () => false,
        );
    if (!ok) {
      throw Exception('VPN permission nahi mili.');
    }
    // The DNS for this attempt: the combination search's override
    // when one is running, otherwise the user's selected provider
    // (the plugin exposes no DNS option of its own).
    final attemptDns = _dnsOverride ?? await DnsService.loadSelected();
    final dnsServers = attemptDns.servers;
    // Hysteria2 links are not understood by the plugin's URL parser:
    // their configuration is built by hand (buildHysteria2Config)
    // and started through the same engine. Every other scheme keeps
    // the plugin parser path, untouched.
    final String config;
    final String remark;
    if (StealthLink.parse(link)?.scheme == 'hysteria2') {
      final built = buildHysteria2Config(link, dnsServers);
      if (built == null) {
        throw Exception('This Hysteria2 link could not be read.');
      }
      config = built;
      remark = server.name;
    } else {
      final parser = V2ray.parseFromURL(link);
      config = parser.getFullConfiguration();
      remark = parser.remark.isEmpty ? server.name : parser.remark;
    }
    await _v2ray.startV2Ray(
      remark: remark,
      // One DNS treatment for every stealth scheme: the dns object
      // plus the routing rule that keeps DNS inside the tunnel.
      // The single exception is the Tier-3 default-DNS attempt,
      // whose whole point is the absence of a custom treatment:
      // the configuration is stripped back and the plugin/core
      // default DNS handling applies instead.
      config: DnsService.isDefaultDns(attemptDns)
          ? DnsService.defaultDnsConfig(config)
          : DnsService.applyStealthDns(config, dnsServers),
      proxyOnly: false,
    );
  }

  Future<void> _connectWireGuard(VpnServer server) async {
    // Claim the engine slot first, before any await (see _connectOvpn).
    _activeEngine = 'wireguard';
    late final String conf;
    late final String endpoint;
    // The user's selected DNS provider, read fresh at connect time.
    final selectedDns = await DnsService.loadSelected();
    final dnsServers = selectedDns.servers;
    // The selected provider is written into the tunnel
    // configuration below (both the WARP and the custom branch),
    // so it is this session's DNS by construction; record it for
    // the status display. A failed start clears the record again
    // via _fail / _disconnect, like every session field.
    effectiveDns = selectedDns;
    if (server.warp) {
      final w = await warp.ensureRegistered().timeout(
            const Duration(seconds: 25),
            onTimeout: () => throw TimeoutException('WARP register timeout'),
          );
      endpoint =
          (server.endpoint?.isNotEmpty ?? false) ? server.endpoint! : w.endpoint;
      conf = warp.buildQuickConfig(w, endpoint, dnsServers: dnsServers);
    } else if (server.type == 'custom') {
      if (server.peerPublicKey == null || server.endpoint == null) {
        throw Exception('Server config adhuri hai.');
      }
      final alg = X25519();
      final kp = await alg.newKeyPair();
      final pub = await kp.extractPublicKey();
      final privBytes = await kp.extractPrivateKeyBytes();
      customClientPubKey = base64Encode(pub.bytes);
      endpoint = server.endpoint!;
      conf = '[Interface]\n'
          'PrivateKey = ${base64Encode(privBytes)}\n'
          'Address = 10.8.0.2/32\n'
          'DNS = ${dnsServers.join(', ')}\n'
          '\n'
          '[Peer]\n'
          'PublicKey = ${server.peerPublicKey}\n'
          'AllowedIPs = 0.0.0.0/0\n'
          'Endpoint = $endpoint\n'
          'PersistentKeepalive = 25\n';
    } else {
      throw Exception('Ye server abhi available nahi hai.');
    }
    await _wg.startVpn(
      serverAddress: endpoint,
      wgQuickConfig: conf,
      providerBundleIdentifier: 'com.ipchakra.app',
    );
    // Free mode's connection notification needs POST_NOTIFICATIONS
    // on Android 13+. The Stealth flow gets it via the V2Ray
    // plugin's permission request; ask here too so a Free-first
    // user is covered. Deliberately AFTER the tunnel start has been
    // issued, and fire-and-forget: the request pops a system dialog
    // (an activity pause/resume cycle) and must never sit on the
    // connect critical path, where in v2.1.3 it lengthened the
    // window in which a stale stop echo could fail the attempt and
    // made the first tap feel ignored. Best-effort: a denied
    // permission only means no notification, never a failed
    // connect.
    if (_isAndroid) {
      unawaited(() async {
        try {
          await _wg
              .requestNotificationPermission()
              .timeout(const Duration(seconds: 5));
        } catch (_) {}
      }());
    }
    // WireGuard ka stage callback jald aata hai; tab tak watchdog sambhalega.
  }

  Future<void> _refreshIp() async {
    try {
      currentIp = await fetchExitIp().timeout(const Duration(seconds: 10));
    } catch (_) {}
    notifyListeners();
  }

  String stateLabel() {
    switch (state) {
      case VpnState.disconnected:
        return 'Disconnected';
      case VpnState.connecting:
        return 'Connecting…';
      case VpnState.connected:
        return 'Connected';
      case VpnState.disconnecting:
        return 'Disconnecting…';
      case VpnState.reconnecting:
        return 'Reconnecting…';
      case VpnState.error:
        return 'Error';
    }
  }
}
