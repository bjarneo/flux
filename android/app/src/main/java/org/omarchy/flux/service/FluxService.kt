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
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import org.omarchy.flux.R
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.CaptureWatch
import org.omarchy.flux.core.ClipWatch
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

    /** The count of connected computers on the notification, so a clip-state change re-renders it. */
    private var connectedCount = 0

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
        CaptureWatch.refresh(this)
        FluxCore.startNetwork()
        nsd = getSystemService(NsdManager::class.java)
        scan()
        scope.launch { FluxCore.listenPort.collect { announce() } }
        scope.launch {
            FluxCore.state.map { s -> s.devices.count { it.paired && it.online } }.distinctUntilChanged().collect { startInForeground(it) }
        }
        // The needs-consent state changes the notification text, so re-render it.
        scope.launch {
            FluxCore.state.map { it.clipAuto }.distinctUntilChanged().collect { startInForeground(connectedCount) }
        }
        // The multicast lock makes the Wi-Fi chip wake the phone for each
        // broadcast on the network, which uses the battery. Flux needs it
        // only to find computers: during a scan, before the first pairing,
        // and while a paired computer is away.
        scope.launch {
            FluxCore.state.map { s -> s.scanning || s.devices.none { it.paired } || s.devices.any { it.paired && !it.online } }
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
                // Flux is on top now, so the log-access dialog can show.
                ClipWatch.refresh(this)
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
        CaptureWatch.stop(this)
        ClipWatch.stop()
        runCatching { multicast?.release() }
        FluxCore.stopNetwork()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startInForeground(connected: Int) {
        connectedCount = connected
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val needsConsent = FluxCore.state.value.clipAuto == org.omarchy.flux.core.ClipAutoState.NeedsConsent
        val text = when {
            needsConsent -> "Open Flux to resume clipboard sync"
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
                        .putExtra(ClipboardSendActivity.EXTRA_MANUAL, true)
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

/** Starts Flux after the phone boots. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            FluxService.start(context)
        }
    }
}
