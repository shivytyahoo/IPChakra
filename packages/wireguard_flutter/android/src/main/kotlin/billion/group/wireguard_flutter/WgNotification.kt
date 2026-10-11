package billion.group.wireguard_flutter

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * IPChakra patch (see PATCHES.md, Patch 2 + Patch 3): the
 * persistent "connected" notification for the WireGuard engine.
 *
 * Neither the upstream plugin nor the WireGuard tunnel backend it
 * wraps (`com.wireguard.android:tunnel` GoBackend — verified: its
 * bytecode contains no notification or startForeground code at all)
 * ever posts a notification, so a Free-mode connection was invisible
 * in the notification shade.
 *
 * Patch 2 posted the notification standalone through the
 * NotificationManager. Patch 3 (v2.3.3) fixes what the user
 * reported from the device: a standalone notification — ongoing
 * flag or not — is removed by "clear all", leaving a running
 * tunnel with no visible status. The notification is therefore now
 * owned by [WgConnectionService]: [show] starts that foreground
 * service, which attaches this notification via startForeground —
 * the one form the system guarantees cannot be swiped or cleared
 * while it runs — and [cancel] stops the service, which removes
 * it. Only if the foreground start is refused does [show] fall
 * back to the standalone post, so a status still appears.
 *
 * The Disconnect action is a real stop: it routes through
 * [WireguardFlutterPlugin.stopFromNotification], i.e. the exact
 * same backend state change the in-app disconnect performs, so
 * the resulting stage events reach Dart exactly like any other
 * native stop (and the "disconnected" stage then stops the
 * foreground service via [cancel]).
 */
object WgNotification {
    const val ACTION_DISCONNECT = "billion.group.wireguard_flutter.ACTION_DISCONNECT"

    private const val CHANNEL_ID = "ipchakra_wireguard_connection"
    const val NOTIFICATION_ID = 2602
    private const val TAG = "NVPN"

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                    ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "VPN connection",
                    NotificationManager.IMPORTANCE_LOW
                )
                channel.description = "Shows while the WireGuard tunnel is connected"
                manager.createNotificationChannel(channel)
            }
        }
    }

    /**
     * Builds the connection notification itself (channel, launch
     * intent, Disconnect action, ongoing flag). Used by
     * [WgConnectionService] for its startForeground call and by the
     * standalone fallback in [show]. Returns null when the
     * notification cannot be built at all.
     */
    fun build(context: Context): android.app.Notification? {
        return try {
            ensureChannel(context)
            val appInfo = context.applicationInfo
            val label = context.packageManager.getApplicationLabel(appInfo).toString()

            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            launchIntent?.flags =
                Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_NEW_TASK
            val contentIntent = launchIntent?.let {
                PendingIntent.getActivity(
                    context, 0, it,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            }

            val disconnectIntent = Intent(context, WgDisconnectReceiver::class.java)
                .setAction(ACTION_DISCONNECT)
            val disconnectPendingIntent = PendingIntent.getBroadcast(
                context, 1, disconnectIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

            NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(appInfo.icon)
                .setContentTitle("$label — WireGuard")
                .setContentText("Connected")
                .setOngoing(true)
                .setSilent(true)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setContentIntent(contentIntent)
                .addAction(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "Disconnect",
                    disconnectPendingIntent
                )
                .build()
        } catch (e: Exception) {
            // Without POST_NOTIFICATIONS (Android 13+) the system
            // simply drops the notification; the tunnel is unaffected.
            Log.w(TAG, "Could not build WireGuard notification: ${e.message}")
            null
        }
    }

    /**
     * Shows the connection status by starting the foreground
     * service that owns the notification (Patch 3). If the service
     * cannot be started at all, falls back to posting the
     * notification standalone — visible, though clearable — rather
     * than showing nothing.
     */
    fun show(context: Context) {
        try {
            val intent = Intent(context, WgConnectionService::class.java)
            androidx.core.content.ContextCompat.startForegroundService(context, intent)
        } catch (e: Exception) {
            Log.w(TAG, "Could not start connection service: ${e.message}")
            val notification = build(context)
            if (notification != null) {
                try {
                    NotificationManagerCompat.from(context)
                        .notify(NOTIFICATION_ID, notification)
                } catch (e2: Exception) {
                    Log.w(TAG, "Could not post WireGuard notification: ${e2.message}")
                }
            }
        }
    }

    /**
     * Removes the connection status: stops the foreground service
     * (which removes its notification as it leaves the foreground)
     * and cancels any standalone fallback copy with the same id.
     */
    fun cancel(context: Context) {
        try {
            context.stopService(Intent(context, WgConnectionService::class.java))
        } catch (e: Exception) {
            Log.w(TAG, "Could not stop connection service: ${e.message}")
        }
        try {
            NotificationManagerCompat.from(context).cancel(NOTIFICATION_ID)
        } catch (e: Exception) {
            Log.w(TAG, "Could not cancel WireGuard notification: ${e.message}")
        }
    }
}

/**
 * Receives the connection notification's Disconnect action. Declared
 * in the plugin's AndroidManifest (not exported). Delegates to the
 * live plugin instance; if the plugin is gone, the notification is
 * stale (its tunnel lived in the same process) and is just removed.
 */
class WgDisconnectReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == WgNotification.ACTION_DISCONNECT) {
            WireguardFlutterPlugin.stopFromNotification(context)
        }
    }
}
