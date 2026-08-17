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
 *  - `flutter.gf_containment_alarm_armed` is the MASTER ENABLE (geofence
 *    auto on) — written by the Dart main isolate on arm/disable/logout
 *    and lifted by the native shift-start alarm every morning.
 *  - This receiver self-perpetuates: every fire re-arms the next one as
 *    long as the flag is set — it NEVER rests while geofence auto is
 *    on.  It is the 24/7 checker for the headless IN/OUT paths: each
 *    fire enqueues a headless WorkManager task that re-registers the OS
 *    geofences (self-heal if an OEM dropped them) and re-checks
 *    containment (missed-ENTER and missed-EXIT).  It never revives the
 *    FGS — the keep-alive service is punch-state lifecycle only (starts
 *    on the IN punch, stops on OUT; user-closed stays closed, no banner
 *    behind the user's back; headless OUT covers it within one interval).
 *  - The FIRST alarm after install/boot is scheduled by the Dart
 *    main isolate (armContainmentAlarmIfNeeded), by the shift-start
 *    alarm, and by [BootReceiver].  Once it exists it never needs the
 *    app again.
 *
 * BATTERY: at the office (punched in, stationary) the Dart side reuses
 * the OS-cached last-known position and does NOT turn on GPS — each fire
 * is a brief CPU wakeup + prefs read.  GPS (≤2 short fixes) only when the
 * cache says the user has moved outside an office radius.  Punched out +
 * away = prefs read only (cheap).  Cost: ~96 light wakeups/day while
 * geofence auto is on — the price of the always-available headless IN.
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

        private const val TASK_NAME = "geofence_containment"

        /**
         * ROMs that kill background app starts / WorkManager / deferred
         * alarms without user exemptions.  MI family ONLY (user decision
         * 2026-08-17: Samsung / Nothing / OnePlus field-proven working
         * without restrictions — no exact-alarm treatment needed for them).
         * Must mirror AggressiveOem.aggressiveBrands (Dart).
         */
        private val AGGRESSIVE_BRANDS = listOf(
            "xiaomi", "redmi", "poco",
        )

        fun isAggressiveOem(context: Context): Boolean {
            val brand = (Build.BRAND + " " + Build.MANUFACTURER).lowercase()
            return AGGRESSIVE_BRANDS.any { brand.contains(it) }
        }

        /** One-shot 15-min alarm.  Doze-tolerant; exact on aggressive OEMs
         *  (exact-alarm receivers are exempt from Android 12+ background
         *  start restrictions, so the receiver can enqueue WorkManager
         *  reliably). */
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

        /** The 24/7 headless-IN/OUT checker: always continues while armed
         *  (geofence auto on) — every 15-min fire enqueues a headless
         *  WorkManager task that re-registers the OS geofences AND
         *  re-checks containment, so ENTER and EXIT punching survive
         *  whatever kills the app process, the FGS, the WorkManager
         *  queue or the OS geofence registration. */
        private fun stillNeeded(context: Context): Boolean {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            return prefs.getBoolean(PREF_ARMED, false)
        }

        /** Headless containment check: WorkManager spawns a fresh engine, no FGS. */
        private fun enqueueHeadlessContainment(context: Context) {
            val input = Data.Builder()
                .putString(BackgroundWorker.DART_TASK_KEY, TASK_NAME)
                .build()
            val request = OneTimeWorkRequest.Builder(BackgroundWorker::class.java)
                .setInputData(input)
                .build()
            WorkManager.getInstance(context).enqueue(request)
            Log.d(TAG, "Containment WorkManager task enqueued")
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_CONTAINMENT_CHECK) {
            Log.w(TAG, "onReceive: unknown action=${intent.action}")
            return
        }
        Log.i(TAG, "CONTAINMENT_ALARM_FIRED aggressive=${isAggressiveOem(context)}")

        if (!stillNeeded(context)) {
            Log.d(TAG, "Containment disarmed — not re-arming")
            // Also drop the keep-alive foreground service (geofence
            // disabled / logged out): the process must not linger.
            try {
                context.stopService(Intent(context, BackgroundService::class.java))
            } catch (_: Exception) {}
            return
        }

        val wakeLock = (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "GeofenceAlarm:Containment")
        wakeLock.acquire(30_000L)

        try {
            // Headless only (user design): the FGS is punch-state
            // lifecycle (starts on the IN punch, stops on OUT).  If the
            // user closed it, we NEVER auto-revive it — the banner must
            // not come back behind their back.  Headless OUT keeps
            // working instead: the task below re-registers the OS
            // geofences and re-checks containment — a closed FGS costs
            // at most one 15-min interval before the OUT punches (OS
            // geofence EXIT is the primary headless OUT path; this
            // reconcile is the guarantee with the fixed 45m band).
            enqueueHeadlessContainment(context)

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
