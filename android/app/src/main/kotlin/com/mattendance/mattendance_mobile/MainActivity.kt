package com.mattendance.mattendance_mobile

import android.content.Intent
import android.util.Log
import androidx.annotation.NonNull
import id.flutter.flutter_background_service.BackgroundService
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "com.mattendance.mattendance_mobile/geofence_alarm"
    private val TAG = "GF_MAIN"

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
    }
}
