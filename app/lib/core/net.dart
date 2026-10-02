import 'package:http/http.dart' as http;

/// Chhote network helpers.
Future<int?> measurePing() async {
  try {
    final sw = Stopwatch()..start();
    final r = await http
        .get(Uri.parse('https://www.cloudflare.com/cdn-cgi/trace'))
        .timeout(const Duration(seconds: 10));
    sw.stop();
    return r.statusCode == 200 ? sw.elapsedMilliseconds : null;
  } catch (_) {
    return null;
  }
}

Future<String?> fetchExitIp() async {
  try {
    final r = await http
        .get(Uri.parse('https://api.ipify.org'))
        .timeout(const Duration(seconds: 15));
    return r.statusCode == 200 ? r.body.trim() : null;
  } catch (_) {
    return null;
  }
}
