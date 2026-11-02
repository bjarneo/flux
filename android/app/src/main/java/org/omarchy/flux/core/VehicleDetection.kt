package org.omarchy.flux.core

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log
import androidx.core.content.ContextCompat
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity

private const val TAG = "FluxVehicle"

/**
 * Detects when the phone enters or leaves a vehicle. It is best effort: a
 * phone without a detector still starts motion cues by hand. The events
 * go to [MotionCues.onVehicle].
 */
interface VehicleDetector {
    /** True when the phone has what the detector needs, without the permission. */
    fun available(context: Context): Boolean

    /** Starts the detection. Call it only with the permission. */
    fun start(context: Context)

    /** Stops the detection. */
    fun stop(context: Context)
}

/** The runtime permission of the vehicle detection. */
const val ACTIVITY_PERMISSION = Manifest.permission.ACTIVITY_RECOGNITION

/** True when the user allowed physical activity access. */
fun hasActivityPermission(context: Context): Boolean =
    ContextCompat.checkSelfPermission(context, ACTIVITY_PERMISSION) == PackageManager.PERMISSION_GRANTED

/**
 * The vehicle detector of Google Play services: the Activity Recognition
 * Transition API, with enter and exit of [DetectedActivity.IN_VEHICLE].
 * The events come to [VehicleReceiver] through a PendingIntent, so they
 * also come while the app sleeps.
 */
object PlayServicesVehicleDetector : VehicleDetector {
    private const val REQUEST = 7

    override fun available(context: Context): Boolean = runCatching {
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS
    }.getOrDefault(false)

    private fun intent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context, REQUEST, Intent(context, VehicleReceiver::class.java).setPackage(context.packageName),
        // Play services adds the result to the intent, so it must be mutable.
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
    )

    @SuppressLint("MissingPermission")
    override fun start(context: Context) {
        if (!hasActivityPermission(context)) return
        val transitions = listOf(ActivityTransition.ACTIVITY_TRANSITION_ENTER, ActivityTransition.ACTIVITY_TRANSITION_EXIT).map {
            ActivityTransition.Builder().setActivityType(DetectedActivity.IN_VEHICLE).setActivityTransition(it).build()
        }
        runCatching {
            ActivityRecognition.getClient(context).requestActivityTransitionUpdates(ActivityTransitionRequest(transitions), intent(context))
                .addOnSuccessListener { Log.i(TAG, "vehicle detection on") }
                .addOnFailureListener { Log.w(TAG, "vehicle detection did not start", it) }
        }.onFailure { Log.w(TAG, "vehicle detection did not start", it) }
    }

    @SuppressLint("MissingPermission")
    override fun stop(context: Context) {
        runCatching {
            ActivityRecognition.getClient(context).removeActivityTransitionUpdates(intent(context))
                .addOnSuccessListener { Log.i(TAG, "vehicle detection off") }
        }
    }
}

/** Takes the vehicle events of [PlayServicesVehicleDetector]. */
class VehicleReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!ActivityTransitionResult.hasResult(intent)) return
        val result = ActivityTransitionResult.extractResult(intent) ?: return
        FluxCore.init(context)
        // The events come in time order, so the last one is the current state.
        val last = result.transitionEvents.lastOrNull { it.activityType == DetectedActivity.IN_VEHICLE } ?: return
        MotionCues.onVehicle(FluxCore, last.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER)
    }
}
