package app.deadman.seeker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Keeps the process out of OEM app freezers (Samsung Freecess, MIUI) while
 * the wallet app is in front. MWA's local association runs a WebSocket server
 * in this process; if it is frozen, the wallet waits forever.
 *
 * A `shortService` needs no special permission and the OS stops it after
 * ~3 minutes, which bounds a forgotten session.
 */
class WalletSessionService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int) {
        stopSelf()
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Wallet connection", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Waiting for your wallet")
            .setContentText("Approve the request in your wallet app")
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "wallet_session"
        private const val NOTIFICATION_ID = 7301
        private const val TAG = "WalletSession"

        fun start(context: Context) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, WalletSessionService::class.java))
            } catch (e: Exception) {
                // Best effort: without it MWA still works on most devices.
                Log.w(TAG, "could not start keep-alive service", e)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, WalletSessionService::class.java))
        }
    }
}
