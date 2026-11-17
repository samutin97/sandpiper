package app.sandpiperbird.android.constant

object Action {
    const val SERVICE = "app.sandpiperbird.android.SERVICE"
    const val SERVICE_CLOSE = "app.sandpiperbird.android.SERVICE_CLOSE"

    /** SP3-02: the service started again without the app (the watchdog, or the user's tap on its notice). */
    const val RESTORE = "app.sandpiperbird.android.RESTORE"

    /** The watchdog's alarm (TunnelWatchdogReceiver). */
    const val WATCHDOG = "app.sandpiperbird.android.WATCHDOG"
}