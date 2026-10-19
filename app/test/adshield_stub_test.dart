// Anti-detect surrogate stub web server tests.
//
// The stub server is what "Ad blocker detected" bait probes actually
// talk to: every assertion below pins the wire contract —
// empty-but-valid resources, never a failure — plus the request
// parser and the bind/start/stop lifecycle.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ipchakra/services/adshield_stub.dart';

Uint8List _u(String s) => Uint8List.fromList(s.codeUnits);
// latin1: every byte maps 1:1, so binary bodies (the GIF) decode too.
String _s(Uint8List b) => latin1.decode(b);

void main() {
  group('parseStubRequest / hasStubHeadEnd', () {
    test('parses target and accept header', () {
      final req = parseStubRequest(_u(
          'GET /ads.js?x=1 HTTP/1.1\r\nHost: a\r\nAccept: */*\r\n\r\n'))!;
      expect(req.target, '/ads.js?x=1');
      expect(req.accept, '*/*');
    });

    test('rejects garbage', () {
      expect(parseStubRequest(_u('GARBAGE')), isNull);
      expect(parseStubRequest(_u('')), isNull);
    });

    test('detects the end of the head', () {
      expect(hasStubHeadEnd(_u('GET / HTTP/1.1\r\n\r\n')), isTrue);
      expect(hasStubHeadEnd(_u('GET / HTTP/1.1\r\n')), isFalse);
      expect(hasStubHeadEnd(_u('')), isFalse);
    });
  });

  group('buildStubResponse', () {
    test('ad scripts get the JS surrogate with ad globals', () {
      final body = _s(buildStubResponse('/ads.js', ''));
      expect(body, contains('HTTP/1.1 200 OK'));
      expect(body, contains('text/javascript'));
      expect(body, contains('adsbygoogle'));
      expect(body, contains('googletag'));
    });

    test('ad images get the 1x1 GIF', () {
      final body = _s(buildStubResponse('/banner.png', ''));
      expect(body, contains('HTTP/1.1 200 OK'));
      expect(body, contains('image/gif'));
    });

    test('video ad tags get a valid empty VAST document', () {
      for (final target in ['/vast/vast.xml', '/api/ima3?x=1', '/vpaid/vast']) {
        final body = _s(buildStubResponse(target, ''));
        expect(body, contains('HTTP/1.1 200 OK'),
            reason: 'target $target');
        expect(body, contains('application/xml'), reason: 'target $target');
        expect(body, contains('<VAST version="3.0"></VAST>'),
            reason: 'target $target');
      }
    });

    test('unknown bait URLs get 204 (fetch resolves = success)', () {
      final body = _s(buildStubResponse('/some-bait-pixel', ''));
      expect(body, contains('HTTP/1.1 204 No Content'));
    });
  });

  group('AdShieldStubServer lifecycle', () {
    test('binds, serves a stub, and stops', () async {
      final server = AdShieldStubServer();
      expect(await server.start(), isTrue);
      expect(server.running, isTrue);
      try {
        final socket = await Socket.connect(
            InternetAddress.loopbackIPv4, AdShieldStubServer.port);
        socket.write('GET /ads.js HTTP/1.1\r\nHost: x\r\n\r\n');
        await socket.flush();
        final response =
            await socket.fold<BytesBuilder>(BytesBuilder(), (b, d) {
          b.add(d);
          return b;
        }).then((b) => b.toBytes());
        await socket.close();
        expect(_s(response), contains('adsbygoogle'));
      } finally {
        await server.stop();
      }
      expect(server.running, isFalse);
    });

    test('start is idempotent', () async {
      final server = AdShieldStubServer();
      expect(await server.start(), isTrue);
      expect(await server.start(), isTrue);
      await server.stop();
    });
  });
}
