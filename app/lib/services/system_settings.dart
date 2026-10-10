import 'package:flutter/services.dart';

/// Bridges to the small piece of Android system UI the app cannot
/// build itself: the system VPN settings page, where the user can
/// turn on Always-on VPN and its "Block connections without VPN"
/// lockdown — the operating system's own leak protection. The app
/// itself makes no claim to block traffic when a tunnel is down;
/// this only opens the door to the setting that does.
class SystemSettings {
  static const _channel = MethodChannel('ipchakra/system_settings');

  /// Open the system VPN settings page. Returns false when the
  /// intent cannot be resolved on this device (or the platform has
  /// no such page), so the caller can say so honestly instead of
  /// pretending the tap worked.
  static Future<bool> openVpnSettings() async {
    try {
      return await _channel.invokeMethod<bool>('openVpnSettings') ??
          false;
    } catch (_) {
      // No handler (non-Android platform, or the channel missing):
      // the settings page cannot be opened from here.
      return false;
    }
  }
}
