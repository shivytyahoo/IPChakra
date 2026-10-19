import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A counting DNS forwarder: the local, honest answer to the
/// standalone AdShield's LIVE OVERVIEW counters.
///
/// Why this exists: embedded AdShield blocks through the tunnel
/// engines' own DNS (the Xray core's `dns.hosts`, or a filtering
/// provider for WireGuard/OpenVPN). Those engines expose no
/// per-query count to the app, so a live "queries / blocked"
/// counter was impossible without inventing numbers. This
/// forwarder makes it measurable for STEALTH sessions:
///
/// - The Xray configuration's only DNS server becomes this
///   forwarder (127.0.0.1 on an ephemeral port) for the attempt.
/// - Every query the core sends upstream lands here first. The
///   forwarder checks the name against the same bundled blocklist
///   the core's hosts injection used: a match is answered locally
///   with 0.0.0.0 / :: and counted as BLOCKED; anything else is
///   relayed to the attempt's upstream resolver THROUGH the tunnel
///   (via the core's own SOCKS inbound — the same path the connect
///   verifier proves) and the answer is relayed back. Every query
///   is counted exactly once, when it arrives.
/// - If the SOCKS relay cannot run yet (the tunnel is still coming
///   up — e.g. the core resolving the proxy server's own hostname
///   during bootstrap), the query falls back to a direct UDP relay
///   so name resolution never deadlocks; once the tunnel is up the
///   SOCKS path succeeds first and the fallback is not used.
///
/// WireGuard/OpenVPN sessions cannot use this: their tunnel DNS is
/// an address inside someone else's network namespace (a config
/// "DNS = 127.0.0.1" would point into the tunnel itself), so their
/// queries never pass through the app. Their sessions keep the
/// provider-based treatment and show no counter — the UI says so.
///
/// All counters are REAL: a query is counted when this forwarder
/// receives it, and blocked only when this forwarder answers it
/// from the blocklist.
typedef DnsRelay = Future<Uint8List?> Function(
    Uint8List query, String upstream);

/// The parts of a DNS query the forwarder needs.
class DnsQueryInfo {
  final int id;
  final String qname;
  final int qtype;

  /// Offset just past the question section (name + type + class) —
  /// a response echoes the bytes up to here verbatim.
  final int questionEnd;

  const DnsQueryInfo({
    required this.id,
    required this.qname,
    required this.qtype,
    required this.questionEnd,
  });
}

/// Parse the first question of a DNS message. Returns null for
/// anything malformed or not a standard query. Pure — unit-tested.
DnsQueryInfo? parseDnsQuery(Uint8List packet) {
  if (packet.length < 12) return null;
  final data =
      ByteData.view(packet.buffer, packet.offsetInBytes, packet.length);
  final flags = data.getUint16(2);
  if ((flags & 0x8000) != 0) return null; // a response, not a query
  if (data.getUint16(4) < 1) return null; // QDCOUNT
  var offset = 12;
  final labels = <String>[];
  while (true) {
    if (offset >= packet.length) return null;
    final len = packet[offset];
    if (len == 0) {
      offset++;
      break;
    }
    if (len & 0xC0 != 0) return null; // compression in a query name
    offset++;
    if (offset + len > packet.length) return null;
    labels.add(String.fromCharCodes(packet.sublist(offset, offset + len)));
    offset += len;
  }
  if (offset + 4 > packet.length) return null;
  final qtype = data.getUint16(offset);
  return DnsQueryInfo(
    id: data.getUint16(0),
    qname: labels.join('.').toLowerCase(),
    qtype: qtype,
    questionEnd: offset + 4,
  );
}

/// Whether [qname] is on the blocklist: the hosts map keys are
/// `domain:<d>` and an entry covers the domain itself and every
/// subdomain (the Xray `domain:` semantics the injected hosts map
/// relied on, reproduced here exactly).
bool isBlockedName(String qname, Map<String, String> hosts) {
  if (hosts.isEmpty) return false;
  var name = qname.toLowerCase();
  while (true) {
    if (hosts.containsKey('domain:$name')) return true;
    final dot = name.indexOf('.');
    if (dot < 0) return false;
    name = name.substring(dot + 1);
    if (name.isEmpty) return false;
  }
}

/// The surrogate stub IP answered for blocked A queries (anti-detect).
///
/// Bait requests (ad pixels / ad scripts) to this IP are redirected by
/// the Xray config to the local stub web server, which answers with
/// empty-but-valid surrogate resources — so "Ad blocker detected"
/// probes see success instead of failure, while no real ad is ever
/// fetched. Must match the dokodemo-door rule in
/// [AdShieldService.injectXrayHosts] and the hosts generator.
const kAdShieldStubIp = '10.10.10.3';

/// The stub IP above as raw bytes.
const kAdShieldStubIpBytes = [10, 10, 10, 3];

