package org.omarchy.flux.core

import android.content.Context
import android.content.SharedPreferences
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Handler
import android.os.HandlerThread
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

private const val TAG = "FluxMotion"

/**
 * Motion cues with flux.motion. The computer sends config, start, and
 * stop. On start, this phone reads the acceleration and sends it in
 * batches until stop, a lost link, or the end of the service. The sensor
 * runs in the process of [org.omarchy.flux.service.FluxService], a
 * foreground service, so the samples keep coming with the screen off.
 *
 * The sensor, the feeds, and the batches belong to 1 thread, flux-motion.
 * The vehicle detection is best effort: see [VehicleDetector].
 */
object MotionCues {
    /** The most packets that can wait for the link writer. With more, the samples drop. */
    private const val MAX_QUEUED = 4

    /** The sensor hub collects samples for this time, so that the main processor wakes less often. */
    private const val LATENCY_US = 100_000

    /** The wake lock holds for this time, and the feed renews it each [WAKE_RENEW_MS]. */
    private const val WAKE_MS = 10 * 60_000L
    private const val WAKE_RENEW_MS = 60_000L

    /** The error in the state when the phone has no accelerometer. */
    const val NO_SENSOR = "no accelerometer"

    /** The detector of the vehicle events. Only it uses Google Play services. */
    var detector: VehicleDetector = PlayServicesVehicleDetector

    @Volatile private var prefs: SharedPreferences? = null
    private val mounts = ConcurrentHashMap<String, Mount>()

    /** Whether the phone can detect a vehicle. [refreshAccess] reads it. */
    @Volatile var detect: VehicleDetect = VehicleDetect.Unavailable
        private set
    private var playServices: Boolean? = null

    // The vehicle state. The lock of the object guards it.
    private val vehicle = VehicleDebounce()
    private var exitTimer: ScheduledFuture<*>? = null

    /** True while the detection runs, false while it is off, and null before the first decision. */
    private var detecting: Boolean? = null

    fun init(context: Context) {
        prefs = context.getSharedPreferences("motion", Context.MODE_PRIVATE)
    }

    // ------------------------------------------------------------ settings

    /** The mount of this phone for the computer [id]. */
    fun mount(id: String): Mount {
        mounts[id]?.let { return it }
        val p = prefs ?: return Mount.Flat
        return Mount.fromKey(p.getString("mount.$id", null)).also { mounts[id] = it }
    }

    fun setMount(core: FluxCore, id: String, mount: Mount) {
        mounts[id] = mount
        prefs?.edit()?.putString("mount.$id", mount.key)?.apply()
        postIfStarted { feeds[id]?.mount = mount }
        core.publish()
    }

    /** Automatic start on this phone. It needs the vehicle detection. */
    val auto: Boolean get() = prefs?.getBoolean("auto", false) ?: false

    fun setAuto(core: FluxCore, on: Boolean) {
        prefs?.edit()?.putBoolean("auto", on)?.apply()
        refreshAccess(core.app)
        updateDetection(core)
        core.publish()
    }

    /** Reads again whether the phone can detect a vehicle. [FluxCore.refreshAccess] calls it. */
    fun refreshAccess(context: Context) {
        val play = playServices ?: detector.available(context).also { playServices = it }
        detect = when {
            !play -> VehicleDetect.Unavailable
            !hasActivityPermission(context) -> VehicleDetect.NoPermission
            else -> VehicleDetect.Ready
        }
    }

    // ------------------------------------------------------------- packets

