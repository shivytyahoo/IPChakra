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
 * IPChakra patch (see PATCHES.md, Patch 2): the persistent
 * "connected" notification for the WireGuard engine.
 *
 * Neither the upstream plugin nor the WireGuard tunnel backend it
 * wraps (`com.wireguard.android:tunnel` GoBackend — verified: its
 * bytecode contains no notification or startForeground code at all)
 * ever posts a notification, so a Free-mode connection was invisible
 * in the notification shade. This helper posts a plain ongoing
 * notification while the tunnel is up and removes it when the
 * tunnel goes down. Its Disconnect action is a real stop: it routes
 * through [WireguardFlutterPlugin.stopFromNotification], i.e. the
 * exact same backend state change the in-app disconnect performs,
 * so the resulting stage events reach Dart exactly like any other
 * native stop.
 */
object WgNotification {
    const val ACTION_DISCONNECT = "billion.group.wireguard_flutter.ACTION_DISCONNECT"

    private const val CHANNEL_ID = "ipchakra_wireguard_connection"
    private const val NOTIFICATION_ID = 2602
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

    fun show(context: Context) {
        try {
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

            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
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
            NotificationManagerCompat.from(context).notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            // Without POST_NOTIFICATIONS (Android 13+) the system
            // simply drops the notification; the tunnel is unaffected.
            Log.w(TAG, "Could not post WireGuard notification: ${e.message}")
        }
    }

    fun cancel(context: Context) {
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
