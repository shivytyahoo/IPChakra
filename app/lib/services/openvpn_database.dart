import '../models/vpn_server.dart';

/// The merged OpenVPN database: every OpenVPN source's servers in
/// one list, deduplicated by endpoint identity, with the liveness
/// registry's verified-alive hint applied.
///
/// Endpoint identity is `host:port:protocol`. Two sources listing
/// the same volunteer relay (the official VPNGate API and the
/// rolling pool both draw from the same network) must produce ONE
/// row, not two. Sources are passed in priority order — the first
/// occurrence of an endpoint wins, so a fresher source's entry
/// (with its inline config and current ping) beats an older
/// sighting of the same endpoint.
///
/// Some sources cannot know an entry's port without downloading
/// its config (the pool's UDP entries, the mirror's file names).
/// Those entries carry a partial identity (`host + protocol`): a
/// partial entry is dropped when any kept entry — exact or partial
/// — already covers the same host and protocol, and an exact entry
/// is never dropped in favour of a partial one.

/// Parse `remote HOST PORT` and the `proto` line out of an OpenVPN
/// config. Returns null when the config has no usable remote line.
(String, int, bool)? parseOvpnRemote(String? config) {
  if (config == null) return null;
  final m =
      RegExp(r'^remote\s+(\S+)\s+(\d+)', multiLine: true).firstMatch(config);
  if (m == null) return null;
  final port = int.tryParse(m.group(2)!);
  if (port == null) return null;
  final protoM = RegExp(r'^proto\s+(\S+)', multiLine: true).firstMatch(config);
  final proto = protoM?.group(1)?.toLowerCase() ?? 'tcp';
  return (m.group(1)!, port, proto.contains('udp'));
}

/// The endpoint identity of an OpenVPN [server], when it can be
/// determined without downloading anything:
///
/// * `(host, port, udp)` — the exact identity, or
/// * `(host, null, udp)` — the partial identity used when the port
///   is not knowable up front (pool UDP entries, mirror files), or
/// * null — no identity could be derived; the merge must keep the
///   entry (an unprovable duplicate is not a duplicate).
(String, int?, bool)? openvpnEndpointOf(VpnServer s) {
  if (s.probeHost != null) {
    return (s.probeHost!, s.probePort, s.probeUdp);
  }
  switch (s.source) {
    case 'vpngate':
      return parseOvpnRemote(s.ovpnConfig);
    case 'mirror':
      // Mirror ids are 'mirror-<dir>-<file name>'; the file name
      // carries the relay IP and a _udp/_tcp flavour marker, but
      // not the port — a partial identity.
      final ip = RegExp(r'(\d+\.\d+\.\d+\.\d+)').firstMatch(s.id);
      if (ip == null) return null;
      return (ip.group(1)!, null, s.id.contains('_udp'));
    default:
      return null;
  }
}

/// Merge [sources] (in priority order, first occurrence wins) into
/// one deduplicated list. When an entry's exact endpoint appears in
/// [verifiedAliveKeys] (`ip:port:proto`, from the liveness
/// registry), the kept entry is marked verified — a display and
/// ordering hint only; the app's own health verdict still decides
/// what is working or dead.
List<VpnServer> mergeOpenvpnServers(
  List<List<VpnServer>> sources, {
  Set<String> verifiedAliveKeys = const {},
}) {
  final seenExact = <String>{};
  final seenExactHostProto = <String>{};
  final seenPartialHostProto = <String>{};
  final out = <VpnServer>[];
  for (final list in sources) {
    for (final s in list) {
      final ep = openvpnEndpointOf(s);
      if (ep == null) {
        out.add(s);
        continue;
      }
      final (host, port, udp) = ep;
      final proto = udp ? 'udp' : 'tcp';
      final hostProto = '$host|$proto';
      if (port != null) {
        final key = '$host|$port|$proto';
        if (!seenExact.add(key)) continue; // exact duplicate
        seenExactHostProto.add(hostProto);
        if (verifiedAliveKeys.contains('$host:$port:$proto')) {
          out.add(s.markVerified());
        } else {
          out.add(s);
        }
      } else {
        // Partial identity: dropped when the same host + protocol
        // is already covered by a kept entry of either kind.
        if (seenExactHostProto.contains(hostProto) ||
            !seenPartialHostProto.add(hostProto)) {
          continue;
        }
        out.add(s);
      }
    }
  }
  return out;
}
