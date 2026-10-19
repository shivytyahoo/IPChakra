import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'dns_service.dart';

/// End-to-end verification of a freshly started stealth tunnel,
/// performed through the Xray core's own local SOCKS inbound
/// (127.0.0.1:10807 — present in every stealth configuration this
/// app starts, plugin-generated and hand-built alike).
///
/// Verifying from inside the app process directly would prove
/// nothing: the VPN plugin excludes the app itself from the tunnel,
/// so the app's own sockets never traverse it. Traffic that enters
/// through the core's SOCKS inbound, however, takes exactly the
/// path user traffic takes — the same outbound, the same routing,
/// the same DNS treatment. Two checks run through it:
///
/// 1. DNS: a real DNS-over-TCP query for [DnsService.testHostname]
///    to the candidate resolver's primary address on port 53.
/// 2. Fetch: a real HTTP request to a hostname URL (api.ipify.org),
///    which additionally proves the exit side resolves names and
///    returns the tunnel's exit address.
///
/// Each check has its own short timeout; a failed check reports
/// failure instead of throwing, so the caller can simply move on to
/// the next (server, DNS) combination.
class TunnelVerifier {
  static const socksHost = '127.0.0.1';
  static const socksPort = 10807;
  static const _connectTimeout = Duration(seconds: 3);
  static const _ioTimeout = Duration(seconds: 3);

  /// Run both checks against the tunnel using [resolverIp] as the
  /// DNS server under test. The checks are independent SOCKS
  /// connections, so they run CONCURRENTLY: run one after the
  /// other, their combined latency routinely exceeded the caller's
  /// overall timeout on ordinary free servers, and working
  /// combinations were being rejected for slowness alone.
  static Future<({bool dnsOk, String? exitIp})> verify({
    required String resolverIp,
  }) async {
    final results = await Future.wait<Object?>([
      _checkDns(resolverIp),
      _fetchExitIp(),
    ]);
    return (dnsOk: results[0] as bool, exitIp: results[1] as String?);
  }

  /// Open a SOCKS5 connection through the local inbound to
  /// [host]:[port] (an IP literal or a domain name) and hand the
  /// connection to [body]. Returns null on any failure.
  static Future<T?> _viaSocks<T>(
    String host,
    int port,
    Future<T> Function(Socket socket, _SocketReader reader) body,
  ) async {
    Socket? socket;
    _SocketReader? reader;
    try {
      socket = await Socket.connect(
        socksHost,
        socksPort,
        timeout: _connectTimeout,
      ).timeout(_connectTimeout);
      reader = _SocketReader(socket);
      socket.add([5, 1, 0]); // version, one method, no-auth
      final greeting = await reader.read(2).timeout(_ioTimeout);
      if (greeting[0] != 5 || greeting[1] != 0) return null;
      final ip = InternetAddress.tryParse(host);
      if (ip != null) {
        socket.add([5, 1, 0, 1, ...ip.rawAddress, port >> 8, port & 0xff]);
      } else {
        final name = utf8.encode(host);
        socket.add([5, 1, 0, 3, name.length, ...name, port >> 8, port & 0xff]);
      }
      final head = await reader.read(4).timeout(_ioTimeout);
      if (head[0] != 5 || head[1] != 0) return null;
      switch (head[3]) {
        case 1:
          await reader.read(6).timeout(_ioTimeout);
          break;
        case 3:
          final len = (await reader.read(1).timeout(_ioTimeout))[0];
          await reader.read(len + 2).timeout(_ioTimeout);
          break;
        case 4:
          await reader.read(18).timeout(_ioTimeout);
          break;
        default:
          return null;
      }
      return await body(socket, reader);
    } catch (_) {
      return null;
    } finally {
      await reader?.close();
      socket?.destroy();
    }
  }

