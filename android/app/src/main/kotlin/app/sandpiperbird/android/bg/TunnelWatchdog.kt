package app.sandpiperbird.android.bg

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import app.sandpiperbird.android.Application
import app.sandpiperbird.android.MainActivity
import app.sandpiperbird.android.R
import app.sandpiperbird.android.Settings
import app.sandpiperbird.android.constant.Action
import app.sandpiperbird.android.constant.ServiceMode

/**
 * SP3-02 / D-09: the second way back for a tunnel whose process was killed (low memory, a vendor's
 * task killer, kill -9). The first is START_STICKY, which Android honours on its own schedule, or
 * not at all on some builds. This is an inexact, non-waking alarm every 15 minutes, armed only while
 * a tunnel the user turned on runs: no wake lock, no job, and it never fires while the device sleeps
 * (it waits for the next wake). When it fires and the service is not running in this process, the
 * service is started again with [Action.RESTORE]; the service then holds a blocking TUN before the
 * core starts (TunnelService.holdBlockingTun), so nothing leaves around the VPN while it connects.
 *
 * What it does not guarantee: the time between the kill and the alarm (up to ~15 minutes, longer in
 * Doze or the restricted standby bucket) is not covered; without Always-on with "Block connections
 * without VPN" traffic goes around the VPN in that time. A force stop, a reboot or an update of the
 * app cancels the alarm (Android's rule); Always-on brings the VPN back after a reboot.
 */
object TunnelWatchdog {
    private const val TAG = "A/TunnelWatchdog"
    private const val INTERVAL_MS = AlarmManager.INTERVAL_FIFTEEN_MINUTES
    private const val RESTORE_NOTIFICATION_ID = 2
    private const val RESTORE_CHANNEL = "restore"

    enum class Decision {
        /** The tunnel runs, or there is nothing to bring back. */
        NOTHING,

        /** The user stopped the tunnel (or it failed): the alarm goes. */
        DISARM,

        /** Start the service again. */
        START,

        /** The VPN permission was taken away: only the user can give it again (the app asks). */
        ASK_PERMISSION,
    }

    /** Pure, for the tests: what the alarm does. */
    fun decide(startedByUser: Boolean, serviceRunning: Boolean, vpnMode: Boolean, vpnPermitted: Boolean): Decision =
        when {
            !startedByUser -> Decision.DISARM
            serviceRunning -> Decision.NOTHING
            vpnMode && !vpnPermitted -> Decision.ASK_PERMISSION
            else -> Decision.START
        }

    private fun alarmIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            0,
            Intent(context, TunnelWatchdogReceiver::class.java).setAction(Action.WATCHDOG),
            ServiceNotification.flags or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    /** While a tunnel the user turned on runs. Arming again only moves the same alarm. */
    fun arm(context: Context) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        runCatching {
            alarms.setInexactRepeating(
                AlarmManager.ELAPSED_REALTIME,
                SystemClock.elapsedRealtime() + INTERVAL_MS,
                INTERVAL_MS,
                alarmIntent(context),
            )
        }.onFailure { Log.w(TAG, "cannot arm the watchdog", it) }
    }

    fun disarm(context: Context) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        runCatching { alarms.cancel(alarmIntent(context)) }
        runCatching { Application.notification.cancel(RESTORE_NOTIFICATION_ID) }
    }

    internal fun onAlarm(context: Context) {
        val vpnMode = Settings.serviceMode == ServiceMode.VPN
        val decision = decide(
            startedByUser = Settings.startedByUser,
            serviceRunning = BoxService.running,
            vpnMode = vpnMode,
            vpnPermitted = !vpnMode || runCatching { VpnService.prepare(context) == null }.getOrDefault(false),
        )
        Log.i(TAG, "alarm: $decision")
        when (decision) {
            Decision.NOTHING -> Unit
            Decision.DISARM -> disarm(context)
            Decision.ASK_PERMISSION -> {
                Settings.startedByUser = false
                disarm(context)
                notifyStopped(context, restore = false)
            }
            Decision.START -> {
                val intent = Intent(context, Settings.serviceClass()).setAction(Action.RESTORE)
                try {
                    // Android 12+ lets an app the user allowed to run a VPN start it from the background
                    // (the ACTIVATE_VPN permission); a vendor build may still refuse: then the user's tap
                    // on the notification starts it
                    ContextCompat.startForegroundService(context, intent)
                } catch (e: Exception) {
                    Log.w(TAG, "cannot start the service from the background", e)
                    notifyStopped(context, restore = true)
                }
            }
        }
    }

    /**
     * "The tunnel stopped": a tap starts it again ([restore]) or opens the app (the VPN permission is
     * needed again).
     */
    private fun notifyStopped(context: Context, restore: Boolean) {
        if (!ServiceNotification.checkPermission()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Application.notification.createNotificationChannel(
                NotificationChannel(
                    RESTORE_CHANNEL,
                    context.getString(R.string.notification_channel_restore),
                    NotificationManager.IMPORTANCE_DEFAULT,
                ),
            )
        }
        val tap = if (restore) {
            val intent = Intent(context, Settings.serviceClass()).setAction(Action.RESTORE)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                PendingIntent.getForegroundService(context, 1, intent, ServiceNotification.flags)
            } else {
                PendingIntent.getService(context, 1, intent, ServiceNotification.flags)
            }
        } else {
            PendingIntent.getActivity(
                context,
                1,
                Intent(context, MainActivity::class.java).setFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                ServiceNotification.flags,
            )
        }
        val notification = NotificationCompat.Builder(context, RESTORE_CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_logo)
            .setContentTitle(context.getString(R.string.app_name))
            .setContentText(context.getString(if (restore) R.string.restore_tap else R.string.restore_open_app))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .build()
        runCatching { Application.notification.notify(RESTORE_NOTIFICATION_ID, notification) }
    }
}

/** The watchdog's alarm; not exported, only its own PendingIntent reaches it. */
class TunnelWatchdogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Action.WATCHDOG) return
        Application.initialize(context)
        TunnelWatchdog.onAlarm(context.applicationContext)
    }
}
