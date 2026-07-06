package com.mattendance.mattendance_mobile

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import id.flutter.flutter_background_service.BackgroundService

class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val PREFS_NAME = "FlutterSharedPreferences"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        // Re-schedule AlarmManager alarm for next shift start
        val nextShiftStr = prefs.getString("flutter.gf_next_shift_start", null)
        if (nextShiftStr != null) {
            try {
                val nextShiftMs = dateStringToMillis(nextShiftStr) ?: return
                val shiftName = prefs.getString("flutter.gf_cached_shift_name", "") ?: ""
                GeofenceAlarmReceiver.scheduleShiftStartAlarm(
                    context, nextShiftMs, shiftName,
                )
            } catch (_: Exception) {
            }
        }

        // If field tracking was active before reboot, also start the background service
        val wasTracking = prefs.getBoolean("flutter.was_field_tracking", false)
        if (wasTracking) {
            startBackgroundService(context)
        }
    }

    private fun startBackgroundService(context: Context) {
        val serviceIntent = Intent(context, BackgroundService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }

    /** Parse a Dart toIso8601String() into epoch milliseconds. */
    private fun dateStringToMillis(iso: String): Long? {
        // Expected format examples:
        //   "2026-06-12T10:00:00.000"  (with millis)
        //   "2026-06-12T10:00:00"       (without millis)
        //   "2026-06-12T10:00:00.000Z"  (with trailing Z)
        // Strips trailing Z and decimal millis, then parses as "yyyy-MM-dd'T'HH:mm:ss".
        val cleaned = iso
            .replace(Regex("[Zz]\$"), "")
            .replace(Regex("\\.\\d+"), "")
        // Simple parse: assume UTC since Dart's toIso8601String() produces UTC
        val parts = cleaned.split(Regex("[-T:]"))
        if (parts.size < 6) return null
        val year = parts[0].toIntOrNull() ?: return null
        val month = parts[1].toIntOrNull() ?: return null
        val day = parts[2].toIntOrNull() ?: return null
        val hour = parts[3].toIntOrNull() ?: return null
        val min = parts[4].toIntOrNull() ?: return null
        val sec = parts[5].toIntOrNull() ?: return null

        val cal = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
        cal.set(year, month - 1, day, hour, min, sec)
        cal.set(java.util.Calendar.MILLISECOND, 0)
        return cal.timeInMillis
    }
}
