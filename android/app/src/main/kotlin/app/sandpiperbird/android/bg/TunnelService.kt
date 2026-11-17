package app.sandpiperbird.android.bg
import android.util.Log

import app.sandpiperbird.android.Application
import app.sandpiperbird.android.CoreCaps
import app.sandpiperbird.android.R
import app.sandpiperbird.android.Settings
import android.content.Intent
import android.content.pm.PackageManager.NameNotFoundException
import android.net.ProxyInfo
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import com.hiddify.core.libbox.Libbox
import com.hiddify.core.libbox.Notification
import app.sandpiperbird.android.constant.PerAppProxyMode
import app.sandpiperbird.android.ktx.toIpPrefix
import com.hiddify.core.libbox.TunOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

class TunnelService : VpnService(), PlatformInterfaceWrapper {

    companion object {
        private const val TAG = "A/TunnelService"

        /** The running VPN, for the network monitor. */
        @Volatile
        var current: TunnelService? = null
            private set

        /** L-03: tells the system which network carries the VPN now, for metered state and validation. */
        fun updateUnderlyingNetwork(network: android.net.Network?) {
            val service = current ?: return
            runCatching { service.setUnderlyingNetworks(network?.let { arrayOf(it) }) }
        }
    }

    private val service = BoxService(this, this)

    override fun onCreate() {
        Application.initialize(this)
        super.onCreate()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Always-on VPN: Android starts the service by itself (at boot, or after the process was
        // killed), with no app to start the core over gRPC. The flag is whatever the last start
        // left, and a connect from the app clears it, so the service came up without the core
        // and the app stayed on "Connecting".
        if (intent?.action == VpnService.SERVICE_INTERFACE) {
            Log.i(TAG, "started by always-on VPN")
            Settings.startCoreAfterStartingService = true
        } else if (intent == null) {
            // D-09: the sticky service restarted by Android after the process was killed. Only a VPN
            // the user had running comes back; one they stopped called stopSelf() and is not sticky.
            if (!Settings.startedByUser) {
                Log.i(TAG, "restarted by the system, but the VPN was stopped: not starting")
                stopSelf()
                return START_NOT_STICKY
            }
            Log.i(TAG, "restarted by the system after the process was killed: starting the last profile")
            Settings.startCoreAfterStartingService = true
        }
        return service.onStartCommand()
    }

    override fun onBind(intent: Intent): IBinder {
        val binder = super.onBind(intent)
        if (binder != null) {
            return binder
        }
        return service.onBind(intent)
    }

    /** D-01: an established TUN is held now. */
    fun hasTun(): Boolean = service.fileDescriptor != null

    override fun onDestroy() {
        if (current === this) current = null
        service.onDestroy()
    }

    override fun onRevoke() {
        runBlocking {
            withContext(Dispatchers.Main) {
                service.onRevoke()
            }
        }
    }

    /**
     * H-02: the core protects every socket that carries the tunnel (its dialer, UDP of Hysteria2/AWG,
     * DNS of the servers' names, the direct outbound), so the app may stay inside its own VPN. A socket
     * Android did not protect would go into the TUN and loop: that is an error for the core's dial, not
     * a silent loop.
     */
    override fun autoDetectInterfaceControl(fd: Int) {
        if (!protect(fd)) throw java.io.IOException("protect failed for socket $fd")
    }

    var systemProxyAvailable = false
    var systemProxyEnabled = false
    fun addIncludePackage(builder: Builder, packageName: String) {
        if (packageName == this.packageName && !CoreCaps.protectsOwnSockets) {
            Log.d("VpnService","Cannot include myself: $packageName")
            return
        }
        try {     
            Log.d("VpnService","Including $packageName")
            builder.addAllowedApplication(packageName)
        } catch (e: NameNotFoundException) {
        }
    }

    fun addExcludePackage(builder: Builder, packageName: String) {
        if (packageName == this.packageName && CoreCaps.protectsOwnSockets) {
            // the app's own requests go through the tunnel; see keepSelfOutOfVpn
            Log.d("VpnService","Not excluding myself: $packageName")
            return
        }
        try {     
            Log.d("VpnService","Excluding $packageName")
            builder.addDisallowedApplication(packageName)
        } catch (e: NameNotFoundException) {
        }
    }

    override fun openTun(options: TunOptions): Int {
        var hasPermission = false
        for (i in 0 until 20) {
            if (prepare(this) != null) {
                Log.w("VPN", "android: missing vpn permission")
            } else {
                hasPermission = true
                break
            }
            Thread.sleep(50)
        }

        if (!hasPermission) {
             error("android: missing vpn permission")
    }
//        service.fileDescriptor?.close()

        val builder = Builder()
            .setSession(getString(R.string.app_name))
            .setMtu(options.mtu)

        // L-03: no setMetered(false). The VPN is metered when the network under it is: on mobile data
        // the system and apps hold back large downloads, as without the VPN.

        val inet4Address = options.inet4Address
        while (inet4Address.hasNext()) {
            val address = inet4Address.next()
            builder.addAddress(address.address(), address.prefix())
        }

        val inet6Address = options.inet6Address
        while (inet6Address.hasNext()) {
            val address = inet6Address.next()
            builder.addAddress(address.address(), address.prefix())
        }

        if (options.autoRoute) {
            if (options.dnsMode.value != Libbox.DNSModeDisabled) {
                val dnsServerAddress = options.dnsServerAddress
                while (dnsServerAddress.hasNext()) {
                    builder.addDnsServer(dnsServerAddress.next())
                }
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val inet4RouteAddress = options.inet4RouteAddress
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        builder.addRoute(inet4RouteAddress.next().toIpPrefix())
                    }
                } else {
                    builder.addRoute("0.0.0.0", 0)
                }

                val inet6RouteAddress = options.inet6RouteAddress
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        builder.addRoute(inet6RouteAddress.next().toIpPrefix())
                    }
                } else {
                    builder.addRoute("::", 0)
                }

