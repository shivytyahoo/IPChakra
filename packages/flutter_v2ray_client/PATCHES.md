# Local patches to flutter_v2ray_client 3.5.0

This is a vendored copy of the upstream `flutter_v2ray_client` package,
version **3.5.0** (copied unchanged from the pub.dev package cache).
The Dart API and the package version are identical to upstream.
IPChakra uses it through a `dependency_overrides` path entry in the
app's `pubspec.yaml`, the same pattern as the vendored
`wireguard_flutter` and `openvpn_flutter` packages.

## Patch 1 — Notification "Disconnect" button actually stops the VPN

**File:**
`android/src/main/java/dev/amirzr/flutter_v2ray_client/v2ray/core/V2rayCoreManager.java`,
method `showNotification(...)`.

**Upstream bug:** the method builds two pending intents:

- `notificationContentPendingIntent` — an *activity* intent that
  launches the app (its intent action is even named
  `FROM_DISCONNECT_BTN`), and
- `pendingIntent` — a *service* intent targeting
  `V2rayVPNService` (or `V2rayProxyOnlyService` in proxy-only mode)
  carrying the `STOP_SERVICE` command.

The notification's Disconnect action was wired to the **first** one:

```java
.addAction(0, v2rayConfig.NOTIFICATION_DISCONNECT_BUTTON_NAME, notificationContentPendingIntent)
```

So tapping "Disconnect" in the VPN notification only brought the app
to the foreground; the correctly built stop intent was created and
never used, and the tunnel kept running.

**Fix:** wire the action to the stop intent instead:

```java
.addAction(0, v2rayConfig.NOTIFICATION_DISCONNECT_BUTTON_NAME, pendingIntent)
```

Nothing else in the method changes: tapping the notification body
still opens the app via `setContentIntent(...)`, which correctly
keeps using the activity intent. `showNotification` builds no other
actions, so no other button is affected.

**Why this is sufficient (receiving side, unchanged upstream code):**

1. The service pending intent delivers the intent to
   `V2rayVPNService.onStartCommand`, which handles
   `STOP_SERVICE` by calling `V2rayCoreManager.stopCore()`
   (`V2rayProxyOnlyService` handles it the same way).
2. `stopCore()` broadcasts the connection-info intent with state
   `V2RAY_DISCONNECTED`, stops the Xray loop, and calls the service
   listener's `stopService()` (foreground state removed, service
   stopped, TUN interface closed). (The broadcast's position inside
   `stopCore()` was later hardened by Patch 2 below.)
3. `V2rayReceiver` forwards that state to Dart as `DISCONNECTED` on
   the plugin's status event channel — exactly the event the app
   already receives for a system-initiated VPN stop, so the app's
   normal native-stop teardown runs and the UI settles at
   Disconnected.

This mirrors how the plugin's own Dart-initiated stop works:
`V2rayController.stopV2Ray()` sends the identical service intent
with `STOP_SERVICE` via `startService(...)`.

## Patch 2 — The DISCONNECTED broadcast cannot be swallowed, and its receiver is lifecycle-proof

**Files:**
`android/.../v2ray/core/V2rayCoreManager.java` (`stopCore`),
`android/.../FlutterV2rayPlugin.java` (receiver registration),
`lib/flutter_v2ray_method_channel.dart` (status subscription).

**Field report (IPChakra v2.1.2, S25):** with Patch 1 the
notification's Disconnect button killed the tunnel (notification
gone, VPN icon gone from the status bar) — but the app kept showing
"Connected" with the old server/IP. The DISCONNECTED news never
landed in Dart.

**Root causes found in the upstream code:**

1. `stopCore()` sent the connection-info broadcast with state
   `V2RAY_DISCONNECTED` as its **very last step**, inside the same
   try block as `coreController.stopLoop()` and the service
   listener's `stopService()` (which removes foreground state,
   stops the service and closes the TUN), and **after** the
   notification had already been cancelled. Any exception in the
   native stop sequence was caught by the blanket
   `catch (Exception e)` that only logs — the single signal the app
   listens to was silently skipped, while the user saw the
   notification disappear and concluded (correctly) that the tunnel
   was dead.
2. The `V2rayReceiver` that forwards those broadcasts to Dart was
   registered on the **Activity** context whenever an activity
   existed (`FlutterV2rayPlugin` onListen), tying delivery to one
   activity instance, and was re-registered from several lifecycle
   callbacks on possibly different contexts.
3. On the Dart side the status `EventChannel` subscription was not
   stored anywhere (`listen(...)` result discarded), so nothing
   owned the lifetime of the only channel that carries a native
   stop to the app.

**Fix:**

- `stopCore()` now calls `sendDisconnectedBroadCast()` **first**,
  in its own try/catch, before cancelling the notification and
  before stopping the core. No teardown step can suppress it.
  (Its other effects — resetting duration/counters and cancelling
  the duration timer — are exactly what a stop wants anyway.)
- Receiver registration is funnelled through one guarded helper
  (`registerStatusReceiver` / `unregisterStatusReceiver`) that
  always registers on the **application context** — the broadcasts
  are sent from the application context in the service process, so
  delivery no longer depends on activity lifecycle timing — and
  can never register the same receiver on two contexts (which
  would deliver every status twice).
- The Dart method-channel implementation keeps its status
  subscription in a field. The no-op `.distinct()` on the stream
  (it compared event lists by identity, so it could never filter
  anything) was removed while touching that line.

## Patch 3 — `getConnectionState()` ground-truth query

**Files:** `android/.../FlutterV2rayPlugin.java` (new method-channel
case), `lib/flutter_v2ray_platform_interface.dart`,
`lib/flutter_v2ray_method_channel.dart`, `lib/flutter_v2ray.dart`.

Upstream offers no way to *ask* the native side for its current
state; the app could only trust pushed events. The new
`getConnectionState()` method returns
`V2rayController.getConnectionState()` — the `AppConfigs.V2RAY_STATE`
mirror that `V2rayController.init()` keeps current in the app
process from the same connection-info broadcasts (registered on
the application context at initialize time, never unregistered).
The app uses it on start/resume to reconcile its UI state against
native truth. Note the state MUST be read from that mirror:
`V2rayCoreManager`'s own field lives in the separate
`:RunSoLibV2RayDaemon` service process and would always read
DISCONNECTED from the app process.

## Keeping this copy honest

Everything in this directory other than this file and the changes
described above (Patch 1: the `addAction(...)` line; Patch 2:
`stopCore` ordering, receiver registration, Dart subscription;
Patch 3: the `getConnectionState` additions) is byte-identical to
the upstream 3.5.0 package. When upgrading the plugin, re-apply
only these patches (and delete this vendoring if upstream ships
equivalents).
