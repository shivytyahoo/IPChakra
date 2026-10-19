import 'package:shared_preferences/shared_preferences.dart';

/// The app's own version identity, kept in step with pubspec.yaml
/// (version 2.3.4+16) — bump both together on every release.
///
/// The build number drives the first-launch-after-upgrade refresh:
/// when it changes, the server lists are force-refreshed once, so an
/// upgrade can never leave the app serving caches written by an
/// older build (the class of bug behind the v2.1.0 Hysteria2 list
/// showing a single server from a pre-Hysteria2 cache).
const String kAppVersionName = '2.3.4';
const int kAppBuildNumber = 16;

const String _kLastSeenBuild = 'last_seen_build';

/// Whether this launch is the first one after the app build changed.
/// A fresh install counts (nothing was ever recorded): forcing one
/// refresh there is harmless, the caches are empty anyway.
bool isFirstLaunchAfterUpgrade(int? lastSeenBuild, int currentBuild) =>
    lastSeenBuild != currentBuild;

/// Check-and-record helper used once at startup. Returns true when
/// this launch follows a build change, and records the current
/// build so the following launches are normal ones.
Future<bool> consumeFirstLaunchAfterUpgrade() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final first = isFirstLaunchAfterUpgrade(
      prefs.getInt(_kLastSeenBuild),
      kAppBuildNumber,
    );
    if (first) await prefs.setInt(_kLastSeenBuild, kAppBuildNumber);
    return first;
  } catch (_) {
    return false;
  }
}
