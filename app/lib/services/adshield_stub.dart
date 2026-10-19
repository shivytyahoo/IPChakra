import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Surrogate stub web server for embedded AdShield (anti-detect).
///
/// Why this exists: the tunnel's DNS answers blocked ad domains with
/// the stub IP (see `kAdShieldStubIp` in counting_dns.dart and the
/// generated `xray_hosts.json`). Xray redirects every TCP connection
/// to that IP through a dokodemo-door outbound to this server
/// (127.0.0.1:18080). It answers with empty-but-*valid* surrogate
/// resources — modelled on uBlock Origin's built-in surrogates — so
/// "Ad blocker detected" bait probes *succeed* instead of failing,
/// while no real ad is ever fetched or displayed:
///
/// - ad scripts -> tiny JS defining the globals pages probe for
///   (`adsbygoogle`, `googletag`, `ga`, `gtag`);
/// - ad images -> 1x1 transparent GIF;
/// - ad frames -> blank HTML page;
/// - anything else -> 204 No Content (fetch()/XHR resolve = success).
///
/// Plain Dart sockets — no TUN involvement (Xray owns the tunnel) and
/// no second VPN profile. The app is disallowed from its own VPN, so
/// loopback always reaches this in-process server directly. HTTPS
/// bait cannot be stubbed without a user-installed CA (the TLS
/// handshake cannot complete); those probes keep the old fail-fast
/// behaviour.
///
/// Lifecycle: [AdShieldService] starts this alongside the counting
/// forwarder on every stealth session and stops it on disconnect.
class AdShieldStubServer {
  /// The loopback port the Xray dokodemo-door rule targets.
  static const port = 18080;

  ServerSocket? _server;
  StreamSubscription<Socket>? _acceptSub;

  /// Whether the server is currently accepting connections.
  bool get running => _server != null;

  /// The port actually bound, or null when not running.
  int? get boundPort => _server?.port;

  /// Bind 127.0.0.1:[port] and start serving. Idempotent; returns
  /// false when the port cannot be bound (the feature then degrades
  /// to the old fail-fast behaviour for stub-IP connections).
  Future<bool> start() async {
    if (running) return true;
    try {
      final server =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      _server = server;
      _acceptSub = server.listen(
        _serve,
        onError: (_) {},
        cancelOnError: false,
      );
      return true;
    } catch (_) {
      _server = null;
      return false;
    }
  }

  /// Stop serving and release the port. Idempotent.
  Future<void> stop() async {
    await _acceptSub?.cancel();
    _acceptSub = null;
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
  }