/// Build the answer for a blocked name: the query's header and
/// question echoed back, NOERROR, and — for A / AAAA queries — a
/// single answer record with a short TTL. A queries get the
/// anti-detect stub IP ([kAdShieldStubIpBytes]); AAAA keeps ::
///
/// (nudging dual-stack clients onto IPv4, where the stub server can
/// answer). Other query types get a NODATA answer (NOERROR, no
/// records): the name is blocked, there is simply nothing of that
/// type. Pure — unit-tested.
Uint8List buildBlockedResponse(Uint8List query, DnsQueryInfo info) {
  final isA = info.qtype == 1;
  final isAAAA = info.qtype == 28;
  final answer = (isA || isAAAA) ? 1 : 0;
  final rdlen = isA ? 4 : (isAAAA ? 16 : 0);
  final out = Uint8List(info.questionEnd + (answer == 1 ? 12 + rdlen : 0));
  out.setRange(0, info.questionEnd, query);
  final data = ByteData.view(out.buffer);
  // QR + opcode copied + RD copied + RA, rcode 0 (NOERROR).
  final reqFlags = ByteData.view(
          query.buffer, query.offsetInBytes, query.length)
      .getUint16(2);
  data.setUint16(2, 0x8000 | (reqFlags & 0x7900) | 0x0080);
  data.setUint16(6, answer); // ANCOUNT
  data.setUint16(8, 0); // NSCOUNT
  data.setUint16(10, 0); // ARCOUNT — any EDNS in the query is dropped
  if (answer == 1) {
    var o = info.questionEnd;
    data.setUint16(o, 0xC00C); // name: pointer to the question name
    data.setUint16(o + 2, info.qtype);
    data.setUint16(o + 4, 1); // class IN
    data.setUint32(o + 6, 60); // TTL
    data.setUint16(o + 10, rdlen);
    if (isA) {
      // Anti-detect: the bait request succeeds against the stub
      // server instead of failing. (AAAA RDATA stays zeroed = ::.)
      out.setRange(o + 12, o + 16, kAdShieldStubIpBytes);
    }
  }
  return out;
}

/// A SERVFAIL response echoing the query's question. Pure.
Uint8List buildServfailResponse(Uint8List query, DnsQueryInfo info) {
  final out = Uint8List(info.questionEnd);
  out.setRange(0, info.questionEnd, query);
  final data = ByteData.view(out.buffer);
  final reqFlags = ByteData.view(
          query.buffer, query.offsetInBytes, query.length)
      .getUint16(2);
  data.setUint16(2, 0x8000 | (reqFlags & 0x7900) | 0x0080 | 0x0002);
  data.setUint16(6, 0);
  data.setUint16(8, 0);
  data.setUint16(10, 0);
  return out;
}

/// The forwarder itself: a UDP socket on loopback, the blocklist,
/// the current attempt's upstream resolvers, and the two counters'
/// callbacks. One instance serves a whole connect session (the
/// ladder's attempts share it via [updateUpstreams]).
class CountingDnsForwarder {
  CountingDnsForwarder({
    required this.hosts,
    required this.onQuery,
    required this.onBlocked,
    DnsRelay? relay,
  }) : _relay = relay ?? _defaultRelay;

  /// The blocklist (`domain:<d>` -> `0.0.0.0`), shared by reference
  /// with AdShieldService — it is never mutated after loading.
  final Map<String, String> hosts;

  /// Called exactly once per received query.
  final void Function() onQuery;

  /// Called when a query is answered from the blocklist.
  final void Function() onBlocked;

  final DnsRelay _relay;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  List<String> _upstreams = const [];

  /// The loopback port the Xray config must point at, once started.
  int? get port => _socket?.port;

  bool get running => _socket != null;

  /// Bind the socket (idempotent) and set the upstream resolvers
  /// for the attempt that is about to start. Returns the port, or
  /// null when the socket could not be bound — the caller then
  /// falls back to the plain hosts-injection treatment, so a
  /// counting failure can never break a connect.
  Future<int?> start(List<String> upstreams) async {
    _upstreams = upstreams;
    if (_socket != null) return _socket!.port;
    try {
      final socket =
          await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      _socket = socket;
      _sub = socket.listen(
        (event) {
          if (event != RawSocketEvent.read) return;
          final datagram = socket.receive();
          if (datagram == null) return;
          unawaited(_handle(socket, datagram));
        },
        onError: (_) {},
      );
      return socket.port;
    } catch (_) {
      _socket = null;
      return null;
    }
  }

