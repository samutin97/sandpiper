package app.sandpiperbird.android

import android.util.Log

/** What the core in this build can do, for the features that need the core's side too. */
object CoreCaps {
    private const val TAG = "A/CoreCaps"

    /**
     * True when the core protects (VpnService.protect) every socket its dialer opens, so the app may
     * stay inside its own VPN without a routing loop. The core of upstream 5.9.8 does not
     * (auto_detect_interface is off on Android): with it the app must keep itself out of the VPN, and
     * its own requests go around the tunnel. Asked by reflection, so the app builds with either core.
     */
    val protectsOwnSockets: Boolean by lazy {
        val protects = try {
            val method = Class.forName("com.hiddify.core.mobile.Mobile").getMethod("protectsOwnSockets")
            (method.invoke(null) as? Boolean) == true
        } catch (_: NoSuchMethodException) {
            false
        } catch (e: Throwable) {
            Log.w(TAG, "protectsOwnSockets", e)
            false
        }
        Log.i(TAG, "core protects its own sockets: $protects")
        protects
    }

    private val getListenAddress by lazy {
        runCatching {
            Class.forName("com.hiddify.core.mobile.Mobile").getMethod("getListenAddress", Long::class.javaPrimitiveType)
        }.getOrNull()
    }

    /**
     * M-01/HC-05: the hardened core takes "127.0.0.1:0" (a free port each start) and tells the port it
     * took; then the control servers have no fixed, recognisable port (17078/17079). The core of
     * upstream 5.9.8 can not tell it, so it keeps the fixed ports.
     */
    val randomGrpcPorts: Boolean
        get() = getListenAddress != null

    /** The address the core's control server of [mode] (1 app, 2 VPN service) listens on, or "". */
    fun listenAddress(mode: Long): String = try {
        getListenAddress?.invoke(null, mode) as? String ?: ""
    } catch (e: Throwable) {
        Log.w(TAG, "getListenAddress", e)
        ""
    }

    /** The TCP port of [listenAddress], 0 when not known. */
    fun listenPort(mode: Long): Int = listenAddress(mode).substringAfterLast(':', "").toIntOrNull() ?: 0

    /** The listen address to give Mobile.setup: a free port when the core reports it, else [fixedPort]. */
    fun listenFor(fixedPort: Int): String = if (randomGrpcPorts) "127.0.0.1:0" else "127.0.0.1:$fixedPort"

    /**
     * H-05/P9: where the core keeps its database, cache and logs. The working directory (private
     * storage), where the app reads the core's log. Ignored by a core without the field.
     */
    fun setDataPath(options: Any, path: String) {
        try {
            options.javaClass.getMethod("setDataPath", String::class.java).invoke(options, path)
        } catch (_: NoSuchMethodException) {
        } catch (e: Throwable) {
            Log.w(TAG, "setDataPath", e)
        }
    }
}
