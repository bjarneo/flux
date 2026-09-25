package org.omarchy.flux.service

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
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import org.omarchy.flux.R
import org.omarchy.flux.core.Android
import org.omarchy.flux.core.FluxCore
import org.omarchy.flux.core.Plugins
import org.omarchy.flux.core.Ringer
import org.omarchy.flux.protocol.PROTOCOL_VERSION
import org.omarchy.flux.protocol.cleanName
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
            FluxCore.rediscover()
        }

        override fun onLost(network: Network) {
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

    private var nsd: NsdManager? = null
    private val nsdListener = object : NsdManager.DiscoveryListener {
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
     * KDE Connect desktops announce _kdeconnect._udp over mDNS. Flux answers a
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
     * Announces this phone as _kdeconnect._udp over mDNS. A computer that
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
            acquire()
        }
        getSystemService(ConnectivityManager::class.java)?.registerDefaultNetworkCallback(networkCallback)
        ContextCompat.registerReceiver(this, batteryReceiver, IntentFilter(Intent.ACTION_BATTERY_CHANGED), ContextCompat.RECEIVER_NOT_EXPORTED)
        FluxCore.startNetwork()
        nsd = getSystemService(NsdManager::class.java)
        runCatching { nsd?.discoverServices(MDNS_TYPE, NsdManager.PROTOCOL_DNS_SD, nsdListener) }
        scope.launch { FluxCore.listenPort.collect { announce() } }
        scope.launch {
            FluxCore.state.map { s -> s.devices.count { it.paired && it.online } }.distinctUntilChanged().collect { startInForeground(it) }
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
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_RING -> Ringer.stop(this)
            ACTION_REFRESH -> {
                FluxCore.rediscover()
                // The device name can change in the system settings.
                announce()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        calls?.stop()
        runCatching { nsd?.stopServiceDiscovery(nsdListener) }
        unannounce()
        runCatching { getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(networkCallback) }
        runCatching { unregisterReceiver(batteryReceiver) }
        multicast?.release()
        FluxCore.stopNetwork()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startInForeground(connected: Int) {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val text = when (connected) {
            0 -> "Waiting for a computer on this network"
            1 -> "1 computer connected"
            else -> "$connected computers connected"
        }
        val n = NotificationCompat.Builder(this, Android.CHANNEL_SERVICE)
            .setSmallIcon(R.drawable.ic_stat_flux)
            .setContentTitle("Flux")
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setSilent(true)
            .build()
        ServiceCompat.startForeground(this, Android.ID_SERVICE, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
    }

    companion object {
        const val ACTION_STOP_RING = "org.omarchy.flux.STOP_RING"
        const val ACTION_REFRESH = "org.omarchy.flux.REFRESH"
        const val MDNS_TYPE = "_kdeconnect._udp"

        fun start(context: Context, action: String? = null) {
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
