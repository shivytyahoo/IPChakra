import '../models/vpn_server.dart';
import 'dns_service.dart';

/// Pure decision logic for the "best DNS + best server, verified
/// together" connect flow.
///
/// Every fresh stealth connection first ranks the DNS providers by a
/// live UDP/53 measurement, then tries (server, DNS) combinations in
/// a fixed order, declaring success only for a combination that
/// passes end-to-end verification ([comboVerified]). Keeping the
/// ordering and the gate pure makes both unit-testable without any
/// network or engine.

/// Rank the providers that actually answered the measurement.
///
/// The user's [selected] provider comes first when it answered —
/// the user's choice wins over a marginally faster rival. Otherwise
/// the fastest answering provider leads, then the next fastest.
/// Providers that did not answer are excluded entirely: a resolver
/// that does not answer on this network is exactly the failure this
/// flow exists to route around. Catalogue order breaks speed ties.
List<DnsProvider> orderDnsCandidates({
  required DnsProvider selected,
  required Map<String, int?> measured,
}) {
  final answering = <(int, int, DnsProvider)>[
    for (var i = 0; i < DnsService.providers.length; i++)
      if (measured[DnsService.providers[i].id] != null)
        (measured[DnsService.providers[i].id]!, i, DnsService.providers[i]),
  ];
  answering.sort((a, b) {
    final bySpeed = a.$1.compareTo(b.$1);
    return bySpeed != 0 ? bySpeed : a.$2.compareTo(b.$2);
  });
  final ordered = [for (final e in answering) e.$3];
  final selectedAt = ordered.indexWhere((p) => p.id == selected.id);
  if (selectedAt > 0) {
    ordered
      ..removeAt(selectedAt)
      ..insert(0, selected);
  }
  return ordered;
}

/// The DNS providers a manual single-server connect tries, in order:
/// always the user's [selected] provider first (the through-tunnel
/// verification, not the direct-path measurement, is the ground
/// truth for it), then the best alternative from [measured] — the
/// fastest answering provider that is not the selected one.
List<DnsProvider> manualDnsAttempts({
  required DnsProvider selected,
  required Map<String, int?> measured,
}) {
  final ordered = orderDnsCandidates(selected: selected, measured: measured);
  DnsProvider? alternative;
  for (final p in ordered) {
    if (p.id != selected.id) {
      alternative = p;
      break;
    }
  }
  return [selected, ?alternative];
}

/// The full DNS escalation order for a manual connect on ONE fixed
/// server (v2.2.0, Shiv's "keep my server, escalate the DNS" spec).
/// The server never changes during a manual connect; only the DNS
/// treatment escalates until one holds:
///
/// - Tier 1: the user's [selected] provider — always first, always
///   tried, even when it did not answer the direct-path measurement
///   (the through-tunnel verification is the ground truth for it).
/// - Tier 2: every OTHER provider that answered the measurement,
///   in the measured speed order ([orderDnsCandidates]), capped at
///   [maxTier2] so one connect stays inside a sane time budget.
/// - Tier 3: the built-in default-DNS choice ([DnsService.defaultDns])
///   — the configuration carries no custom DNS object at all and the
///   core/plugin default treatment applies.
///
/// Providers that did not answer the measurement are NOT in Tier 2:
/// a resolver that does not answer on this network at all is what
/// the escalation exists to route around, and Tier 3 is the better
/// next shot for that situation. Pure function — unit-tested.
List<DnsProvider> manualEscalationAttempts({
  required DnsProvider selected,
  required Map<String, int?> measured,
  int maxTier2 = 6,
}) {
  final ordered = orderDnsCandidates(selected: selected, measured: measured);
  final attempts = <DnsProvider>[selected];
  var tier2 = 0;
  for (final p in ordered) {
    if (tier2 >= maxTier2) break;
    if (p.id == selected.id) continue;
    attempts.add(p);
    tier2++;
  }
  attempts.add(DnsService.defaultDns);
  return attempts;
}