  /// Point the relay at a new attempt's resolvers (the ladder's
  /// DNS escalation changes the upstream per attempt).
  void updateUpstreams(List<String> upstreams) => _upstreams = upstreams;

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
  }

  Future<void> _handle(
      RawDatagramSocket socket, Datagram datagram) async {
    final response = await _answerFor(datagram.data);
    if (response != null) {
      socket.send(response, datagram.address, datagram.port);
    }
  }

  /// The whole serving decision for one received query: count it,
  /// answer it from the blocklist when it matches, relay it
  /// otherwise, and answer SERVFAIL when no upstream responds.
  /// Returns null only for packets that are not servable queries
  /// (those are dropped silently). Split from the socket so the
  /// logic is testable where UDP itself is unavailable.
  @visibleForTesting
  Future<Uint8List?> debugAnswerFor(Uint8List packet) => _answerFor(packet);

  Future<Uint8List?> _answerFor(Uint8List packet) async {
    final info = parseDnsQuery(packet);
    if (info == null) return null; // not a query we can serve; drop it
    onQuery();
    if (isBlockedName(info.qname, hosts)) {
      onBlocked();
      return buildBlockedResponse(packet, info);
    }
    for (final upstream in _upstreams) {
      final response = await _relay(packet, upstream);
      if (response != null) return response;
    }
    return buildServfailResponse(packet, info);
  }

  // ── default relay: SOCKS-TCP through the tunnel, direct UDP
  // as the bootstrap fallback ────────────────────────────────────

  static Future<Uint8List?> _defaultRelay(
      Uint8List query, String upstream) async {
    final viaTunnel = await _relayViaSocks(query, upstream);
    if (viaTunnel != null) return viaTunnel;
    return _relayDirectUdp(query, upstream);
  }

  /// DNS-over-TCP through the core's SOCKS inbound (127.0.0.1:10807
  /// — present in every stealth configuration, and the exact path
  /// the connect verifier uses), so the relayed query rides the
  /// tunnel like all user traffic.
  static Future<Uint8List?> _relayViaSocks(
      Uint8List query, String upstream) async {
    Socket? socket;
    try {
      socket = await Socket.connect('127.0.0.1', 10807,
              timeout: const Duration(seconds: 2))
          .timeout(const Duration(seconds: 2));
      socket.add([5, 1, 0]); // version, one method, no-auth
      final greeting = await _readExact(socket, 2);
      if (greeting == null || greeting[0] != 5 || greeting[1] != 0) {
        return null;
      }
      final ip = InternetAddress.tryParse(upstream);
      if (ip == null) return null;
      socket.add([5, 1, 0, 1, ...ip.rawAddress, 0, 53]);
      final head = await _readExact(socket, 4);
      if (head == null || head[0] != 5 || head[1] != 0) return null;
      switch (head[3]) {
        case 1:
          await _readExact(socket, 6);
          break;
        case 3:
          final lenBytes = await _readExact(socket, 1);
          if (lenBytes == null) return null;
          await _readExact(socket, lenBytes[0] + 2);
          break;
        case 4:
          await _readExact(socket, 18);
          break;
        default:
          return null;
      }
      socket.add([query.length >> 8, query.length & 0xff, ...query]);
      final lenBytes =
          await _readExact(socket, 2, timeout: const Duration(seconds: 3));
      if (lenBytes == null) return null;
      final length = (lenBytes[0] << 8) | lenBytes[1];
      if (length < 12 || length > 4096) return null;
      return await _readExact(socket, length,
          timeout: const Duration(seconds: 3));
    } catch (_) {
      return null;
    } finally {
      socket?.destroy();
    }
  }

  /// Read exactly [n] bytes from a freshly opened socket (the whole
  /// reply arrives as one short stream). Returns null on timeout or
  /// early close.
  static Future<Uint8List?> _readExact(Socket socket, int n,
      {Duration timeout = const Duration(seconds: 2)}) async {
    final buffer = <int>[];
    final completer = Completer<Uint8List?>();
    late final StreamSubscription<List<int>> sub;
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    sub = socket.listen(
      (chunk) {
        buffer.addAll(chunk);
        if (buffer.length >= n && !completer.isCompleted) {
          completer.complete(Uint8List.fromList(buffer.sublist(0, n)));
        }
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(null);
      },
    );
    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await sub.cancel();
    }
  }

  /// Direct UDP relay to the upstream resolver — the fallback for
  /// the moments the tunnel path cannot answer yet (bootstrap).
  /// The app process is excluded from its own VPN, so this goes
  /// over the real network and cannot loop into the forwarder.
  static Future<Uint8List?> _relayDirectUdp(
      Uint8List query, String upstream) async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final target = InternetAddress(upstream);
      final id = query.length >= 2 ? (query[0] << 8) | query[1] : -1;
      final completer = Completer<Uint8List?>();
      final timer = Timer(const Duration(seconds: 2), () {
        if (!completer.isCompleted) completer.complete(null);
      });
      final sub = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        final data = datagram.data;
        // Only the answer to OUR query counts.
        if (data.length >= 2 && ((data[0] << 8) | data[1]) == id) {
          if (!completer.isCompleted) completer.complete(data);
        }
      });
      socket.send(query, target, 53);
      final result = await completer.future;
      timer.cancel();
      await sub.cancel();
      return result;
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }
}
