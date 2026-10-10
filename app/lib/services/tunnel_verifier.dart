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
  /// DNS server under test.
  static Future<({bool dnsOk, String? exitIp})> verify({
    required String resolverIp,
  }) async {
    final dnsOk = await _checkDns(resolverIp);
    final exitIp = await _fetchExitIp();
    return (dnsOk: dnsOk, exitIp: exitIp);
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

  /// Check 2: fetch the exit address through the tunnel from a
  /// hostname URL — the name is resolved on the exit side, exactly
  /// like a browser request for a site.
  static Future<String?> _fetchExitIp() {
    return _viaSocks<String?>('api.ipify.org', 80, (socket, reader) async {
      socket.add(utf8.encode(
        'GET / HTTP/1.0\r\nHost: api.ipify.org\r\n\r\n',
      ));
      final buffer = await reader.readToEnd(8192).timeout(
            const Duration(seconds: 5),
            onTimeout: () => <int>[],
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

  /// Read until the peer closes or [maxBytes] have arrived.
  Future<List<int>> readToEnd(int maxBytes) async {
    while (!_closed && _buffer.length < maxBytes) {
      await _waitForData();
    }
    return List.of(_buffer);
  }

  Future<void> close() => _sub.cancel();
}
