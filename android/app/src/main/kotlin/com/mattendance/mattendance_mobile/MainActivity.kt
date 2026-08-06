package com.mattendance.mattendance_mobile

import android.Manifest
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process
import android.util.Log
import androidx.annotation.NonNull
import androidx.core.content.ContextCompat
import id.flutter.flutter_background_service.BackgroundService
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.mattendance.mattendance_mobile/geofence_alarm"
    private val LOCATION_PRECISION_CHANNEL = "com.mattendance.mattendance_mobile/location_precision"
    private val TAG = "GF_MAIN"

    /**
     * True only when the OS location permission is PRECISE (fine granularity).
     *
     * On Android 12+ (API 31+), granting "approximate location" revokes
     * ACCESS_FINE_LOCATION while keeping ACCESS_COARSE_LOCATION — so a direct
     * FINE permission check is the authoritative signal (the documented
     * approach). The API-31 `LocationManager#getLocationGranularity()` API is
     * @SystemApi and not available to apps.
     *
     * Additional AppOps check on API 29+ catches OEM-specific toggles (e.g.
     * MIUI 12/13 "Approximate location" on Android 10/11) that revoke the fine
     * location op independently of the runtime permission.
     */
    private fun isPreciseLocationGranted(): Boolean {
        val fineGranted = ContextCompat.checkSelfPermission(
            this, Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED
        if (!fineGranted) return false

        // Belt-and-suspenders: fine-location app-op revoked by OEM toggles.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_FINE_LOCATION, Process.myUid(), packageName,
            )
            // MODE_IGNORED = fine fixes blocked (approximate). MODE_ERRORED means
            // the op isn't readable → trust the permission check (fail-open).
            if (mode == AppOpsManager.MODE_IGNORED) return false
        }
        return true
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            Log.d(TAG, "MethodChannel: ${call.method}")
            when (call.method) {
                "scheduleShiftAlarm" -> {
                    val triggerAtMillis =
                        call.argument<Long>("triggerAtMillis") ?: 0L
                    val shiftName =
                        call.argument<String>("shiftName") ?: ""
                    Log.d(TAG, "scheduleShiftAlarm: shift=$shiftName at=$triggerAtMillis")
                    GeofenceAlarmReceiver.scheduleShiftStartAlarm(
                        this, triggerAtMillis, shiftName,
                    )
                    result.success(null)
                }
                "cancelShiftAlarm" -> {
                    Log.d(TAG, "cancelShiftAlarm")
                    GeofenceAlarmReceiver.cancelShiftStartAlarm(this)
                    result.success(null)
                }
                "stopBackgroundService" -> {
                    Log.d(TAG, "stopBackgroundService called")
                    val intent = Intent(this, BackgroundService::class.java)
                    stopService(intent)
                    Log.d(TAG, "stopBackgroundService completed")
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LOCATION_PRECISION_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isPreciseGranted" -> result.success(isPreciseLocationGranted())
                else -> result.notImplemented()
            }
        }
    }
}
