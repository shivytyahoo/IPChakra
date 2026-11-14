import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/app_version.dart';

/// In-app update check against this repo's GitHub releases
/// (Settings → Check for update).
///
/// The check is manual and on demand: it asks the public GitHub
/// releases API for the latest release, compares its tag with the
/// running build, and — when a newer release carries an APK asset —
/// downloads that APK into the app cache and hands it to the system
/// package installer through a FileProvider URI (see the
/// `ipchakra/app_update` method channel in MainActivity). No
/// account, no token, no background polling: unauthenticated
/// GitHub API reads are rate-limited per IP, and a tap is the only
/// time the app spends one.
///
/// Honest by construction: a release with no APK asset still
/// reports itself as available, but offers the release page
/// instead of a download button; a failed check says so instead
/// of pretending everything is up to date.
enum UpdateCheckStatus {
  /// The latest release is the running version (or older).
  upToDate,

  /// A newer release exists.
  available,

  /// The check itself failed (no network, GitHub error, bad data).
  error,
}

class UpdateCheckResult {
  final UpdateCheckStatus status;

  /// Latest release tag without a leading 'v', when known.
  final String? latestVersion;

  /// Release title from GitHub, when present.
  final String? releaseName;

  /// Release notes from GitHub, when present.
  final String? releaseNotes;

  /// Direct download URL of the release's APK asset, when the
  /// release carries one.
  final String? apkUrl;

  /// Web URL of the release page (fallback when there is no APK).
  final String? releaseUrl;

  /// Human-readable reason, only for [UpdateCheckStatus.error].
  final String? message;

  const UpdateCheckResult._({
    required this.status,
    this.latestVersion,
    this.releaseName,
    this.releaseNotes,
    this.apkUrl,
    this.releaseUrl,
    this.message,
  });

  const UpdateCheckResult.upToDate({String? latestVersion})
      : this._(status: UpdateCheckStatus.upToDate,
            latestVersion: latestVersion);

  const UpdateCheckResult.available({
    required String latestVersion,
    String? releaseName,
    String? releaseNotes,
    String? apkUrl,
    String? releaseUrl,
  }) : this._(
          status: UpdateCheckStatus.available,
          latestVersion: latestVersion,
          releaseName: releaseName,
          releaseNotes: releaseNotes,
          apkUrl: apkUrl,
          releaseUrl: releaseUrl,
        );

  const UpdateCheckResult.error(String message)
      : this._(status: UpdateCheckStatus.error, message: message);
}

class UpdateService {
  static const releasesLatestUrl =
      'https://api.github.com/repos/shivytyahoo/IPChakra/releases/latest';

  static const _channel = MethodChannel('ipchakra/app_update');

  final http.Client _client;

  /// Version the check compares against; defaults to the running
  /// build so callers never pass it, tests pin it explicitly.
  final String currentVersion;

  UpdateService({http.Client? client, String? currentVersion})
      : _client = client ?? http.Client(),
        currentVersion = currentVersion ?? kAppVersionName;

  void close() => _client.close();

  /// Whether [latest] is a newer release than [current].
  /// Compares numeric parts (so 1.10.0 > 1.9.0); a leading 'v' and
  /// a pre-release suffix ('-beta') are tolerated, and a
  /// pre-release is older than the same numbers released.
  static bool isNewerVersion(String latest, String current) {
    final l = _parts(latest);
    final r = _parts(current);
    final n = l.length > r.length ? l.length : r.length;
    for (var i = 0; i < n; i++) {
      final a = i < l.length ? l[i] : 0;
      final b = i < r.length ? r[i] : 0;
      if (a != b) return a > b;
    }
    if (_hasPreRelease(current) && !_hasPreRelease(latest)) return true;
    return false;
  }

  static bool _hasPreRelease(String v) => v.trim().contains('-');

  static List<int> _parts(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    s = s.split('-').first.split('+').first;
    return s.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  }

  /// Ask GitHub for the latest release and compare it with the
  /// running build. Never throws: every failure becomes an
  /// [UpdateCheckStatus.error] result with a plain reason.
  Future<UpdateCheckResult> checkForUpdate() async {
    try {
      final r = await _client
          .get(
            Uri.parse(releasesLatestUrl),
            headers: {
              // GitHub requires a User-Agent on API calls.
              'User-Agent': 'IPChakra',
              'Accept': 'application/vnd.github+json',
            },
          )
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 404) {
        return const UpdateCheckResult.error(
            'No releases found on GitHub yet.');
      }
      if (r.statusCode != 200) {
        return UpdateCheckResult.error(
            'GitHub answered ${r.statusCode} — try again later.');
      }
      final data = jsonDecode(r.body);
      if (data is! Map<String, dynamic>) {
        return const UpdateCheckResult.error(
            'GitHub sent a reply the app could not read.');
      }
      final tag = (data['tag_name'] as String?) ?? '';
      if (tag.isEmpty) {
        return const UpdateCheckResult.error(
            'GitHub sent a release without a version.');
      }
      final latest = tag.startsWith('v') ? tag.substring(1) : tag;
      String? apkUrl;
      final assets = data['assets'];
      if (assets is List) {
        for (final a in assets) {
          if (a is! Map) continue;
          final name = a['name']?.toString() ?? '';
          if (name.endsWith('.apk')) {
            apkUrl = a['browser_download_url']?.toString();
            break;
          }
        }
      }
      if (!isNewerVersion(latest, currentVersion)) {
        return UpdateCheckResult.upToDate(latestVersion: latest);
      }
      return UpdateCheckResult.available(
        latestVersion: latest,
        releaseName: data['name']?.toString(),
        releaseNotes: data['body']?.toString(),
        apkUrl: apkUrl,
        releaseUrl: data['html_url']?.toString(),
      );
    } on TimeoutException {
      return const UpdateCheckResult.error(
          'Timed out reaching GitHub — check your connection.');
    } catch (_) {
      return const UpdateCheckResult.error(
          'Could not reach GitHub — check your connection.');
    }
  }

  /// Download the release APK into the app cache (`updates/`
  /// subfolder, served to the installer by the FileProvider).
  /// Reports 0.0–1.0 progress when the server sends a length.
  /// Returns the downloaded file's path, or null when the
  /// download failed. Never throws.
  Future<String?> downloadApk(
    String apkUrl,
    String version, {
    void Function(double progress)? onProgress,
  }) async {
    try {
      final req = http.Request('GET', Uri.parse(apkUrl));
      final resp =
          await _client.send(req).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) return null;
      final total = resp.contentLength ?? -1;
      final dir = Directory('${Directory.systemTemp.path}/updates');
      await dir.create(recursive: true);
      final file = File('${dir.path}/IPChakra-v$version.apk');
      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in resp.stream) {
        received += chunk.length;
        sink.add(chunk);
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.close();
      if (total > 0) onProgress?.call(1.0);
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Hand a downloaded APK to the system package installer.
  /// Returns false when the install intent cannot be started
  /// (or the platform has no handler) — the caller then says so
  /// instead of pretending the update started. Android itself
  /// asks the user to allow "Install unknown apps" for IPChakra
  /// on first use.
  Future<bool> installApk(String path) async {
    try {
      return await _channel.invokeMethod<bool>(
              'installApk', {'path': path}) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Open a URL in the browser (release-page fallback when a
  /// release carries no APK asset). Returns false when nothing
  /// can open it.
  Future<bool> openUrl(String url) async {
    try {
      return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