                val inet4RouteExcludeAddress = options.inet4RouteExcludeAddress
                while (inet4RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet4RouteExcludeAddress.next().toIpPrefix())
                }

                val inet6RouteExcludeAddress = options.inet6RouteExcludeAddress
                while (inet6RouteExcludeAddress.hasNext()) {
                    builder.excludeRoute(inet6RouteExcludeAddress.next().toIpPrefix())
                }
            } else {
                val inet4RouteAddress = options.inet4RouteRange
                if (inet4RouteAddress.hasNext()) {
                    while (inet4RouteAddress.hasNext()) {
                        val address = inet4RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                    }
                }

                val inet6RouteAddress = options.inet6RouteRange
                if (inet6RouteAddress.hasNext()) {
                    while (inet6RouteAddress.hasNext()) {
                        val address = inet6RouteAddress.next()
                        builder.addRoute(address.address(), address.prefix())
                    }
                }
            }

            // H-02: the app itself (its subscription updates, the core's own HTTP clients) stays inside
            // the VPN when the core protects the sockets that carry the tunnel; otherwise it must stay
            // out, or those sockets would loop back into the tunnel.
            val keepSelfOutOfVpn = !CoreCaps.protectsOwnSockets
            // Item 8: with the hardened core the app sends the list to the core (per-app-proxy-mode/list),
            // which filters by owner (leak B) and hands the same list back in TunOptions: that is the
            // only source then, so the filter and VpnService.Builder can not differ. The official core
            // knows no such keys: the list is read from the app's settings as before.
            if (Settings.perAppProxyEnabled && !CoreCaps.randomGrpcPorts) {
                val appList = Settings.perAppProxyList
                if (Settings.perAppProxyMode == PerAppProxyMode.INCLUDE) {
                    appList.forEach {
                        addIncludePackage(builder,it)
                    }
                    if (!keepSelfOutOfVpn) addIncludePackage(builder, packageName)
                } else {
                    appList.forEach {
                        addExcludePackage(builder,it)
                    }
                    if (keepSelfOutOfVpn) addExcludePackage(builder,packageName)
                }
            } else {
                val includePackage = options.includePackage
                if (includePackage.hasNext()) {
                    while (includePackage.hasNext()) {
                        addIncludePackage(builder,includePackage.next())
                    }
                    if (!keepSelfOutOfVpn) addIncludePackage(builder, packageName)
                }else {
                    val excludePackage = options.excludePackage
                    if (excludePackage.hasNext()) {
                        while (excludePackage.hasNext()) {
                            addExcludePackage(builder, excludePackage.next())
                        }
                    }

                    if (keepSelfOutOfVpn) addExcludePackage(builder, packageName)
                }
                
            }
        }

        if (options.isHTTPProxyEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            systemProxyAvailable = true
            systemProxyEnabled = Settings.systemProxyEnabled
            if (systemProxyEnabled) builder.setHttpProxy(
                ProxyInfo.buildDirectProxy(
                    options.httpProxyServer, options.httpProxyServerPort
                )
            )
        } else {
            systemProxyAvailable = false
            systemProxyEnabled = false
        }

        DefaultNetworkMonitor.defaultNetwork?.let { builder.setUnderlyingNetworks(arrayOf(it)) }
        val pfd = builder.establish() ?: error("android: the application is not prepared or is revoked")
        // D-06: a rebuilt tunnel (per-app list, settings) left the previous interface behind, DOWN, as
        // long as this side held its descriptor: libbox works on a dup of the fd (OpenInterface), so the
        // previous one is closed here, and the interface goes once the core closes its own copy.
        val previous = service.fileDescriptor
        service.fileDescriptor = pfd
        if (previous != null && previous !== pfd) runCatching { previous.close() }
        current = this
        return pfd.fd
    }

//    override fun writeLog(message: String) = service.writeLog(message)

    override fun sendNotification(notification: Notification) {
//        service.sendNotification(notification)
    }

    override fun cancelNotification(identifier: String, typeID: Int) = service.cancelNotification(identifier, typeID)
}