  /// Check 1: a real DNS query to the candidate resolver, carried by
  /// the tunnel. Uses the same query builder and response validator
  /// as the DNS speed test.
  static Future<bool> _checkDns(String resolverIp) async {
    final id = Random().nextInt(0x10000);
    final query = DnsService.buildAQuery(DnsService.testHostname, id);
    final ok = await _viaSocks<bool>(resolverIp, 53, (socket, reader) async {
      socket.add([query.length >> 8, query.length & 0xff, ...query]);
      final lenBytes = await reader.read(2).timeout(_ioTimeout);
      final length = (lenBytes[0] << 8) | lenBytes[1];
      if (length < 12 || length > 4096) return false;
      final packet = await reader.read(length).timeout(_ioTimeout);
      if (!DnsService.isValidResponse(Uint8List.fromList(packet), id)) {
        return false;
      }
      // At least one answer record.
      return packet.length >= 8 && ((packet[6] << 8) | packet[7]) >= 1;
    });
    return ok ?? false;
  }

  /// Plain-HTTP exit-address services, raced against each other:
  /// a single hard-coded endpoint was a single point of failure —
  /// when it throttled or dropped the exit, every combination
  /// failed verification no matter how healthy the tunnel was.
  static const _exitIpHosts = ['api.ipify.org', 'checkip.amazonaws.com'];

  /// Check 2: fetch the exit address through the tunnel from a
  /// hostname URL — the name is resolved on the exit side, exactly
  /// like a browser request for a site. The first service to
  /// answer with a valid address wins.
  static Future<String?> _fetchExitIp() async {
    final completer = Completer<String?>();
    var pending = _exitIpHosts.length;
    for (final host in _exitIpHosts) {
      unawaited(_fetchExitIpFrom(host).then((ip) {
        if (ip != null && !completer.isCompleted) {
          completer.complete(ip);
        }
        if (--pending == 0 && !completer.isCompleted) {
          completer.complete(null);
        }
      }));
    }
    return completer.future;
  }

  static Future<String?> _fetchExitIpFrom(String host) {
    return _viaSocks<String?>(host, 80, (socket, reader) async {
      socket.add(utf8.encode(
        'GET / HTTP/1.0\r\nHost: $host\r\nConnection: close\r\n\r\n',
      ));
      // Whatever arrived within the window is parsed, including a
      // complete response on a connection the peer kept open —
      // waiting for the close discarded good answers.
      final buffer = await reader.readToEnd(
        8192,
        timeout: const Duration(seconds: 5),
      );
      final text = utf8.decode(buffer, allowMalformed: true);
      if (!text.startsWith('HTTP/1.') || !text.contains(' 200 ')) {
        return null;
      }
      final split = text.indexOf('\r\n\r\n');
      if (split < 0) return null;
      final body = text.substring(split + 4).trim();
      return InternetAddress.tryParse(body) != null ? body : null;
    });
  }
}

/// Minimal buffered reader over a [Socket]: SOCKS replies arrive in
/// fragments, so exact-length reads are buffered here. One reader
/// owns the socket's single subscription for its whole lifetime.
class _SocketReader {
  _SocketReader(this._socket) {
    _sub = _socket.listen(
      (chunk) {
        _buffer.addAll(chunk);
        _pump();
      },
      onError: (_) => _fail(),
      onDone: _fail,
    );
  }

  final Socket _socket;
  late final StreamSubscription<List<int>> _sub;
  final List<int> _buffer = [];
  final List<Completer<void>> _waiters = [];
  bool _closed = false;

  void _pump() {
    for (final w in List.of(_waiters)) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  void _fail() {
    _closed = true;
    _pump();
  }

  Future<void> _waitForData() {
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  /// Read exactly [n] bytes; throws on timeout or stream end.
  Future<List<int>> read(int n) async {
    while (_buffer.length < n) {
      if (_closed) throw const SocketException('Socket closed');
      await _waitForData().timeout(
        TunnelVerifier._ioTimeout,
        onTimeout: () =>
            throw TimeoutException('Timed out reading from socket'),
      );
    }
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }

  /// Read until the peer closes, [maxBytes] have arrived, or
  /// [timeout] elapses — whichever comes first. On timeout the
  /// bytes buffered so far are returned (a complete response on a
  /// connection the peer kept open is still usable), never
  /// discarded.
  Future<List<int>> readToEnd(
    int maxBytes, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final watch = Stopwatch()..start();
    while (!_closed && _buffer.length < maxBytes) {
      final remaining = timeout - watch.elapsed;
      if (remaining <= Duration.zero) break;
      try {
        await _waitForData().timeout(remaining);
      } on TimeoutException {
        break;
      }
    }
    return List.of(_buffer);
  }

  Future<void> close() => _sub.cancel();
}
