package org.omarchy.flux.service

import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.IBinder
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import org.omarchy.flux.R
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.CaptureWatch
import org.omarchy.flux.core.DndSync
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.core.Ringer
import org.omarchy.flux.core.SmsSync
import org.omarchy.flux.protocol.PROTOCOL_VERSION
import org.omarchy.flux.protocol.cleanName
import org.omarchy.flux.ui.ClipboardSendActivity
import org.omarchy.flux.ui.MainActivity

/**
 * Keeps the LAN backend running while the app is in the background. Android
 * requires a visible notification for this.
 */
class FluxService : Service() {
    private var multicast: WifiManager.MulticastLock? = null
    private var lastBattery = -1
    private var lastCharging = false
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var calls: CallMonitor? = null

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            FluxCore.refreshWifi()
            FluxCore.rediscover()
        }

        override fun onLost(network: Network) {
            FluxCore.refreshWifi()
            FluxCore.publish()
        }
    }

    private val batteryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val (pct, charging) = Android.battery(context)
            if (pct == lastBattery && charging == lastCharging) return
            lastBattery = pct
            lastCharging = charging
            FluxCore.connectedPaired().forEach { Plugins.sendBattery(FluxCore, it) }
        }
    }

    private val dndReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == NotificationManager.ACTION_NOTIFICATION_POLICY_ACCESS_GRANTED_CHANGED) FluxCore.refresh()
            else DndSync.onLocalChange(FluxCore)
        }
    }

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) = search()
    }

    /**
     * True for [SEARCH_MS] after a trigger: the start of the service, a
     * rediscover, a dropped link, or the screen on. A rediscover comes with
     * a new network, the app on screen, a scan, and Retry. See
     * [multicastNeeded]. Only the main thread uses these fields.
     */
    private val searching = MutableStateFlow(false)
    private var searchUntil = 0L
    private var searchEnd: Job? = null

    /** Starts the time of [searching] again. It runs on the main thread. */
    private fun search() {
        searchUntil = SystemClock.elapsedRealtime() + SEARCH_MS
        searching.value = true
        if (searchEnd?.isActive == true) return
        searchEnd = scope.launch {
            // A delay counts only the time while the phone is awake. Short
            // steps end the time soon after the phone wakes from a sleep.
            while (true) {
                val left = searchUntil - SystemClock.elapsedRealtime()
                if (left <= 0) break
                delay(minOf(left, SEARCH_STEP_MS))
            }
            searching.value = false
        }
    }

    private var nsd: NsdManager? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private var scanEnd: Job? = null

    /**
     * Looks for computers for [SCAN_MS]. The phone sends its identity over UDP
     * and browses mDNS once, so that the radio does not stay busy. A tap on
     * Scan again starts a new scan.
     */
    private fun scan() {
        if (scanEnd?.isActive == true) return
        FluxCore.rediscover()
        val listener = discoveryListener()
        runCatching { nsd?.discoverServices(MDNS_TYPE, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onSuccess { discovery = listener }
        FluxCore.setScanning(true)
        scanEnd = scope.launch {
            delay(SCAN_MS)
            stopScan()
        }
    }

    private fun stopScan() {
        discovery?.let { runCatching { nsd?.stopServiceDiscovery(it) } }
        discovery = null
        FluxCore.setScanning(false)
    }

    /** Android does not accept one discovery listener for 2 scans, so each scan gets a new one. */
    private fun discoveryListener() = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(serviceType: String) = Unit
        override fun onDiscoveryStopped(serviceType: String) = Unit
        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

        override fun onServiceFound(info: NsdServiceInfo) {
            if (info.serviceName == FluxCore.local.deviceId) return
            resolve(info)
        }
    }

    /**
     * fluxd announces _flux._udp over mDNS. Flux answers a
     * found host with a unicast identity, and the host then connects.
     */
    @Suppress("DEPRECATION")
    private fun resolve(info: NsdServiceInfo) {
        runCatching {
            nsd?.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
                override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                    serviceInfo.host?.let { FluxCore.announceTo(it) }
                }
            })
        }
    }

    private var announced: Pair<Int, String>? = null
    private var registration: NsdManager.RegistrationListener? = null

    /**
     * Announces this phone as _flux._udp over mDNS. A computer that
     * blocks incoming connections finds the phone this way and connects to it.
     * The service name is the device ID. The port is the TCP link port.
     */
    private fun announce() {
        val port = FluxCore.listenPort.value
        val name = FluxCore.deviceName
        if (port == 0 || announced == port to name) return
        unannounce()
        val info = NsdServiceInfo().apply {
            serviceName = FluxCore.local.deviceId
            serviceType = MDNS_TYPE
            setPort(port)
            setAttribute("id", FluxCore.local.deviceId)
            setAttribute("name", cleanName(name))
            setAttribute("type", "phone")
            setAttribute("protocol", PROTOCOL_VERSION.toString())
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) = Unit
            override fun onServiceUnregistered(info: NsdServiceInfo) = Unit
            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                if (registration === this) {
                    registration = null
                    announced = null
                }
            }
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) = Unit
        }
        runCatching { nsd?.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener) }
            .onSuccess {
                registration = listener
                announced = port to name
            }
    }

    private fun unannounce() {
        registration?.let { runCatching { nsd?.unregisterService(it) } }
        registration = null
        announced = null
    }

    override fun onCreate() {
        super.onCreate()
        FluxCore.init(this)
        Android.createChannels(this)
        startInForeground(0)
        multicast = getSystemService(WifiManager::class.java)?.createMulticastLock("flux")?.apply {
            setReferenceCounted(false)
        }
        getSystemService(ConnectivityManager::class.java)?.registerDefaultNetworkCallback(networkCallback)
        ContextCompat.registerReceiver(this, batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
        // The system sends these broadcasts only to receivers that register at run time.
        DndSync.start(this)
        val dndChanges = IntentFilter(NotificationManager.ACTION_INTERRUPTION_FILTER_CHANGED).apply {
            addAction(NotificationManager.ACTION_NOTIFICATION_POLICY_ACCESS_GRANTED_CHANGED)
        }
        ContextCompat.registerReceiver(this, dndReceiver, dndChanges, ContextCompat.RECEIVER_NOT_EXPORTED)
        ContextCompat.registerReceiver(this, screenReceiver, IntentFilter(Intent.ACTION_SCREEN_ON), ContextCompat.RECEIVER_NOT_EXPORTED)
        CaptureWatch.refresh(this)
        FluxCore.startNetwork()
        nsd = getSystemService(NsdManager::class.java)
        scan()
        scope.launch { FluxCore.listenPort.collect { announce() } }
        scope.launch {
            FluxCore.state.map { s -> s.devices.count { it.paired && it.online } }.distinctUntilChanged().collect { startInForeground(it) }
        }
        // The multicast lock makes the Wi-Fi chip wake the phone for each
        // broadcast on the network, which uses the battery. See [multicastNeeded].
        search()
        scope.launch { FluxCore.rediscovered.collect { search() } }
        scope.launch {
            var online = emptySet<String>()
            FluxCore.state.map { s -> s.devices.filter { it.paired && it.online }.map { it.id }.toSet() }.distinctUntilChanged().collect { now ->
                if (!now.containsAll(online)) search()
                online = now
            }
        }
        scope.launch {
            combine(FluxCore.state, searching) { s, window ->
                multicastNeeded(s.scanning, s.devices.any { it.paired }, s.devices.any { it.paired && !it.online }, window)
            }
                .distinctUntilChanged()
                .collect { need -> runCatching { if (need) multicast?.acquire() else multicast?.release() } }
        }
        // Call alerts follow the switch on the device screen and the phone permission.
        scope.launch {
            FluxCore.state.map { it.callAlerts && it.callAccess }.distinctUntilChanged().collect { on ->
                if (on) {
                    calls = calls ?: CallMonitor(this@FluxService)
                    calls?.start()
                } else {
                    calls?.stop()
                }
            }
        }
        // Text messages follow the switch on the device screen and the SMS permissions.
        scope.launch {
            FluxCore.state.map { it.smsSync && it.smsAccess && it.smsSupported }.distinctUntilChanged().collect { on ->
                if (on) SmsSync.start(this@FluxService) else SmsSync.stop(this@FluxService)
                // The connected computers show or hide their Messages page.
                FluxCore.sendIdentity()
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_RING -> Ringer.stop(this)
            ACTION_APPROVE_DENY -> org.omarchy.flux.core.Approvals.deny(FluxCore)
            ACTION_TURN_OFF -> {
                FluxCore.setEnabled(false)
                return START_NOT_STICKY
            }
            ACTION_REFRESH -> {
                // The app came to the front. A permission or the network can have changed.
                FluxCore.refreshAccess()
                FluxCore.refreshWifi()
                FluxCore.rediscover()
                // The device name can change in the system settings.
                announce()
            }
            ACTION_SCAN -> scan()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        calls?.stop()
        SmsSync.stop(this)
        stopScan()
        unannounce()
        runCatching { getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(networkCallback) }
        runCatching { unregisterReceiver(batteryReceiver) }
        runCatching { unregisterReceiver(dndReceiver) }
        runCatching { unregisterReceiver(screenReceiver) }
        CaptureWatch.stop(this)
        runCatching { multicast?.release() }
        FluxCore.stopNetwork()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startInForeground(connected: Int) {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val text = when {
            connected == 0 -> "Waiting for a computer on this network"
            connected == 1 -> "1 computer connected"
            else -> "$connected computers connected"
        }
        val b = NotificationCompat.Builder(this, Android.CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_flux)
            .setContentTitle("Flux")
            .setContentText(text)
            .setContentIntent(open)
        // A copy in another app reaches the computer with 1 tap.
        if (connected > 0) {
            b.addAction(
                R.drawable.ic_content_paste_go,
                "Send clipboard",
                PendingIntent.getActivity(
                    this, 2,
                    Intent(this, ClipboardSendActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
        }
        b.addAction(
            R.drawable.ic_power_settings_new,
            "Turn off",
            PendingIntent.getService(
                this, 1, Intent(this, FluxService::class.java).setAction(ACTION_TURN_OFF),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            ),
        )
        val n = b.setOngoing(true).setSilent(true).build()
        ServiceCompat.startForeground(this, Android.ID_SERVICE, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
    }

    companion object {
        const val ACTION_STOP_RING = "org.omarchy.flux.STOP_RING"
        const val ACTION_APPROVE_DENY = "org.omarchy.flux.APPROVE_DENY"
        const val ACTION_REFRESH = "org.omarchy.flux.REFRESH"
        const val ACTION_TURN_OFF = "org.omarchy.flux.TURN_OFF"
        const val ACTION_SCAN = "org.omarchy.flux.SCAN"
        const val SCAN_MS = 10_000L

        /**
         * How long the multicast lock stays on after a trigger while a paired
         * computer is away. fluxd resolves an away phone over mDNS every 30
         * seconds, and after 10 minutes every 2 to 2.5 minutes. It also
         * broadcasts each minute. This time covers at least 1 of each.
         */
        private const val SEARCH_MS = 3 * 60_000L

        /** The longest step of the timer of [SEARCH_MS]. */
        private const val SEARCH_STEP_MS = 10_000L

        const val MDNS_TYPE = "_flux._udp"

        fun start(context: Context, action: String? = null) {
            // Flux stays off until the user turns it on again.
            FluxCore.init(context)
            if (!FluxCore.enabled) return
            val i = Intent(context, FluxService::class.java)
            if (action != null) i.action = action
            runCatching { ContextCompat.startForegroundService(context, i) }
        }
    }
}

/**
 * True when the phone holds the Wi-Fi multicast lock: while it is
 * [scanning], before the first pairing, and in the [searching] time after
 * a trigger while a paired computer is away. A paired computer finds the
 * phone at its last address without the lock, because fluxd dials that
 * address. After the phone gets a new address, fluxd finds it through
 * mDNS, or the phone answers a broadcast of fluxd. Without the lock, the
 * Wi-Fi chip can drop both.
 */
internal fun multicastNeeded(scanning: Boolean, paired: Boolean, pairedAway: Boolean, searching: Boolean): Boolean =
    scanning || !paired || (pairedAway && searching)

/** Starts Flux after the phone boots. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            FluxService.start(context)
        }
    }
}
