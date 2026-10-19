// End-to-end test of the REAL TunnelVerifier against a local fake
// tunnel: a SOCKS5 server on the verifier's own port, relaying to
// a fake DNS-over-TCP responder and a fake exit-address HTTP
// service. Every controller test stubs the verifier, so the real
// SOCKS handshake / DNS validation / HTTP parse path had never
// been exercised — while on Shiv's S25 every stealth combination
// was failing it. This test pins the real path.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/services/dns_service.dart';
import 'package:ipchakra/services/tunnel_verifier.dart';

/// Buffered exact-length reader over a socket (test side), with a
/// takeover mode: after the handshake reads, the rest of the
/// stream (including anything already buffered) is handed to a
/// relay listener. A socket's stream cannot be listened to twice,
/// so the single subscription lives here for the whole connection.
class _Conn {
  _Conn(this.socket) {
    _sub = socket.listen(
      (chunk) {
        final sink = _sink;
        if (sink != null) {
          sink.add(chunk);
        } else {
          _buffer.addAll(chunk);
          _pump();
        }
      },
      onError: (_) => _fail(),
      onDone: _fail,
    );
  }

  final Socket socket;
  late final StreamSubscription<List<int>> _sub;
  final List<int> _buffer = [];
  final List<Completer<void>> _waiters = [];
  StreamController<List<int>>? _sink;
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
    final sink = _sink;
    if (sink != null && !sink.isClosed) unawaited(sink.close());
  }

  Future<List<int>> read(int n) async {
    while (_buffer.length < n) {
      if (_closed) throw const SocketException('closed');
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    final out = _buffer.sublist(0, n);
    _buffer.removeRange(0, n);
    return out;
  }

  /// Hand the remainder of this connection to [onData]: buffered
  /// bytes first, then live chunks, from the one subscription.
  void takeOver(void Function(List<int> chunk) onData,
      {required void Function() onDone}) {
    final controller = StreamController<List<int>>(
      onCancel: onDone,
    );
    _sink = controller;
    if (_buffer.isNotEmpty) {
      controller.add(List.of(_buffer));
      _buffer.clear();
    }
    if (_closed) unawaited(controller.close());
    controller.stream.listen(onData, onError: (_) {}, onDone: onDone);
  }

  Future<void> close() => _sub.cancel();
}

/// A canned valid DNS response for [query]: same ID, QR set, one A
/// answer (203.0.113.9) echoing the question.
Uint8List _dnsResponse(Uint8List query) {
  final out = BytesBuilder();
  out.add(query.sublist(0, 2)); // ID
  out.add([0x81, 0x80]); // QR + RD + RA, no error
  out.add(query.sublist(4, 6)); // QDCOUNT copied
  out.add([0, 1]); // ANCOUNT = 1
  out.add([0, 0, 0, 0]); // NSCOUNT, ARCOUNT
  out.add(query.sublist(12)); // question section
  out.add([0xc0, 0x0c, 0, 1, 0, 1]); // name pointer, A, IN
  out.add([0, 0, 0, 60]); // TTL
  out.add([0, 4, 203, 0, 113, 9]); // RDLENGTH + address
  return out.toBytes();
}

void main() {
  test(
    'the real verifier passes against a working tunnel '
    '(SOCKS + DNS-over-TCP + HTTP exit fetch)',
    () async {
      // Fake DNS-over-TCP responder on 127.0.0.1:53 (the verifier
      // always queries port 53 at the resolver address).
      final dnsServer =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 53);
      final dnsSubs = <StreamSubscription<Socket>>[];
      dnsSubs.add(dnsServer.listen((client) {
        final conn = _Conn(client);
        unawaited(() async {
          try {
            final lenBytes = await conn.read(2);
            final length = (lenBytes[0] << 8) | lenBytes[1];
            final query = await conn.read(length);
            final response = _dnsResponse(Uint8List.fromList(query));
            client.add(
                [response.length >> 8, response.length & 0xff, ...response]);
            await client.flush();
          } catch (_) {
            // The verifier went away mid-check; the next check is
            // a fresh connection.
          }
        }());
      }));

      // Fake exit-address HTTP service.
      final httpServer =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final httpSubs = <StreamSubscription<Socket>>[];
      httpSubs.add(httpServer.listen((client) {
        final conn = _Conn(client);
        unawaited(() async {
          try {
            await conn.read(4); // part of the request line is enough
            client.write('HTTP/1.0 200 OK\r\n'
                'Content-Type: text/plain\r\n'
                '\r\n'
                '203.0.113.9');
            await client.flush();
            await client.close();
          } catch (_) {}
        }());
      }));

      // Fake SOCKS5 server on the verifier's port: CONNECT is
      // relayed to the fake DNS (127.0.0.1:53) or the fake HTTP
      // service (the two exit-address hostnames).
      final socksServer = await ServerSocket.bind(
          InternetAddress.loopbackIPv4, TunnelVerifier.socksPort);
      final socksSubs = <StreamSubscription<Socket>>[];
      socksSubs.add(socksServer.listen((client) {
        final conn = _Conn(client);
        unawaited(() async {
          Socket? target;
          try {
            final greeting = await conn.read(2);
            final methods = await conn.read(greeting[1]);
            if (greeting[0] != 5 || methods.isEmpty) return;
            client.add([5, 0]);
            final head = await conn.read(4);
            if (head[0] != 5 || head[1] != 1) return;
            String host;
            int port;
            switch (head[3]) {
              case 1:
                final addr = await conn.read(4);
                final portBytes = await conn.read(2);
                host = addr.join('.');
                port = (portBytes[0] << 8) | portBytes[1];
              case 3:
                final len = (await conn.read(1))[0];
                final name = await conn.read(len);
                final portBytes = await conn.read(2);
                host = String.fromCharCodes(name);
                port = (portBytes[0] << 8) | portBytes[1];
              default:
                return;
            }
            final targetPort = port == 80 ? httpServer.port : port;
            final targetHost = port == 80 ? '127.0.0.1' : host;
            target = await Socket.connect(targetHost, targetPort);
            client.add([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
            await client.flush();
            // Bidirectional relay for the rest of the connection.
            final relaySub = target.listen(
              (chunk) => client.add(chunk),
              onError: (_) {},
              onDone: () => client.destroy(),
            );
            conn.takeOver(
              (chunk) => target?.add(chunk),
              onDone: () {
                target?.destroy();
                unawaited(relaySub.cancel());
              },
            );
          } catch (_) {
            // Verifier closed early; nothing to relay.
          }
        }());
      }));

      addTearDown(() async {
        for (final s in [...dnsSubs, ...httpSubs, ...socksSubs]) {
          await s.cancel();
        }
        await dnsServer.close();
        await httpServer.close();
        await socksServer.close();
      });

      // Sanity: the canned response must pass the app's own
      // validator for a freshly built query.
      final probeQuery = DnsService.buildAQuery('example.com', 4242);
      expect(
        DnsService.isValidResponse(_dnsResponse(probeQuery), 4242),
        isTrue,
      );

      final result = await TunnelVerifier.verify(resolverIp: '127.0.0.1');
      expect(result.dnsOk, isTrue,
          reason: 'the DNS check must pass through a working tunnel');
      expect(result.exitIp, '203.0.113.9',
          reason: 'the exit fetch must return the service answer');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
