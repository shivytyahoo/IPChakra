# Local patches to wireguard_flutter

This is a vendored copy of the upstream `wireguard_flutter` package.
IPChakra uses it through a `dependency_overrides` path entry in the
app's `pubspec.yaml`, the same pattern as the vendored
`openvpn_flutter` and `flutter_v2ray_client` packages.

## Patch 1 — Android build modernisation (pre-existing)

Upstream is unmaintained (AGP 7.1.3 / compileSdk 31), so only the
Android build configuration was modernised in this copy: AGP 9.1.0,
Kotlin 2.4.0, compileSdk 35. No Dart or native behaviour change.

## Patch 2 — Persistent connection notification with a real Disconnect action

**Field report (IPChakra v2.1.2, S25):** Free mode (WireGuard)
showed **no notification at all** while connected, unlike Stealth.

**Root cause:** nobody ever posts one.

- The tunnel backend, `com.wireguard.android:tunnel:1.0.20230427`
  (GoBackend), contains **no notification code whatsoever** —
  verified in the shipped AAR bytecode: no `startForeground`, no
  `Notification` references in `GoBackend` or its `VpnService`.
- The plugin itself never built a notification either.
- On Android 13+ a notification additionally needs the
  POST_NOTIFICATIONS runtime permission, which nothing in the Free
  path ever requested (only the V2Ray plugin requests it, during a
  Stealth connect).

**Fix (all inside this vendored copy; the Dart API gains one
method, nothing else changes):**

- New file `android/.../WgNotification.kt`:
  - `WgNotification` posts a plain ongoing, silent, low-priority
    notification on a dedicated channel ("VPN connection") while
    the tunnel is up: app label as title, "Connected" as text, the
    app's launch intent on tap, and a **Disconnect** action.
  - `WgDisconnectReceiver` (declared in the plugin manifest,
    `exported=false`) receives that action and calls
    `WireguardFlutterPlugin.stopFromNotification(...)`.
- `WireguardFlutterPlugin.kt`:
  - `updateStage(...)` — the single funnel every stage change
    passes through — shows the notification when the stage becomes
    "connected" and cancels it on "disconnected"/"no_connection",
    whatever caused the change (in-app disconnect, notification
    action, system revocation).
  - The existing `disconnect(result)` body was extracted verbatim
    into `performDisconnect(result: Result?)`;
    `stopFromNotification` calls it with a null result. The stop
    is therefore the identical backend state change as an in-app
    disconnect: the tunnel's state-change callback fires
    `disconnected`, Dart receives the stage event, and the app's
    native-stop teardown runs. If no plugin instance is alive the
    notification is stale and is simply cancelled.
  - New method-channel method `requestNotificationPermission`:
    on Android 13+, requests POST_NOTIFICATIONS through the
    plugin's activity when not already granted.
- `android/src/main/AndroidManifest.xml`: declares the
  POST_NOTIFICATIONS permission (merged into the app manifest) and
  the `WgDisconnectReceiver` receiver.
- Dart: `WireGuardFlutterInterface.requestNotificationPermission()`
  (default no-op, so other platforms are unaffected), implemented
  by the method-channel class and forwarded by the facade.

The notification is intentionally **not** a foreground-service
notification: the WireGuard tunnel's liveness is owned by the
system-managed VpnService (the active VPN service is kept alive by
Android itself), so a plain ongoing notification provides the same
user-visible persistence without a second service competing with
the backend.

## Keeping this copy honest

Other than this file, the build-configuration changes in Patch 1
and the additions in Patch 2 (one new Kotlin file, small hunks in
`WireguardFlutterPlugin.kt`, the plugin manifest, and the three
Dart files), this copy matches upstream. When upgrading, re-apply
only these patches.
