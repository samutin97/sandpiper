package app.sandpiperbird.android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Base64
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import java.security.MessageDigest
import java.security.SecureRandom

/**
 * The only exported entry for the "Toggle" shortcut: a launcher asks it (CREATE_SHORTCUT) for a shortcut
 * to pin, and gets one that starts the not exported [ToggleActivity]. It never toggles the VPN for an
 * intent of another app.
 *
 * Android 7 has no pinned shortcuts: there the launcher keeps a plain intent and starts it as itself,
 * which can not reach a not exported activity. That intent comes back here, with a random token only
 * this app and the launcher's shortcut know; any intent without the right token is ignored.
 */
class ShortcutCreateActivity : Activity() {

    companion object {
        const val SHORTCUT_ID = "toggle"
        private const val ACTION_LEGACY_TOGGLE = "app.shortcut.TOGGLE"
        private const val EXTRA_TOKEN = "token"
        private const val PREFS = "shortcut"
        private const val KEY_TOKEN = "token"

        private fun token(context: Context): String {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            prefs.getString(KEY_TOKEN, null)?.let { return it }
            val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
            val token = Base64.encodeToString(bytes, Base64.NO_WRAP or Base64.URL_SAFE)
            prefs.edit().putString(KEY_TOKEN, token).apply()
            return token
        }

        private fun tokenMatches(context: Context, given: String?): Boolean {
            if (given.isNullOrEmpty()) return false
            val expected = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_TOKEN, null)
                ?: return false
            return MessageDigest.isEqual(expected.toByteArray(), given.toByteArray())
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        Application.initialize(this)
        super.onCreate(savedInstanceState)
        when (intent?.action) {
            Intent.ACTION_CREATE_SHORTCUT -> setResult(RESULT_OK, createShortcut())
            ACTION_LEGACY_TOGGLE -> if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O &&
                tokenMatches(this, intent.getStringExtra(EXTRA_TOKEN))
            ) {
                startActivity(Intent(this, ToggleActivity::class.java).setAction(Intent.ACTION_MAIN))
            }
            else -> {}
        }
        finish()
    }

    private fun createShortcut(): Intent {
        val target = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // a pinned shortcut: Android starts it as this app, so the activity needs no export
            Intent(this, ToggleActivity::class.java).setAction(Intent.ACTION_MAIN)
        } else {
            Intent(this, ShortcutCreateActivity::class.java)
                .setAction(ACTION_LEGACY_TOGGLE)
                .putExtra(EXTRA_TOKEN, token(this))
        }
        return ShortcutManagerCompat.createShortcutResultIntent(
            this,
            ShortcutInfoCompat.Builder(this, SHORTCUT_ID)
                .setIntent(target)
                .setIcon(IconCompat.createWithResource(this, R.mipmap.ic_launcher))
                .setShortLabel(getString(R.string.quick_toggle))
                .build(),
        )
    }
}
