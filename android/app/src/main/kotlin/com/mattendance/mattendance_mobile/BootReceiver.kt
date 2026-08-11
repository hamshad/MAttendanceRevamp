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

        // Re-arm the periodic containment check (punched-in auto-punch users).
        // The alarm self-perpetuates once its first fire is scheduled.
        ContainmentAlarmReceiver.armFromPrefsIfNeeded(context)

        // Aggressive OEMs (MIUI & friends): also revive the keep-alive
        // foreground service after reboot — these ROMs won't spawn the app
        // from background at all, and the service holding the process is
        // what makes geofence/alarm/WorkManager work without exemptions.
        // Set the mode flag so the Dart entrypoint runs keep-alive (light),
        // never the full GPS service, unless wifi/tracking genuinely need it
        // (then `was_field_tracking` above already starts the full service).
        val serviceRequired = prefs.getBoolean("flutter.wifi_auto_punch_enabled_bg", false) ||
            prefs.getBoolean("flutter.wifi_auto_punch_enabled", false) ||
            prefs.getBoolean("flutter.field_tracking_enabled", false)
        if (ContainmentAlarmReceiver.isAggressiveOem(context) &&
            !serviceRequired &&
            prefs.getBoolean("flutter.gf_containment_alarm_armed", false)
        ) {
            prefs.edit().putBoolean("flutter.gf_keep_alive_mode", true).apply()
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
        // Strips trailing Z and decimal millis, then parses.
        // IMPORTANT: Dart's DateTime.now().toIso8601String() writes LOCAL time
        // WITHOUT a Z suffix.  Parse in the device's default timezone so the
        // alarm fires at the same wall-clock time the Dart side intended.
        // (Previously parsed as UTC, shifting the alarm by the device's UTC
        // offset — e.g. +5:30 IST → alarm fired 5.5h late after reboot.)
        val cleaned = iso
            .replace(Regex("[Zz]\$"), "")
            .replace(Regex("\\.\\d+"), "")
        // Simple parse: assume local time since Dart's toIso8601String() on a
        // local DateTime produces no timezone marker
        val parts = cleaned.split(Regex("[-T:]"))
        if (parts.size < 6) return null
        val year = parts[0].toIntOrNull() ?: return null
        val month = parts[1].toIntOrNull() ?: return null
        val day = parts[2].toIntOrNull() ?: return null
        val hour = parts[3].toIntOrNull() ?: return null
        val min = parts[4].toIntOrNull() ?: return null
        val sec = parts[5].toIntOrNull() ?: return null

        val cal = java.util.Calendar.getInstance(java.util.TimeZone.getDefault())
        cal.set(year, month - 1, day, hour, min, sec)
        cal.set(java.util.Calendar.MILLISECOND, 0)
        return cal.timeInMillis
    }
}
