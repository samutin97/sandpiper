package app.sandpiperbird.android.bg

import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import app.sandpiperbird.android.Application
import app.sandpiperbird.android.MainActivity
import app.sandpiperbird.android.R

/**
 * The system notification of the question about the last resort: the core's choice by the server's
 * ranking found nothing working but a last resort the user has to agree to, and holds the tunnel
 * without a connection meanwhile (SystemInfo.tier_confirm). In the app the question is on the home
 * screen; with the app in the background or swiped away (the service lives on) only this
 * notification tells the user why the internet went away.
 *
 * Once an episode of waiting (from the question until the state leaves it) and only while the app
 * is not in the foreground; it goes when the state leaves the question (the user agreed, a proxy
 * above works again, the tunnel stops) or the app comes to the foreground. A tap opens the app with
 * the question: the notification has no action of its own, so nothing turns the last resort on but
 * the user's tap in the app (a button on the lock screen, or a broadcast another app could send, is
 * no agreement).
 */
class TierPrompt(private val service: Service) {
    companion object {
        private const val notificationId = 3

        // P-1: a channel's sound and vibration are fixed once it is created, and "tier_confirm" was
        // created without vibration (HyperOS played the sound, no vibration): a new channel, with
        // vibration, under the same name for the user; the old one is deleted.
        private const val channel = "tier_confirm_vibrate"
        private const val oldChannel = "tier_confirm"

        /** Short, twice: the question waits for the user, not an alarm. */
        private val vibration = longArrayOf(0, 250, 150, 250)
    }

    init {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            runCatching { Application.notification.deleteNotificationChannel(oldChannel) }
        }
    }

    /** The last resort of the episode under way, "" without one. */
    private var episode = ""
    private var notified = false
    private var posted = false

    /** The core's tier_confirm, at each poll of the service. */
    @Synchronized
    fun update(confirm: String) {
        if (confirm.isEmpty()) {
            episode = ""
            notified = false
            cancel()
            return
        }
        if (confirm != episode) {
            episode = confirm
            notified = false
        }
        if (appInForeground()) {
            // the question is on the app's screen
            cancel()
            return
        }
        if (notified || !ServiceNotification.checkPermission()) return
        notified = true
        post(displayName(confirm))
    }

    /** The tunnel stops: no question any more. */
    @Synchronized
    fun close() {
        episode = ""
        notified = false
        cancel()
    }

    private fun post(name: String) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Application.notification.createNotificationChannel(
                    NotificationChannel(channel, service.getString(R.string.tier_channel), NotificationManager.IMPORTANCE_HIGH).apply {
                        enableVibration(true)
                        vibrationPattern = vibration
                        // the lock screen shows the public version: no connection, not the proxy
                        lockscreenVisibility = Notification.VISIBILITY_PRIVATE
                    }
                )
            }
            val open = PendingIntent.getActivity(
                service,
                notificationId,
                Intent(service, MainActivity::class.java)
                    .setFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                ServiceNotification.flags,
            )
            val body = service.getString(R.string.tier_confirm_body, name)
            val notification = NotificationCompat.Builder(service, channel)
                .setSmallIcon(R.drawable.ic_stat_logo)
                .setContentTitle(service.getString(R.string.tier_confirm_title))
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setCategory(NotificationCompat.CATEGORY_STATUS)
                // before Android 8 the notification itself carries the sound and the vibration
                .setDefaults(NotificationCompat.DEFAULT_SOUND or NotificationCompat.DEFAULT_LIGHTS)
                .setVibrate(vibration)
                .setAutoCancel(true)
                .setContentIntent(open)
                // the lock screen: the app's name and that there is no connection, not the proxy
                .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
                .setPublicVersion(
                    NotificationCompat.Builder(service, channel)
                        .setSmallIcon(R.drawable.ic_stat_logo)
                        .setContentTitle(service.getString(R.string.app_name))
                        .setContentText(service.getString(R.string.tier_waiting))
                        .build()
                )
                .build()
            Application.notification.notify(notificationId, notification)
            posted = true
        } catch (e: Exception) {
            // notifications off or not allowed: nothing to show, nothing to fail
            Log.d("TierPrompt", "not shown: ${e.message}")
        }
    }

    private fun cancel() {
        if (!posted) return
        posted = false
        runCatching { Application.notification.cancel(notificationId) }
    }

    /** The app's screen is in front (the activity runs in the service's process). */
    private fun appInForeground(): Boolean {
        val state = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(state)
        return state.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }
}

/** A tag as the app shows it: without the core's "§…" suffix. */
fun displayName(tag: String): String = tag.substringBefore('§').trim()
