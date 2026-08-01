package com.mattendance.mattendance_mobile

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.util.Log
import java.util.Calendar
import id.flutter.flutter_background_service.BackgroundService

class GeofenceAlarmReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "GF_ALARM"
        private const val ACTION_SHIFT_START =
            "com.mattendance.mattendance_mobile.SHIFT_START"
        private const val REQUEST_CODE = 901

        /** Shift start "HH:mm" persisted by Dart — used to self-re-arm the next alarm. */
        private const val PREF_SHIFT_START_TIME = "flutter.gf_cached_shift_start_time"

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

            // setExactAndAllowWhileIdle: exact when the device is awake AND
            // fires during Doze (the phone is typically idle overnight before
            // a morning shift).  Plain setExact is silently deferred during
            // Doze until the next maintenance window — alarms that then fire
            // 10-30+ minutes late.  Requires USE_EXACT_ALARM (API 33+,
            // declared in manifest, auto-granted) / SCHEDULE_EXACT_ALARM.
            try {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
                Log.d(TAG, "Alarm scheduled EXACT for $triggerAtMillis")
            } catch (e: SecurityException) {
                // Permission revoked / not granted on API 31-32 → fall back to
                // inexact but Doze-tolerant delivery rather than nothing.
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP, triggerAtMillis, pendingIntent)
                Log.d(TAG, "Alarm scheduled INEXACT (fallback) for $triggerAtMillis")
            }
        }

        /**
         * Re-arm the shift-start alarm for the NEXT occurrence of the shift
         * start time, purely from native side.  Called by the receiver when it
         * fires — the Dart background isolate cannot reach the app's
         * MethodChannel (it is only registered on the main engine), so relying
         * on Dart to re-arm would leave only the inexact Workmanager task for
         * subsequent days.
         */
        fun scheduleNextShiftAlarmFromPrefs(context: Context) {
            val prefs = context.getSharedPreferences(
                "FlutterSharedPreferences",
                Context.MODE_PRIVATE,
            )
            val startTime = prefs.getString(PREF_SHIFT_START_TIME, null) ?: return
            val parts = startTime.split(":")
            if (parts.size < 2) return
            val hour = parts[0].toIntOrNull() ?: return
            val minute = parts[1].toIntOrNull() ?: return

            val now = Calendar.getInstance()
            val next = Calendar.getInstance()
            next.set(Calendar.HOUR_OF_DAY, hour)
            next.set(Calendar.MINUTE, minute)
            next.set(Calendar.SECOND, 0)
            next.set(Calendar.MILLISECOND, 0)
            // If today's occurrence already passed, roll to tomorrow.
            if (!next.after(now)) {
                next.add(Calendar.DAY_OF_YEAR, 1)
            }

            val shiftName = prefs.getString("flutter.gf_cached_shift_name", "") ?: ""
            scheduleShiftStartAlarm(context, next.timeInMillis, shiftName)
            Log.d(TAG, "Self re-armed next shift alarm for ${next.time.toString()}")
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

            // 3. Re-arm the next shift alarm natively — see
            //    scheduleNextShiftAlarmFromPrefs() for why this must not rely
            //    on the Dart background isolate.
            scheduleNextShiftAlarmFromPrefs(context)
        } catch (e: Exception) {
            Log.e(TAG, "onReceive error: $e")
        } finally {
            wakeLock.release()
            Log.d(TAG, "WakeLock released")
        }
    }
}
