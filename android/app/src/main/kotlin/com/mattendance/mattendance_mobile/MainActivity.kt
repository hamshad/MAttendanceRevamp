package com.mattendance.mattendance_mobile

import android.Manifest
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Process
import android.provider.Settings
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
     * Android 12+ (API 31+): the permission level is the documented
     * authoritative signal — granting "approximate location" revokes
     * ACCESS_FINE_LOCATION while keeping ACCESS_COARSE_LOCATION. This applies
     * to MIUI/HyperOS too (the MIUI "approximate location" toggle is the same
     * Android 12 feature). Never consult AppOps here: MIUI is known to report
     * stale MODE_IGNORED op state even after the user enabled precise location
     * (permission changed in Settings, op not synced) — blocking on it would
     * permanently stick the "Precise location required" screen on MI devices.
     *
     * Pre-12 (API 29-30): stock Android grants FINE together with COARSE, so
     * the permission check would always pass. MIUI backported the approximate
     * toggle to Android 10/11 devices at the app-op level (permission stays
     * granted, OP_FINE_LOCATION = MODE_IGNORED) — the app-op is the only
     * signal there. MODE_ERRORED (op not readable) fails open.
     */
    private fun isPreciseLocationGranted(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return ContextCompat.checkSelfPermission(
                this, Manifest.permission.ACCESS_FINE_LOCATION,
            ) == PackageManager.PERMISSION_GRANTED
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_FINE_LOCATION, Process.myUid(), packageName,
            )
            return mode != AppOpsManager.MODE_IGNORED &&
                mode != AppOpsManager.MODE_ERRORED
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
                "scheduleContainmentAlarm" -> {
                    Log.d(TAG, "scheduleContainmentAlarm")
                    ContainmentAlarmReceiver.armContainmentAlarm(this)
                    result.success(null)
                }
                "cancelContainmentAlarm" -> {
                    Log.d(TAG, "cancelContainmentAlarm")
                    ContainmentAlarmReceiver.cancelContainmentAlarm(this)
                    result.success(null)
                }
                "isAggressiveOem" -> {
                    result.success(ContainmentAlarmReceiver.isAggressiveOem(this))
                }
                "openMiuiAutoStart" -> {
                    // MIUI/HyperOS per-app Auto-start page.  MIUI hides the
                    // background-exec toggles (Auto-start, Battery saver)
                    // inside the Security Center app, and the component names
                    // move across versions — a hardcoded class often fails to
                    // resolve on HyperOS, dropping the user onto the useless
                    // app-details page.  Try several intents; if none resolve,
                    // land in the Security Center home so the user can find
                    // Permissions → Autostart.  Auto-start is THE critical
                    // toggle: without it the 15-min containment alarm, OS
                    // geofence transitions and WorkManager cannot run in the
                    // background, so headless auto-punch never fires.
                    val sc = "com.miui.securitycenter"
                    val attempts = listOf(
                        Intent("miui.intent.action.OP_AUTO_START").apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            setClassName(
                                sc,
                                "com.miui.permcenter.autostart.AutoStartManagementActivity",
                            )
                        },
                        Intent("miui.intent.action.OP_AUTO_START").apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        },
                        Intent().apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            setClassName(
                                sc,
                                "com.miui.permcenter.autostart.AutoStartManagementActivity",
                            )
                        },
                        Intent().apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            setClassName(sc, "com.miui.securitycenter.MainActivity")
                        },
                    )
                    var opened = false
                    for (intent in attempts) {
                        if (runCatching { startActivity(intent) }.isSuccess) {
                            opened = true
                            break
                        }
                    }
                    if (!opened) {
                        runCatching {
                            startActivity(
                                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                    data = Uri.parse("package:$packageName")
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                },
                            )
                        }
                    }
                    result.success(null)
                }
                "openMiuiBatterySaver" -> {
                    // MIUI per-app "Battery saver" page (unrestricted toggle).
                    runCatching {
                        val intent = Intent("miui.intent.action.APP_BATTERY_SAVER").apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            putExtra("package_name", packageName)
                            setClassName(
                                "com.miui.securitycenter",
                                "com.miui.powercenter.batteryUI.BatterySettingsActivity",
                            )
                        }
                        startActivity(intent)
                    }.onFailure {
                        runCatching {
                            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            })
                        }
                    }
                    result.success(null)
                }
                "requestIgnoreBatteryOptimizations" -> {
                    // Standard Android battery-optimization exemption dialog —
                    // works on MIUI too ("No restrictions" in App details →
                    // Battery).
                    runCatching {
                        val intent = Intent(
                            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            Uri.parse("package:$packageName"),
                        ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                        startActivity(intent)
                    }
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
