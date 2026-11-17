package app.sandpiperbird.android.bg

import android.app.Service
import app.sandpiperbird.android.Application
import app.sandpiperbird.android.Settings
import app.sandpiperbird.android.constant.Action
import android.content.Intent
import com.hiddify.core.libbox.Notification

class RelayService :
    Service(),
    PlatformInterfaceWrapper {
    private val service = BoxService(this, this)

    override fun onCreate() {
        Application.initialize(this)
        super.onCreate()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // D-09: restarted by Android after the process was killed (sticky), or (SP3-02) the watchdog's
        // start: the core starts by itself, only for a proxy the user had running
        if (intent == null || intent.action == Action.RESTORE) {
            if (!Settings.startedByUser) {
                if (intent == null) stopSelf() else service.refuseStart()
                return START_NOT_STICKY
            }
            Settings.startCoreAfterStartingService = true
        }
        return service.onStartCommand()
    }

    override fun onBind(intent: Intent) = service.onBind(intent)

    override fun onDestroy() = service.onDestroy()

    override fun sendNotification(notification: Notification) = service.sendNotification(notification)

    override fun cancelNotification(identifier: String, typeID: Int) = service.cancelNotification(identifier, typeID)
}