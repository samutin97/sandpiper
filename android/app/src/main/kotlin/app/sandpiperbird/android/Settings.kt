package app.sandpiperbird.android

import android.content.Context
import android.content.pm.ApplicationInfo
import android.util.Base64
import app.sandpiperbird.android.bg.RelayService
import app.sandpiperbird.android.bg.TunnelService
import app.sandpiperbird.android.constant.PerAppProxyMode
import app.sandpiperbird.android.constant.ServiceMode
import app.sandpiperbird.android.constant.SettingsKey
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File
import java.io.ObjectInputStream


object Settings {

    private val debuggable by lazy {
        (Application.application.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }

    private val preferences by lazy {
        val context = Application.application.applicationContext
        context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    }

    private const val LIST_IDENTIFIER = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"

    var perAppProxyMode: String
        get() = preferences.getString(SettingsKey.PER_APP_PROXY_MODE, PerAppProxyMode.EXCLUDE)!!
        set(value) = preferences.edit().putString(SettingsKey.PER_APP_PROXY_MODE, value).apply()

    // Older versions saved it as the mode's "off". The tile can start the VPN before the app moves it.
    val perAppProxyEnabled: Boolean
        get() = preferences.getBoolean(
            SettingsKey.PER_APP_PROXY_ENABLED,
            preferences.getString(SettingsKey.PER_APP_PROXY_MODE, PerAppProxyMode.OFF) != PerAppProxyMode.OFF
        )

    val perAppProxyList: List<String>
        get() {
            val stringValue = if (perAppProxyMode == PerAppProxyMode.INCLUDE) {
                preferences.getString(SettingsKey.PER_APP_PROXY_INCLUDE_LIST, "")!!
            } else {
                preferences.getString(SettingsKey.PER_APP_PROXY_EXCLUDE_LIST, "")!!
            }
            if (!stringValue.startsWith(LIST_IDENTIFIER)) {
                return stringValue.split(";")
            }
            return try {
                decodeListString(stringValue.substring(LIST_IDENTIFIER.length))
            } catch (e: java.lang.Exception) {
                emptyList()
            }
        }

    /**
     * shared_preferences keeps a list as the prefix, then "!" and JSON (2.3+), or base64 of a Java
     * serialized list (older). L-09: the old form is read with only the classes a list of strings
     * needs; anything else is refused instead of instantiated.
     */
    private fun decodeListString(listString: String): List<String> {
        if (listString.startsWith("!")) {
            val array = org.json.JSONArray(listString.substring(1))
            return List(array.length()) { array.getString(it) }
        }
        val allowed = setOf("java.util.ArrayList", "java.util.List", "java.lang.String")
        val stream = object : ObjectInputStream(ByteArrayInputStream(Base64.decode(listString, 0))) {
            override fun resolveClass(desc: java.io.ObjectStreamClass): Class<*> {
                if (desc.name !in allowed) throw java.io.InvalidClassException(desc.name, "not allowed")
                return super.resolveClass(desc)
            }
        }
        return (stream.readObject() as List<*>).map { it as String }
    }

    var activeConfigPath: String
        get() = preferences.getString(SettingsKey.ACTIVE_CONFIG_PATH, "")!!
        set(value) = preferences.edit().putString(SettingsKey.ACTIVE_CONFIG_PATH, value).apply()

    var activeProfileName: String
        get() = preferences.getString(SettingsKey.ACTIVE_PROFILE_NAME, "")!!
        set(value) = preferences.edit().putString(SettingsKey.ACTIVE_PROFILE_NAME, value).apply()

    var serviceMode: String
        get() = preferences.getString(SettingsKey.SERVICE_MODE, ServiceMode.VPN)!!
        set(value) = preferences.edit().putString(SettingsKey.SERVICE_MODE, value).apply()

    var configOptions: String
        get() = preferences.getString(SettingsKey.CONFIG_OPTIONS, "")!!
        set(value) = preferences.edit().putString(SettingsKey.CONFIG_OPTIONS, value).apply()

    /**
     * The core's debug mode (goroutine snapshots, debug files): only in a debuggable APK, whatever the
     * app sends (D-10). The release's Dart side sends false (kDebugMode); this holds even if it did not.
     */
    var debugMode: Boolean
        get() = debuggable && preferences.getBoolean(SettingsKey.DEBUG_MODE, false)
        set(value) = preferences.edit().putBoolean(SettingsKey.DEBUG_MODE, value).apply()

    var disableMemoryLimit: Boolean
        get() = preferences.getBoolean(SettingsKey.DISABLE_MEMORY_LIMIT, true)
        set(value) =
            preferences.edit().putBoolean(SettingsKey.DISABLE_MEMORY_LIMIT, value).apply()

    var dynamicNotification: Boolean
        get() = preferences.getBoolean(SettingsKey.DYNAMIC_NOTIFICATION, true)
        set(value) =
            preferences.edit().putBoolean(SettingsKey.DYNAMIC_NOTIFICATION, value).apply()

    var systemProxyEnabled: Boolean
        get() = preferences.getBoolean(SettingsKey.SYSTEM_PROXY_ENABLED, true)
        set(value) =
            preferences.edit().putBoolean(SettingsKey.SYSTEM_PROXY_ENABLED, value).apply()

    var startedByUser: Boolean
        get() = preferences.getBoolean(SettingsKey.STARTED_BY_USER, false)
        set(value) = preferences.edit().putBoolean(SettingsKey.STARTED_BY_USER, value).apply()

    fun serviceClass(): Class<*> {
        return when (serviceMode) {
            ServiceMode.VPN -> TunnelService::class.java
            else -> RelayService::class.java
        }
    }

    private var currentServiceMode : String? = null

    suspend fun rebuildServiceMode(): Boolean {
        var newMode = ServiceMode.NORMAL
        try {
            if (serviceMode == ServiceMode.VPN) {
                newMode = ServiceMode.VPN
            }
        } catch (_: Exception) {
        }
        if (currentServiceMode == newMode) {
            return false
        }
        currentServiceMode = newMode
        return true
    }

    private suspend fun needVPNService(): Boolean {
        val filePath = activeConfigPath
        if (filePath.isBlank()) return false
        val content = JSONObject(File(filePath).readText())
        val inbounds = content.getJSONArray("inbounds")
        for (index in 0 until inbounds.length()) {
            val inbound = inbounds.getJSONObject(index)
            if (inbound.getString("type") == "tun") {
                return true
            }
        }
        return false
    }

    /** The folder in files/ the Dart side uses as the core's working directory (H-05). */
    const val WORKING_DIR_NAME = "working"

    /** files/working: private storage, used until the app has passed its own (always-on start). */
    val defaultWorkingDir: File
        get() = File(Application.application.filesDir, WORKING_DIR_NAME).also { it.mkdirs() }

    var workingDir: String
        get() = preferences.getString(SettingsKey.WORKING_DIR, null) ?: defaultWorkingDir.path
        set(value) = preferences.edit().putString(SettingsKey.WORKING_DIR, value).apply()
    var tempDir: String
        get() = preferences.getString(SettingsKey.TMP_DIR, null) ?: Application.application.cacheDir.path
        set(value) = preferences.edit().putString(SettingsKey.TMP_DIR, value).apply()

    var baseDir: String
        get() = preferences.getString(SettingsKey.BASE_DIR, null) ?: Application.application.filesDir.path
        set(value) = preferences.edit().putString(SettingsKey.BASE_DIR, value).apply()



    var grpcServiceModePort: Int
        get() = preferences.getInt(SettingsKey.GRPC_PORT, 17078)!!
        set(value) = preferences.edit().putInt(SettingsKey.GRPC_PORT, value).apply()

    var startCoreAfterStartingService: Boolean
        get() = preferences.getBoolean(SettingsKey.START_CORE_ON_STARTING_SERVICE, false)
        set(value) = preferences.edit().putBoolean(SettingsKey.START_CORE_ON_STARTING_SERVICE, value).apply()


}

