package app.sandpiperbird.android

import android.app.Activity
import android.content.Intent
import android.content.pm.ShortcutManager
import android.os.Build
import android.os.Bundle
import androidx.core.content.getSystemService
import app.sandpiperbird.android.bg.BoxService
import app.sandpiperbird.android.bg.ServiceConnection
import app.sandpiperbird.android.constant.Status

/**
 * Turns the VPN on or off: the target of the "Toggle" shortcut.
 *
 * Not exported. Android launches a shortcut, static (res/xml/shortcuts.xml) or pinned on Android 8+,
 * on behalf of the app that published it, so the shortcut reaches this activity while no other app
 * can: before, the exported ShortcutActivity let any app turn the VPN off or on with one
 * startActivity, with no dialog. On Android 7 a pinned shortcut is launched by the launcher itself;
 * it goes through [ShortcutCreateActivity], which checks the shortcut's secret token.
 */
class ToggleActivity : Activity(), ServiceConnection.Callback {

    private val connection = ServiceConnection(this, this, false)

    override fun onCreate(savedInstanceState: Bundle?) {
        Application.initialize(this)
        super.onCreate(savedInstanceState)
        if (intent?.action != Intent.ACTION_MAIN) {
            finish()
            return
        }
        connection.connect()
        if (Build.VERSION.SDK_INT >= 25) {
            getSystemService<ShortcutManager>()?.reportShortcutUsed(ShortcutCreateActivity.SHORTCUT_ID)
        }
        moveTaskToBack(true)
    }

    override fun onServiceStatusChanged(status: Status) {
        when (status) {
            Status.Started -> BoxService.stop()
            Status.Stopped -> {
                // No app UI starts the core over gRPC here, so the service must start it itself.
                Settings.startCoreAfterStartingService = true
                BoxService.start()
            }
            else -> {}
        }
        finish()
    }

    override fun onDestroy() {
        connection.disconnect()
        super.onDestroy()
    }
}
