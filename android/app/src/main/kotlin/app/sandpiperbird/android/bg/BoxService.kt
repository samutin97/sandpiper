package app.sandpiperbird.android.bg

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import app.sandpiperbird.android.Application
import app.sandpiperbird.android.R
import app.sandpiperbird.android.CoreCaps
import app.sandpiperbird.android.Settings
import app.sandpiperbird.android.constant.Action
import app.sandpiperbird.android.constant.Alert
import app.sandpiperbird.android.constant.Status
import app.sandpiperbird.android.utils.DeviceMemory
import app.sandpiperbird.android.utils.GrpcClientProvider
import com.hiddify.core.mobile.SetupOptions

import go.Seq
import com.hiddify.core.libbox.Libbox
import com.hiddify.core.mobile.Mobile


import com.hiddify.core.libbox.CommandServer
import com.hiddify.core.libbox.CommandServerHandler
import com.hiddify.core.libbox.Notification
import com.hiddify.core.libbox.PlatformInterface
import com.hiddify.core.libbox.SystemProxyStatus
import app.sandpiperbird.android.BuildConfig
import app.sandpiperbird.android.MainActivity
import app.sandpiperbird.android.constant.Bugs
import kotlinx.coroutines.DelicateCoroutinesApi
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import java.io.File

class BoxService(
        private val service: Service,
        private val platformInterface: PlatformInterface
)  {

    companion object {
        private const val TAG = "A/BoxService"

        // The running service's platform interface. The core keeps one per process, and the front
        // core's setup would replace it with null, so MethodHandler passes this one instead.
        @Volatile
        var activePlatformInterface: PlatformInterface? = null
            private set

        /**
         * SP3-02: a service of this process is starting, runs or holds its TUN. In a process Android
         * started again after a kill it is false, which is how the watchdog (TunnelWatchdog) tells
         * that the tunnel is gone.
         */
        @Volatile
        var running = false
            private set

        private var initializeOnce = false
        private lateinit var workingDir: File
        private fun initialize() {
            if (initializeOnce) return
            val baseDir = Application.application.filesDir

            baseDir.mkdirs()
            // H-05: private storage, as the Dart side's working directory (files/working)
            workingDir = Settings.defaultWorkingDir
            workingDir.mkdirs()
            val tempDir = Application.application.cacheDir
            tempDir.mkdirs()
            Log.d(TAG, "base dir: ${baseDir.path}")
            Log.d(TAG, "working dir: ${workingDir.path}")
            Log.d(TAG, "temp dir: ${tempDir.path}")

//
            //Mobile.setup(baseDir.path, workingDir.path, tempDir.path,  2L ,"127.0.0.1:{Setting}","",false,this)
//            Libbox.setup(baseDir.path, workingDir.path, tempDir.path, false)

//            Libbox.setup(SetupOptions().also {
//                it.basePath = baseDir.path
//                it.workingPath = workingDir.path
//                it.tempPath = tempDir.path
//                it.fixAndroidStack = Bugs.fixAndroidStack
//
//            })
            Libbox.redirectStderr(File(Settings.workingDir, "stderr.log").path)
            initializeOnce = true
            return
        }

        fun start() {
            val intent = runBlocking {
                withContext(Dispatchers.IO) {
                    Intent(Application.application, Settings.serviceClass())
                }
            }
            // Android 12+ refuses a foreground start from the background with an exception; the
            // callers (boot receiver, tile, shortcut) have nobody to report it to.
            try {
                ContextCompat.startForegroundService(Application.application, intent)
            } catch (e: Exception) {
                Log.e(TAG, "cannot start the service", e)
            }
        }

        fun stop() {
            Application.application.sendBroadcast(
                    Intent(Action.SERVICE_CLOSE).setPackage(
                            Application.application.packageName
                    )
            )
        }


    }

    var fileDescriptor: ParcelFileDescriptor? = null

    /** SP3-02: [fileDescriptor] is the blocking TUN of a start without the app, not the core's. */
    var tunIsBlocking = false

    private val status = MutableLiveData(Status.Stopped)
    private val binder = ServiceBinder(status)
    private val notification = ServiceNotification(status, service)
//    private var boxService: BoxService? = null
    private var commandServer: CommandServer? = null
    private var receiverRegistered = false
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                Action.SERVICE_CLOSE -> {
                    stopService()
                }

                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        // a receiver runs on the main thread, and waking the core is a call into it
                        GlobalScope.launch(Dispatchers.IO) { serviceUpdateIdleMode() }
                    }
                }
            }
        }
    }
    


    private var activeProfileName = ""

    /// Mode last passed to Mobile.setup for the VPN gRPC server (2 mTLS / 4 insecure).
    private var grpcSetupMode: Long = 4L

    private suspend fun startService() {
        try {
            status.postValue(Status.Starting)
            Log.d(TAG, "starting service")
            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, R.string.status_starting)
            }

            val selectedConfigPath = Settings.activeConfigPath
            if (selectedConfigPath.isBlank()) {
                stopAndAlert(Alert.EmptyConfiguration)
                return
            }

            activeProfileName = Settings.activeProfileName

            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, R.string.status_starting)
                binder.broadcast {
                    it.onServiceResetLogs(listOf())
                }
            }

            DefaultNetworkMonitor.start()
            Libbox.setMemoryLimit(!Settings.disableMemoryLimit)
            activePlatformInterface = platformInterface
            // 2 = GRPC_BACKGROUND (mTLS), always: never 4 (GRPC_BACKGROUND_INSECURE, plain HTTP/2 that any
            // app could call). Without the app's client identity (Always-on before the app ever ran) the
            // server starts but no client gets in; the VPN runs without it. Must match Mobile.close.
            grpcSetupMode = 2L
            if (!GrpcClientProvider.usesMutualTls) Log.w(TAG, "no gRPC client identity yet: the service runs without control clients")
            try {
                Mobile.setup(
                    SetupOptions().also {
                        it.basePath = Settings.baseDir
                        it.workingDir = Settings.workingDir
                        it.tempDir = Settings.tempDir
                        it.fixAndroidStack = app.sandpiperbird.android.bg.Bugs.fixAndroidStack
                        it.mode = grpcSetupMode
                        it.listen = CoreCaps.listenFor(Settings.grpcServiceModePort)
                        CoreCaps.setDataPath(it, Settings.workingDir)
                        it.secret = ""
                        it.debug = Settings.debugMode
                        DeviceMemory.applyTo(it)
                    },
                    platformInterface,
                )
                // the core trusts the client certificate stored in the base folder by itself
                if (CoreCaps.randomGrpcPorts) {
                    // the free port the core took, for this service's own client (notification stats)
                    CoreCaps.listenPort(grpcSetupMode).takeIf { it > 0 }?.let { Settings.grpcServiceModePort = it }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Mobile.setup failed", e)
                stopAndAlert(Alert.CreateService, e.message ?: e.toString())
                return
            }
            status.postValue(Status.Started)

            if (Settings.startCoreAfterStartingService){
                Mobile.start("","")
                }
            // SP3-02: the second way back after the process is killed, beside START_STICKY
            if (Settings.startedByUser) TunnelWatchdog.arm(service)
//            if (delayStart) {
//                delay(1000L)
//            }

//            newService.start()
//            boxService = newService
//            commandServer?.setService(boxService)


            withContext(Dispatchers.Main) {
                notification.show(activeProfileName, R.string.status_started)
            }
            notification.start()
        } catch (e: Exception) {
            stopAndAlert(Alert.StartService, e.message)
            return
        }
    }

    fun serviceReload() {
        runBlocking {
            serviceReload0()
        }
    }

    suspend fun serviceReload0() {
        notification.close()
        status.postValue(Status.Starting)

        val pfd = fileDescriptor
        if (pfd != null) {
            pfd.close()
            fileDescriptor = null
        }
        
//        boxService?.apply {
//            runCatching {
//                close()
//            }.onFailure {
//                writeLog("service: error when closing: $it")
//            }
//            Seq.destroyRef(refnum)
//        }
        Mobile.stop()
//        boxService = null
        
            startService()
        
    }

    fun getSystemProxyStatus(): SystemProxyStatus {
        val status = SystemProxyStatus()
        if (service is TunnelService) {
            status.available = service.systemProxyAvailable
            status.enabled = service.systemProxyEnabled
        }
        return status
    }

    fun setSystemProxyEnabled(isEnabled: Boolean) {
        serviceReload()
    }

    @RequiresApi(Build.VERSION_CODES.M)
    private fun serviceUpdateIdleMode() {
        if (Application.powerManager.isDeviceIdleMode) {
//            boxService?.pause()
            //Mobile.pause()
        } else {
            Mobile.wake()
//            boxService?.wake()
        }
    }

    private fun stopService() {
        if (status.value == Status.Stopped) {
            // D-09: after a failed start (stopAndAlert) the service keeps the TUN it had, so traffic is
            // dropped rather than sent around the VPN until the user reconnects; a stop by the user
            // then has to release it, or the device stays without a network.
            fileDescriptor?.let { pfd ->
                Log.i(TAG, "stop after a failure: releasing the TUN")
                runCatching { pfd.close() }
                fileDescriptor = null
            }
            if (receiverRegistered) {
                service.unregisterReceiver(receiver)
                receiverRegistered = false
            }
            Settings.startedByUser = false
            TunnelWatchdog.disarm(service)
            notification.close()
            service.stopSelf()
            return
        }
        status.value = Status.Stopping
        if (receiverRegistered) {
            service.unregisterReceiver(receiver)
            receiverRegistered = false
        }
        notification.close()
        GlobalScope.launch(Dispatchers.IO) {
            val pfd = fileDescriptor
            if (pfd != null) {
                pfd.close()
                fileDescriptor = null
            }
//            commandServer?.setService(null)
//            boxService?.apply {
//                runCatching {
//                    close()
//                }.onFailure {
//                    writeLog("service: error when closing: $it")
//                }
//                //Seq.destroyRef(refnum)
//            }

//            boxService = null
//            Libbox.registerLocalDNSTransport(null)
            DefaultNetworkMonitor.stop()

//            commandServer?.apply {
//                close()
//                Seq.destroyRef(refnum)
//            }
//            commandServer = null
            Settings.startedByUser = false
            TunnelWatchdog.disarm(service)
            if (activePlatformInterface === platformInterface) activePlatformInterface = null
            // Close the mode we actually started. Old code always closed 4 (insecure), so
            // mTLS background (mode 2) left :17079 listening and reconnect failed with
            // "background service did not stop".
            // Closing stops the core, which can take seconds: never on the main thread, or the
            // app freezes while it disconnects.
            val closeStart = System.currentTimeMillis()
            for (mode in linkedSetOf(grpcSetupMode, 2L, 4L)) {
                Mobile.close(mode)
            }
            Log.i(TAG, "core closed in ${System.currentTimeMillis() - closeStart}ms")
            withContext(Dispatchers.Main) {
                status.value = Status.Stopped
                service.stopSelf()
            }
            notification.close()
        }
    }

    private suspend fun stopAndAlert(type: Alert, message: String? = null) {
        Settings.startedByUser = false
        TunnelWatchdog.disarm(service)
        withContext(Dispatchers.Main) {
            // D-09: a TUN still held (fail-closed) is released by the user's stop, which comes as the
            // close broadcast: the receiver stays while it is held
            if (receiverRegistered && fileDescriptor == null) {
                service.unregisterReceiver(receiver)
                receiverRegistered = false
            }
            if (fileDescriptor != null) {
                // SP3-02: say so (a start without the app has nobody else to tell), with the Stop that
                // releases the TUN; the service stays in the foreground while it holds it
                runCatching { notification.show(activeProfileName, R.string.status_blocked) }
                    .onFailure { notification.close() }
            } else {
                notification.close()
            }
            binder.broadcast { callback ->
                callback.onServiceAlert(type.ordinal, message)
            }
            status.value = Status.Stopped
        }
    }

    /**
     * D-09: START_STICKY. When the process is killed (low memory, a vendor's task killer, kill -9) while
     * the VPN runs, Android may start the service again with a null intent (when it does is up to
     * Android: on some builds it waits until the app's process starts for another reason), and it
     * brings the VPN back with the last profile (Settings.activeConfigPath) by itself, without the
     * app's UI. SP3-02: TunnelWatchdog is the second way back. A stop by the user calls stopSelf() and
     * cancels the watchdog, so a stopped VPN is not brought back.
     */
    @OptIn(DelicateCoroutinesApi::class)
    @Suppress("SameReturnValue")
    internal fun onStartCommand(): Int {
        // Already up, and in the foreground: ignore duplicate start intents.
        if (status.value == Status.Started) {
            return Service.START_STICKY
        }
        // Every start comes through startForegroundService, and Android kills the app ("did not
        // then call Service.startForeground()") when the service stops, or 10 seconds pass,
        // before startForeground is called. So go to the foreground here, on the main thread,
        // before anything slow (loading the core at boot) and before the returns below: a start
        // that arrives while a stop is still closing the core used to return without it, and
        // the stop's stopSelf() then crashed the app.
        try {
            notification.show(activeProfileName, R.string.status_starting)
        } catch (e: Exception) {
            Log.e(TAG, "cannot go to the foreground", e)
        }
        if (status.value == Status.Starting) {
            return Service.START_STICKY
        }
        // A stop is still tearing down Mobile/VPN; wait then start so reconnect
        // after disconnect does not hit CreateService from a raced Mobile.setup.
        if (status.value == Status.Stopping) {
            GlobalScope.launch(Dispatchers.IO) {
                var i = 0
                while (status.value == Status.Stopping && i < 50) {
                    delay(200)
                    i++
                }
                if (status.value == Status.Stopped) start()
            }
            return Service.START_STICKY
        }
        status.value = Status.Starting
        running = true

        if (!receiverRegistered) {
            ContextCompat.registerReceiver(service, receiver, IntentFilter().apply {
                addAction(Action.SERVICE_CLOSE)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
                }
            }, ContextCompat.RECEIVER_NOT_EXPORTED)
            receiverRegistered = true
        }

        GlobalScope.launch(Dispatchers.IO) {
            Settings.startedByUser = true
            initialize()
//            try {
//                startCommandServer()
//            } catch (e: Exception) {
//                stopAndAlert(Alert.StartCommandServer, e.message)
//                return@launch
//            }
            startService()
        }
        return Service.START_STICKY
    }

    fun onBind(intent: Intent): IBinder {
        return binder
    }

    /** SP3-02: nothing started and no TUN held: a start without the app may hold a blocking TUN first. */
    fun isIdle(): Boolean = status.value == Status.Stopped && fileDescriptor == null

    /** SP3-02: holds [pfd], a TUN nothing reads, until the core's own replaces it (openTun) or a stop. */
    fun holdTun(pfd: ParcelFileDescriptor) {
        val previous = synchronized(tunLock) {
            val previous = fileDescriptor
            fileDescriptor = pfd
            tunIsBlocking = true
            previous
        }
        previous?.let { runCatching { it.close() } }
        running = true
    }

    private val tunLock = Any()

    /** The core's TUN [pfd] replaces the one held (a blocking one, or the core's previous); returns that. */
    fun takeCoreTun(pfd: ParcelFileDescriptor): ParcelFileDescriptor? = synchronized(tunLock) {
        val previous = fileDescriptor
        fileDescriptor = pfd
        tunIsBlocking = false
        previous
    }

    /**
     * SP4-01: the blocking TUN of a start by the user, if the core's TUN has not replaced it by now:
     * the start failed. A failed start of the service (stopped with an alert) stops as a Stop would;
     * a core that never opened its TUN leaves the service as it was without the blocking TUN. A
     * start without the app keeps its blocking TUN until the user's Stop (SP3-02), and does not
     * come here. Runs on the main thread.
     */
    fun releaseBlockingTun(pfd: ParcelFileDescriptor) {
        val released = synchronized(tunLock) {
            if (!tunIsBlocking || fileDescriptor !== pfd) return
            if (status.value == Status.Stopped) null else pfd.also { fileDescriptor = null }
        }
        Log.i(TAG, "the core's TUN did not come: releasing the blocking TUN")
        if (released == null) {
            stopService()
        } else {
            runCatching { released.close() }
        }
    }

    /**
     * A start the service must not act on (the watchdog's, after the user stopped the tunnel). It came
     * through startForegroundService, so the service still goes to the foreground before it stops, or
     * Android ends the process.
     */
    fun refuseStart() {
        runCatching { notification.show(activeProfileName, R.string.status_starting) }
        notification.close()
        service.stopSelf()
    }

    fun onDestroy() {
        running = false
        if (receiverRegistered) {
            runCatching { service.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
        if (activePlatformInterface === platformInterface) activePlatformInterface = null
        binder.close()
    }

    fun onRevoke() {
        stopService()
    }

    internal fun sendNotification(notification: Notification) {
        return
        val builder =
            NotificationCompat.Builder(service, notification.identifier).setShowWhen(false)
                .setContentTitle(notification.title).setContentText(notification.body)
                .setOnlyAlertOnce(true).setSmallIcon(R.drawable.ic_launcher_foreground)
                .setCategory(NotificationCompat.CATEGORY_EVENT)
                .setPriority(NotificationCompat.PRIORITY_HIGH).setAutoCancel(true)
        if (!notification.subtitle.isNullOrBlank()) {
            builder.setContentInfo(notification.subtitle)
        }
        if (!notification.openURL.isNullOrBlank()) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    service,
                    0,
                    Intent(
                        service,
                        MainActivity::class.java,
                    ).apply {
                        setAction(Action.SERVICE).setData(Uri.parse(notification.openURL))
                        setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                    },
                    ServiceNotification.flags,
                ),
            )
        }
        GlobalScope.launch(Dispatchers.Main) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Application.notification.createNotificationChannel(
                    NotificationChannel(
                        notification.identifier,
                        notification.typeName,
                        NotificationManager.IMPORTANCE_HIGH,
                    ),
                )
            }
            Application.notification.notify(notification.identifier, notification.typeID, builder.build())
        }
    }

    internal fun cancelNotification(identifier: String, typeID: Int) {
        GlobalScope.launch(Dispatchers.Main) {
            Application.notification.cancel(identifier, typeID)
        }
    }

     fun writeDebugMessage(message: String?) {
        Log.d("BoxService", message!!)
        binder.broadcast {
            it.onServiceWriteLog(message)
        }
    }

}