package com.mattendance.mattendance_mobile

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.util.Log
import id.flutter.flutter_background_service.BackgroundService

class GeofenceAlarmReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "GF_ALARM"
        private const val ACTION_SHIFT_START =
            "com.mattendance.mattendance_mobile.SHIFT_START"
        private const val REQUEST_CODE = 901

        fun scheduleShiftStartAlarm(
            context: Context,
            triggerAtMillis: Long,
            shiftName: String,
        ) {
            Log.d(TAG, "scheduleShiftStartAlarm: shift=$shiftName triggerAt=$triggerAtMillis")
            val intent = Intent(context, GeofenceAlarmReceiver::class.java).apply {
                action = ACTION_SHIFT_START
                putExtra("shift_name", shiftName)
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

            // Use setExact with USE_EXACT_ALARM (normal, auto-granted on API 31+)
            // Falls back to inexact setAndAllowWhileIdle if permission denied.
            try {
                alarmManager.setExact(AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
                Log.d(TAG, "Alarm scheduled EXACT for $triggerAtMillis")
            } catch (e: SecurityException) {
                alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
                Log.d(TAG, "Alarm scheduled INEXACT (fallback) for $triggerAtMillis")
            }
        }

        fun cancelShiftStartAlarm(context: Context) {
            val intent = Intent(context, GeofenceAlarmReceiver::class.java).apply {
                action = ACTION_SHIFT_START
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarmManager.cancel(pendingIntent)
            pendingIntent.cancel()
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_SHIFT_START) {
            Log.w(TAG, "onReceive: unknown action=${intent.action}")
            return
        }

        val shiftName = intent.getStringExtra("shift_name") ?: "unknown"
        Log.i(TAG, "ALARM_FIRED: shift=$shiftName — starting BackgroundService")

        val wakeLock = (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GeofenceAlarm:ShiftStart")
        wakeLock.acquire(10_000L)

        try {
            // 1. Start the combined background service.
            val serviceIntent = Intent(context, BackgroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
                Log.d(TAG, "startForegroundService() called")
            } else {
                context.startService(serviceIntent)
                Log.d(TAG, "startService() called")
            }

            // 2. Write a SharedPreferences flag so the Dart side can detect a missed
            //    alarm even if BackgroundService fails to start the Dart isolate.
            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE,
            )
            prefs.edit()
                .putBoolean("gf_alarm_fired", true)
                .putLong("gf_alarm_fired_at", System.currentTimeMillis())
                .apply()
            Log.d(TAG, "Alarm flag written to SharedPreferences")
        } catch (e: Exception) {
            Log.e(TAG, "onReceive error: $e")
        } finally {
            wakeLock.release()
            Log.d(TAG, "WakeLock released")
        }
    }
}
