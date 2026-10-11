package billion.group.wireguard_flutter

import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * IPChakra patch (see PATCHES.md, Patch 3): the foreground service
 * that OWNS the WireGuard connection notification.
 *
 * Up to v2.3.2 the notification was posted standalone through
 * NotificationManager (see [WgNotification]). It carried
 * setOngoing(true), but it was not attached to any service, and on
 * the user's device "clear all" removed it while the tunnel stayed
 * up — the VPN looked gone while it was still running. A
 * notification attached to a running foreground service cannot be
 * swiped away or cleared; it exists exactly as long as the service
 * runs, and the service runs exactly as long as the tunnel is up:
 * [WgNotification.show] starts this service on the tunnel's
 * "connected" stage event and [WgNotification.cancel] stops it on
 * "disconnected". It carries no tunnel state of its own (the
 * WireGuard backend lives in GoBackend's VpnService); its only job
 * is to pin the status notification as a foreground-service
 * notification.
 */
class WgConnectionService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = WgNotification.build(applicationContext)
        if (notification == null) {
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    WgNotification.NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(WgNotification.NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // The system refused the foreground transition (for
            // example a background-start restriction). Do not crash
            // and do not pretend: stop, and let the caller's plain
            // notification fallback be the visible status instead.
            Log.w(TAG, "Could not enter foreground: ${e.message}")
            stopSelf()
            return START_NOT_STICKY
        }
        // Not sticky: if the process dies, the tunnel died with it
        // (same process), so the notification must NOT be
        // resurrected by a service restart.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        try {
            @Suppress("DEPRECATION")
            stopForeground(true)
        } catch (e: Exception) {
            Log.w(TAG, "Could not leave foreground: ${e.message}")
        }
        super.onDestroy()
    }

    companion object {
        private const val TAG = "NVPN"
    }
}
