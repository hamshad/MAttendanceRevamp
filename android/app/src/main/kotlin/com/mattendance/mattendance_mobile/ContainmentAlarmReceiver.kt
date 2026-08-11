package com.mattendance.mattendance_mobile

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.work.Data
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.BackgroundWorker
import id.flutter.flutter_background_service.BackgroundService
import java.util.Calendar

/**
 * Periodic background containment check for auto-punch.
 *
 * WHY IT EXISTS: Android does not reliably deliver geofence EXIT
 * transitions while the app is backgrounded (no location samples during
 * Doze — the OS holds "inside" state, so the crossing is never detected).
 * The user would stay punched in all day.  This alarm is the guaranteed
 * net: while armed it fires every 15 minutes (setAndAllowWhileIdle —
 * fires even during Doze, unlike WorkManager periodic tasks), enqueues a
 * headless WorkManager task, and the Dart callback re-checks containment
 * and punches OUT/IN if the user is on the wrong side of the boundary.
 *
 * ARMING MODEL (no app-open dependency):
 *  - Dart (any isolate — prefs writes work headless) flips
 *    `flutter.gf_containment_alarm_armed` on punch-in / punch-out.
 *  - This receiver self-perpetuates: every fire re-arms the next one as
 *    long as the flag is set AND the state still needs checking
 *    (punched IN, or punched OUT but within the shift window — the
 *    missed-ENTER case).
 *  - The FIRST alarm after install/boot is scheduled by the Dart
 *    main isolate (armContainmentAlarmIfNeeded) and by [BootReceiver].
 *    Once it exists it never needs the app again.
 *
 * BATTERY: at the office (punched in, stationary) the Dart side reuses
 * the OS-cached last-known position and does NOT turn on GPS — each fire
 * is a brief CPU wakeup + prefs read.  GPS (≤2 short fixes) only when the
 * cache says the user has moved outside an office radius.
 */
class ContainmentAlarmReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "GF_CONTAINMENT"
        private const val ACTION_CONTAINMENT_CHECK =
            "com.mattendance.mattendance_mobile.CONTAINMENT_CHECK"
        private const val REQUEST_CODE = 902
        private const val INTERVAL_MS = 15L * 60L * 1000L
        private const val PREFS_NAME = "FlutterSharedPreferences"

        private const val PREF_ARMED = "flutter.gf_containment_alarm_armed"
        private const val PREF_LAST_PUNCH_TYPE = "flutter.gf_last_punch_type"
        private const val PREF_SHIFT_START_TIME = "flutter.gf_cached_shift_start_time"
        private const val PREF_SHIFT_END = "flutter.gf_shift_end_time"

        private const val TASK_NAME = "geofence_containment"

        /**
         * ROMs that kill background app starts / WorkManager / deferred
         * alarms without user exemptions (MIUI/HyperOS is the canonical
         * pain; ColorOS/OxygenOS, Funtouch/OriginOS and MagicOS behave the
         * same).  Must mirror AggressiveOem.aggressiveBrands (Dart).
         */
        private val AGGRESSIVE_BRANDS = listOf(
            "xiaomi", "redmi", "poco", "honor",
            "oppo", "realme", "oneplus", "vivo",
        )

        fun isAggressiveOem(context: Context): Boolean {
            val brand = (Build.BRAND + " " + Build.MANUFACTURER).lowercase()
            return AGGRESSIVE_BRANDS.any { brand.contains(it) }
        }

        /** True when a live isolate genuinely needs to run the FULL combined
         *  service (wifi auto / field tracking) — that service is itself a
         *  foreground service and owns the process; no keep-alive needed. */
        private fun serviceRequired(context: Context): Boolean {
            val prefs =
                context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return prefs.getBoolean("flutter.wifi_auto_punch_enabled_bg", false) ||
                prefs.getBoolean("flutter.wifi_auto_punch_enabled", false) ||
                prefs.getBoolean("flutter.field_tracking_enabled", false)
        }

        /** One-shot 15-min alarm.  Doze-tolerant; exact on aggressive OEMs
         *  (exact-alarm receivers are exempt from Android 12+ background
         *  start restrictions, so the receiver can revive the keep-alive
         *  foreground service without user exemptions). */
        fun armContainmentAlarm(context: Context) {
            val intent = Intent(context, ContainmentAlarmReceiver::class.java).apply {
                action = ACTION_CONTAINMENT_CHECK
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val triggerAt = System.currentTimeMillis() + INTERVAL_MS
            if (isAggressiveOem(context)) {
                try {
                    alarmManager.setExactAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
                    Log.d(TAG, "Containment alarm armed EXACT (+15m, aggressive OEM)")
                    return
                } catch (e: SecurityException) {
                    // Exact-alarm permission revoked → fall through to inexact.
                }
            }
            try {
                alarmManager.setAndAllowWhileIdle(
                    AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
                Log.d(TAG, "Containment alarm armed (+15m)")
            } catch (e: SecurityException) {
                alarmManager.set(AlarmManager.RTC_WAKEUP, triggerAt, pendingIntent)
                Log.d(TAG, "Containment alarm armed inexact fallback (+15m)")
            }
        }

        fun cancelContainmentAlarm(context: Context) {
            val intent = Intent(context, ContainmentAlarmReceiver::class.java).apply {
                action = ACTION_CONTAINMENT_CHECK
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
            Log.d(TAG, "Containment alarm cancelled")
        }

        /** Boot-time helper: schedule the first fire when the app armed the
         *  alarm before the reboot. */
        fun armFromPrefsIfNeeded(context: Context) {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            if (prefs.getBoolean(PREF_ARMED, false)) {
                armContainmentAlarm(context)
            }
        }

        private fun parseIsoLocal(iso: String): Long? {
            val cleaned = iso
                .replace(Regex("[Zz]$"), "")
                .replace(Regex("\\.\\d+"), "")
            val parts = cleaned.split(Regex("[-T:]"))
            if (parts.size < 6) return null
            val year = parts[0].toIntOrNull() ?: return null
            val month = parts[1].toIntOrNull() ?: return null
            val day = parts[2].toIntOrNull() ?: return null
            val hour = parts[3].toIntOrNull() ?: return null
            val min = parts[4].toIntOrNull() ?: return null
            val sec = parts[5].toIntOrNull() ?: return null
            val cal = Calendar.getInstance(java.util.TimeZone.getDefault())
            cal.set(year, month - 1, day, hour, min, sec)
            cal.set(Calendar.MILLISECOND, 0)
            return cal.timeInMillis
        }

        /** True when now is inside [today's shift start, shift end]. */
        private fun withinShiftWindow(context: Context): Boolean {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val startTime = prefs.getString(PREF_SHIFT_START_TIME, null) ?: return false
            val endIso = prefs.getString(PREF_SHIFT_END, null) ?: return false
            val parts = startTime.split(":")
            if (parts.size < 2) return false
            val hour = parts[0].toIntOrNull() ?: return false
            val minute = parts[1].toIntOrNull() ?: return false
            val endMs = parseIsoLocal(endIso) ?: return false

            val now = Calendar.getInstance()
            val start = Calendar.getInstance()
            start.set(Calendar.HOUR_OF_DAY, hour)
            start.set(Calendar.MINUTE, minute)
            start.set(Calendar.SECOND, 0)
            start.set(Calendar.MILLISECOND, 0)
            // Overnight shift: end < start today → end belongs to tomorrow.
            return (now.timeInMillis >= start.timeInMillis &&
                now.timeInMillis <= endMs) ||
                (endMs < start.timeInMillis &&
                    now.timeInMillis <= endMs + 24L * 60L * 60L * 1000L &&
                    now.timeInMillis >= start.timeInMillis)
        }

        /** Punch-state gate: still need containment checks? */
        private fun stillNeeded(context: Context): Boolean {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            if (!prefs.getBoolean(PREF_ARMED, false)) return false
            val lastType = prefs.getString(PREF_LAST_PUNCH_TYPE, null)
            return lastType == "In" || withinShiftWindow(context)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_CONTAINMENT_CHECK) {
            Log.w(TAG, "onReceive: unknown action=${intent.action}")
            return
        }
        Log.i(TAG, "CONTAINMENT_ALARM_FIRED aggressive=${isAggressiveOem(context)}")

        if (!stillNeeded(context)) {
            Log.d(TAG, "Containment no longer needed — not re-arming")
            // Also drop the keep-alive foreground service (punched out
            // outside the shift window): the process must not linger.
            try {
                context.stopService(Intent(context, BackgroundService::class.java))
            } catch (_: Exception) {}
            return
        }

        val wakeLock = (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GeofenceAlarm:Containment")
        wakeLock.acquire(30_000L)

        try {
            if (isAggressiveOem(context) && !serviceRequired(context)) {
                // Revive the keep-alive foreground service directly (exact
                // alarm ⇒ exempt from background start restrictions).  Set
                // the mode flag so the Dart entrypoint runs keep-alive
                // (heal geofences + one containment check + idle holding
                // the process), not the full GPS service — which is exactly
                // what MIUI-class ROMs need for everything else to work
                // (geofence transitions, WorkManager, alarms).
                val prefs =
                    context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                prefs.edit()
                    .putBoolean("flutter.gf_keep_alive_mode", true)
                    .apply()
                val serviceIntent = Intent(context, BackgroundService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
                Log.d(TAG, "Keep-alive foreground service revived (aggressive OEM)")
            } else {
                // Standard ROMs: headless WorkManager task is enough — the
                // plugin's BackgroundWorker spawns a fresh engine, runs the
                // Dart containment callback, no foreground service involved.
                val input = Data.Builder()
                    .putString(BackgroundWorker.DART_TASK_KEY, TASK_NAME)
                    .build()
                val request = OneTimeWorkRequest.Builder(BackgroundWorker::class.java)
                    .setInputData(input)
                    .build()
                WorkManager.getInstance(context).enqueue(request)
                Log.d(TAG, "Containment WorkManager task enqueued")
            }

            // Self-perpetuating: arm the next fire.
            armContainmentAlarm(context)
        } catch (e: Exception) {
            Log.e(TAG, "onReceive error: $e")
            // Even on error, keep the loop alive (retry next interval).
            armContainmentAlarm(context)
        } finally {
            wakeLock.release()
        }
    }
}