/// The verdict of the stability gate that follows a successful
/// through-tunnel verification (v2.2.0): a combination may only be
/// shown as Connected after [requiredProbes] further spaced probes
/// through the tunnel have ALL answered, and every probe's exit
/// address matches the address the verification itself observed
/// ([verifiedExitIp]) — a tunnel that flaps to a different exit (or
/// dies) seconds after verifying is exactly the "Connected, then
/// dead by the time a site opens" failure this gate exists to
/// reject. When [verifiedExitIp] is unknown the exit comparison is
/// skipped and the DNS answers alone decide. Pure function —
/// unit-tested.
bool stabilityGatePassed({
  required List<({bool dnsOk, String? exitIp})> probes,
  required String? verifiedExitIp,
  required int requiredProbes,
}) {
  if (probes.length < requiredProbes) return false;
  for (final probe in probes) {
    if (!probe.dnsOk) return false;
    if (verifiedExitIp != null && probe.exitIp != verifiedExitIp) {
      return false;
    }
  }
  return true;
}

/// Build the (server, DNS) combinations Stealth Auto tries, in
/// order, capped at [maxCombos].
///
/// The primary DNS — the selected provider when it answered, else
/// the fastest answering one, which is what [dnsOrdered] carries
/// first — is paired with the best [serversPerDns] servers first;
/// then the next DNS (when one exists) gets the same top servers.
/// With a single DNS candidate it is paired with up to [maxCombos]
/// servers. When [dnsOrdered] is empty (no provider answered the
/// measurement), [fallbackDns] is used alone: DNS that fails on the
/// direct path can still work through a tunnel, so the search must
/// go on. [servers] is expected in candidate order already
/// (last-good first, then health/latency order).
List<(VpnServer, DnsProvider)> buildDnsServerCombos({
  required List<VpnServer> servers,
  required List<DnsProvider> dnsOrdered,
  required DnsProvider fallbackDns,
  int maxCombos = 6,
  int serversPerDns = 3,
}) {
  if (servers.isEmpty) return const [];
  final dnsList = dnsOrdered.isEmpty ? [fallbackDns] : dnsOrdered;
  final combos = <(VpnServer, DnsProvider)>[];
  void addPhase(DnsProvider dns, int serverCount) {
    for (final server in servers.take(serverCount)) {
      if (combos.length >= maxCombos) return;
      final pair = (server, dns);
      if (!combos.contains(pair)) combos.add(pair);
    }
  }

  if (dnsList.length == 1) {
    addPhase(dnsList.first, maxCombos);
  } else {
    addPhase(dnsList[0], serversPerDns);
    addPhase(dnsList[1], serversPerDns);
  }
  return combos;
}

/// The verification gate for one (server, DNS) combination.
///
/// A combination counts as working only when BOTH checks through the
/// tunnel's own SOCKS inbound passed: a real DNS query to the
/// combination's resolver was answered ([dnsOk]) AND a real HTTP
/// fetch of a hostname URL returned the tunnel's exit address
/// ([fetchOk], [tunnelIp]). A combination whose fetch failed is
/// rejected even when an exit-IP change was observed some other way
/// — an IP change alone never proved name resolution works, which is
/// precisely how "Connected but no internet" used to slip through.
/// When the pre-connect baseline address is known, the tunnel exit
/// must differ from it; when it is unknown, a fetched exit address
/// is accepted on its own.
bool comboVerified({
  required bool dnsOk,
  required bool fetchOk,
  required String? tunnelIp,
  required String? baselineIp,
}) {
  if (!dnsOk || !fetchOk) return false;
  if (tunnelIp == null || tunnelIp.isEmpty) return false;
  if (baselineIp != null && baselineIp.isNotEmpty && tunnelIp == baselineIp) {
    return false;
  }
  return true;
}