    /** Handles flux.motion from a computer. The core lock is held. */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        when (val m = MotionMessage.parse(p.body)) {
            is MotionMessage.Config -> {
                d.motionConfig = m
                updateDetection(core)
                // A computer that connects during a trip learns that the phone is in a vehicle.
                val inside = synchronized(this) { detecting == true && vehicle.inside }
                vehicleReplyTo(m, inside)?.let { d.send(it.packet()) }
            }
            is MotionMessage.Start -> {
                val rate = clampMotionRate(m.rate)
                post { startFeed(core, d, rate) }
            }
            MotionMessage.Stop -> post { stopFeed(core, d, report = true) }
            // The phone sends the other bodies.
            else -> Unit
        }
    }

    /** The user starts the cues on this phone. The sensor starts when the computer answers with start. */
    fun requestStart(core: FluxCore, id: String): Boolean {
        val d = core.device(id) ?: return false
        if (!d.send(MotionMessage.Start().packet())) {
            core.toast("${d.identity.deviceName} is not reachable")
            return false
        }
        return true
    }

    /** The user stops the cues on this phone. The sensor stops at once, and the computer gets stop. */
    fun requestStop(core: FluxCore, id: String) {
        val d = core.device(id) ?: return
        d.send(MotionMessage.Stop.packet())
        post { stopFeed(core, d, report = true) }
    }

    /** The link of [d] closed or changed. The core lock is held. */
    fun onLinkLost(d: Device) {
        d.motionRunning = false
        postIfStarted { stopFeed(FluxCore, d, report = false) }
    }

    /** [d] is no longer paired. The core lock is held. */
    fun forget(core: FluxCore, d: Device) {
        d.motionConfig = null
        d.motionRunning = false
        d.motionError = null
        mounts.remove(d.id)
        prefs?.edit()?.remove("mount.${d.id}")?.apply()
        postIfStarted { stopFeed(core, d, report = false) }
        updateDetection(core)
    }

    /** Stops the sensor for all computers, for example when the service stops. */
    fun stopAll() {
        postIfStarted {
            for (f in feeds.values.toList()) stopFeed(FluxCore, f.device, report = false)
        }
    }

    // ---------------------------------------------------------------- feed

    private class Feed(val device: Device, var mount: Mount) {
        val batcher = SampleBatcher()
    }

    // Only the flux-motion thread uses these fields.
    private val feeds = HashMap<String, Feed>()
    private var sensor: Sensor? = null
    private var rate = 0
    private var gravity: GravityFilter? = null
    private var wake: PowerManager.WakeLock? = null
    private var wakeAt = 0L

    private var handler: Handler? = null

    /** Runs [block] on the flux-motion thread. */
    private fun post(block: () -> Unit) {
        val h = synchronized(this) {
            handler ?: Handler(HandlerThread("flux-motion").apply { start() }.looper).also { handler = it }
        }
        h.post(block)
    }

    /** Runs [block] on the flux-motion thread when the thread runs. Without the thread, no feed ran. */
    private fun postIfStarted(block: () -> Unit) {
        synchronized(this) { handler }?.post(block)
    }

    private val listener = object : SensorEventListener {
        override fun onSensorChanged(e: SensorEvent) {
            var x = e.values[0].toDouble()
            var y = e.values[1].toDouble()
            var z = e.values[2].toDouble()
            gravity?.update(x, y, z)?.let { v ->
                x = v[0]
                y = v[1]
                z = v[2]
            }
            if (!validAccel(x) || !validAccel(y) || !validAccel(z)) return
            // The event time is in nanoseconds of the monotonic clock with deep sleep.
            val t = e.timestamp / 1_000_000
            for (f in feeds.values) f.batcher.add(MotionSample(t, x, y, z, f.mount))
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    }

    private val tick = object : Runnable {
        override fun run() {
            if (feeds.isEmpty()) return
            val now = SystemClock.elapsedRealtime()
            for (f in feeds.values) {
                val busy = (f.device.link?.queued ?: 0) > MAX_QUEUED
                val batch = f.batcher.take(now, busy) ?: continue
                f.device.sendIfIdle(MotionMessage.Samples(batch).packet(), MAX_QUEUED)
            }
            if (now - wakeAt >= WAKE_RENEW_MS) holdWake(now)
            handler?.postDelayed(this, MOTION_BATCH_MS)
        }
    }

    private fun startFeed(core: FluxCore, d: Device, wanted: Int) {
        if (!d.online) return
        if (sensor == null || rate != wanted) {
            val sm = core.app.getSystemService(SensorManager::class.java)
            val linear = sm?.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION)
            val s = linear ?: sm?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
            if (sm == null || s == null) {
                Log.i(TAG, "no accelerometer")
                report(core, d, running = false, error = NO_SENSOR)
                return
            }
            unregister(core)
            gravity = if (linear == null) GravityFilter() else null
            if (!sm.registerListener(listener, s, 1_000_000 / wanted, LATENCY_US, handler)) {
                Log.w(TAG, "the sensor did not start")
                // Each feed lost the sensor.
                val lost = feeds.values.map { it.device } + d
                feeds.clear()
                for (o in lost.distinctBy { it.id }) report(core, o, running = false, error = "the sensor did not start")
                return
            }
            Log.i(TAG, "sensor ${s.name} at $wanted Hz${if (linear == null) ", gravity filter" else ""}")
            sensor = s
            rate = wanted
            holdWake(SystemClock.elapsedRealtime())
            handler?.removeCallbacks(tick)
            handler?.postDelayed(tick, MOTION_BATCH_MS)
        }
        if (feeds[d.id]?.device !== d) feeds[d.id] = Feed(d, mount(d.id))
        report(core, d, running = true, error = null)
    }

    private fun stopFeed(core: FluxCore, d: Device, report: Boolean) {
        val had = feeds.remove(d.id) != null
        if (feeds.isEmpty()) unregister(core)
        if (report) report(core, d, running = false, error = null)
        else if (had) core.locked { d.motionRunning = false }
    }

    private fun unregister(core: FluxCore) {
        if (sensor != null) {
            core.app.getSystemService(SensorManager::class.java)?.unregisterListener(listener)
            Log.i(TAG, "sensor off")
        }
        sensor = null
        rate = 0
        gravity = null
        handler?.removeCallbacks(tick)
        runCatching { wake?.takeIf { it.isHeld }?.release() }
        wakeAt = 0L
    }

    /**
     * Holds a partial wake lock while the sensor runs. Without it, the
     * main processor sleeps with the screen off, and the samples stop.
     */
    private fun holdWake(now: Long) {
        val w = wake ?: FluxCore.app.getSystemService(PowerManager::class.java)
            ?.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "flux:motion")?.apply { setReferenceCounted(false) }
            ?.also { wake = it }
        runCatching { w?.acquire(WAKE_MS) }
        wakeAt = now
    }

    /** Sends the state to [d] and shows it on the phone. */
    private fun report(core: FluxCore, d: Device, running: Boolean, error: String?) {
        d.send(MotionMessage.State(running, error).packet())
        core.locked {
            d.motionRunning = running
            d.motionError = error
        }
    }

    // ------------------------------------------------------------- vehicle

    /**
     * Starts or stops the vehicle detection. It runs only while Flux is on,
     * automatic start is on on this phone, the phone can detect a vehicle,
     * and a paired computer has motion cues and automatic start on.
     */
    fun updateDetection(core: FluxCore) {
        val wanted = core.enabled && auto && detect == VehicleDetect.Ready &&
            core.pairedDevices().any { it.motionConfig?.let { c -> c.enabled && c.auto } == true }
        val change = synchronized(this) {
            if (detecting == wanted) return
            detecting = wanted
            if (!wanted) {
                vehicle.reset()
                exitTimer?.cancel(false)
                exitTimer = null
            }
            true
        }
        // A detection that never ran also stops, because its registration can outlive the process.
        if (change && (wanted || playServices == true)) {
            core.io.execute { if (wanted) detector.start(core.app) else detector.stop(core.app) }
        }
    }

    /** Takes a vehicle event of the detector. */
    fun onVehicle(core: FluxCore, enter: Boolean) {
        val now = SystemClock.elapsedRealtime()
        synchronized(this) {
            if (detecting != true) return
            if (enter) {
                exitTimer?.cancel(false)
                exitTimer = null
                if (vehicle.enter()) sendVehicle(core, true)
            } else {
                val at = vehicle.exit(now) ?: return
                exitTimer = core.scheduler.schedule({ exitDue(core) }, at - now, TimeUnit.MILLISECONDS)
            }
        }
    }

    private fun exitDue(core: FluxCore) {
        val now = SystemClock.elapsedRealtime()
        synchronized(this) {
            val at = vehicle.pendingExit ?: return
            if (vehicle.due(now)) {
                exitTimer = null
                sendVehicle(core, false)
            } else {
                // The exit is not due yet. Wait for the rest of the time.
                exitTimer = core.scheduler.schedule({ exitDue(core) }, at - now, TimeUnit.MILLISECONDS)
            }
        }
    }

    /** Sends a vehicle event to each connected computer with automatic start. A computer that is not connected misses it. */
    private fun sendVehicle(core: FluxCore, inside: Boolean) {
        Log.i(TAG, if (inside) "in a vehicle" else "out of the vehicle")
        for (d in core.connectedPaired()) {
            if (Types.FLUX_MOTION !in d.identity.incoming) continue
            val c = d.motionConfig ?: continue
            if (c.enabled && c.auto) d.send(MotionMessage.Vehicle(inside).packet())
        }
    }
}