  Future<void> _serve(Socket socket) async {
    try {
      final head = await _readHead(socket).timeout(
        const Duration(seconds: 5),
        onTimeout: () => null,
      );
      final parsed = head == null ? null : parseStubRequest(head);
      final response = parsed == null
          ? _badRequest()
          : buildStubResponse(parsed.target, parsed.accept);
      socket.add(response);
      await socket.flush();
    } catch (_) {
      // Bait client went away; nothing to do.
    } finally {
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  /// Read until the end of the HTTP request head (`\r\n\r\n`) or
  /// [maxHead] bytes. Returns null on EOF/overflow.
  static Future<Uint8List?> _readHead(Socket socket,
      {int maxHead = 32768}) async {
    final buffer = BytesBuilder();
    await for (final chunk in socket) {
      buffer.add(chunk);
      final bytes = buffer.toBytes();
      if (hasStubHeadEnd(bytes)) return bytes;
      if (bytes.length > maxHead) return null;
    }
    return null;
  }

  static Uint8List _badRequest() => Uint8List.fromList(
        ascii.encode('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n'
            'Content-Length: 0\r\n\r\n'),
      );
}

/// A parsed stub request: the request target and the Accept header.
class StubRequest {
  final String target;
  final String accept;

  const StubRequest(this.target, this.accept);
}

/// Parse a raw HTTP request head; null when malformed. Pure.
StubRequest? parseStubRequest(Uint8List head) {
  final text = ascii.decode(head, allowInvalid: true);
  final eol = text.indexOf('\r\n');
  if (eol < 0) return null;
  final parts = text.substring(0, eol).split(' ');
  if (parts.length < 2 || parts[1].isEmpty) return null;
  var accept = '';
  for (final line in text.substring(eol + 2).split('\r\n')) {
    if (line.isEmpty) break;
    final colon = line.indexOf(':');
    if (colon > 0 &&
        line.substring(0, colon).trim().toLowerCase() == 'accept') {
      accept = line.substring(colon + 1).trim();
    }
  }
  return StubRequest(parts[1], accept);
}

/// True once [bytes] contain a complete HTTP request head. Pure.
bool hasStubHeadEnd(Uint8List bytes) {
  if (bytes.length < 4) return false;
  for (var i = 0; i <= bytes.length - 4; i++) {
    if (bytes[i] == 13 &&
        bytes[i + 1] == 10 &&
        bytes[i + 2] == 13 &&
        bytes[i + 3] == 10) {
      return true;
    }
  }
  return false;
}

/// 1x1 transparent GIF, 43 bytes.
final Uint8List _pixelGif = base64Decode(
    'R0lGODlhAQABAIAAAP///////yH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==');

/// Minimal ad-SDK stub: pages probing `window.adsbygoogle`,
/// `googletag`, `ga`/`gtag` see them as "loaded" — the same trick as
/// uBlock Origin's `googlesyndication_adsbygoogle.js` surrogate.
/// Served ONLY for blocked ad domains, never first-party content.
const String _jsSurrogate = '/* AdShield surrogate: empty ad stub */'
    '(function(){function n(){}'
    'var g={loaded:true,push:function(){return 0},enable_page_level_ads:n};'
    'window.adsbygoogle=window.adsbygoogle||g;'
    'window.googletag=window.googletag||{cmd:[],display:n,enableServices:n,'
    'pubads:function(){return{refresh:n,clear:n,enableSyncRendering:n,'
    'collapseEmptyDivs:n,setTargeting:function(){return this},'
    'addEventListener:n}}};'
    'window.ga=window.ga||n;window.gtag=window.gtag||n;})();';

const String _blankHtml = '<!doctype html><html><head>'
    '<meta charset="utf-8"><title></title></head><body></body></html>';

/// A valid, empty VAST 3.0 document: the deterministic "no ad"
/// signal for video players. Served for ad-tag-like requests on
/// blocked ad domains — the player parses it, finds zero <Ad>
/// elements and plays the content instead of erroring, retrying,
/// or falling back to a house ad (which a bare 204 sometimes
/// triggers). The stub only ever serves blocked ad domains, so any
/// VAST-shaped request here is ad inventory by construction.
const String _emptyVast =
    '<?xml version="1.0" encoding="UTF-8"?><VAST version="3.0"></VAST>';

/// Build the complete HTTP response bytes for a stub request. Pure —
/// unit-tested.
Uint8List buildStubResponse(String target, String acceptHeader) {
  var t = target.toLowerCase();
  final q = t.indexOf('?');
  if (q >= 0) t = t.substring(0, q);
  final h = t.indexOf('#');
  if (h >= 0) t = t.substring(0, h);
  final a = acceptHeader.toLowerCase();
  if (t.endsWith('.js') ||
      t.endsWith('.mjs') ||
      a.contains('javascript') ||
      a.contains('ecmascript')) {
    return _http(200, 'OK', 'text/javascript', ascii.encode(_jsSurrogate));
  }
  if (t.endsWith('.css') || a.contains('text/css')) {
    return _http(
        200, 'OK', 'text/css', ascii.encode('/* AdShield surrogate */'));
  }
  if (t.endsWith('.gif') ||
      t.endsWith('.png') ||
      t.endsWith('.jpg') ||
      t.endsWith('.jpeg') ||
      t.endsWith('.webp') ||
      t.endsWith('.ico') ||
      t.endsWith('.bmp') ||
      t.endsWith('.svg') ||
      a.startsWith('image/')) {
    return _http(200, 'OK', 'image/gif', _pixelGif);
  }
  if (t.endsWith('.html') || t.endsWith('.htm') || a.contains('text/html')) {
    return _http(200, 'OK', 'text/html', ascii.encode(_blankHtml));
  }
  // Video ad tags (VAST/IMA): an empty VAST document is the
  // deterministic "no ad" signal — better than 204, which some
  // players treat as a retryable error.
  if (t.endsWith('.xml') ||
      t.contains('vast') ||
      t.contains('/ima') ||
      t.contains('ima3') ||
      a.contains('xml')) {
    return _http(200, 'OK', 'application/xml', ascii.encode(_emptyVast));
  }
  // Unknown bait URL: 204 still resolves fetch()/XHR as success,
  // which is all most detection probes check.
  return Uint8List.fromList(ascii.encode(
      'HTTP/1.1 204 No Content\r\nConnection: close\r\n'
      'Cache-Control: no-store\r\n\r\n'));
}

Uint8List _http(int status, String reason, String contentType,
    Uint8List body) {
  final head = ascii.encode('HTTP/1.1 $status $reason\r\n'
      'Content-Type: $contentType\r\n'
      'Content-Length: ${body.length}\r\n'
      'Connection: close\r\n'
      'Cache-Control: no-store\r\n'
      'X-AdShield: surrogate\r\n'
      '\r\n');
  final out = Uint8List(head.length + body.length);
  out.setRange(0, head.length, head);
  out.setRange(head.length, out.length, body);
  return out;
}
