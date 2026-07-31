import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/offline_punch.dart';
import 'core/notifications/fcm_service.dart';
import 'core/notifications/local_notifications.dart';
import 'core/offline/offline_sync_manager.dart';
import 'core/utils/constants.dart';
import 'core/utils/app_logger.dart';
import 'core/utils/log_buffer.dart';
import 'features/tracking/services/field_tracking_service.dart';
import 'features/punch/services/geofence_scheduler.dart';
import 'features/punch/services/shift_service.dart';
import 'app.dart';

/// Override debugPrint to capture all logs in our in-memory buffer.
void _initLogCapture() {
  debugPrint = debugPrintWithBuffer;
}

/// Sync the Hive geofence-enabled flag to SharedPreferences before the
/// background service starts, so [_isEnabled] in the geofence worker
/// returns the correct value from the very first GPS fix.
Future<void> _syncGeofenceFlag() async {
  try {
    final box = Hive.box(AppConstants.geofenceSettingsBox);
    final enabled = box.get('auto_punch_enabled', defaultValue: true) as bool;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('geofence_auto_enabled', enabled);
    await prefs.remove('gf_shift_ended');
    debugPrint('[MAIN] Synced geofence flag: $enabled, cleared stale gf_shift_ended');
  } catch (_) {}
}

/// Schedule alarms from cached shifts and start the combined service
/// immediately if within the current shift window.
///
/// Skips entirely when no auth token exists (user logged out).
/// Alarms are re-scheduled by [MainShell._initGeofenceScheduler] on login.
void _scheduleAlarmFromCachedShifts() {
  SharedPreferences.getInstance().then((prefs) {
    final token = prefs.getString('bg_access_token');
    if (token == null || token.isEmpty) {
      debugPrint('[MAIN] No auth token — skipping geofence service start');
      return;
    }
    // Permission gate (mirrored by accessPermissionsProvider on fetch): skip
    // only when the server definitively denied geofence auto.  Absent flag
    // (not fetched yet) → proceed, MainShell re-evaluates once perms load.
    if (prefs.getBool('bg_allow_geofence_auto') == false) {
      debugPrint('[MAIN] Geofence not permitted by backend — skipping alarm/service start');
      return;
    }
    try {
      final cached = ShiftService.loadCachedShifts();
      if (cached.isEmpty) return;
      GeofenceScheduler.startIfWithinShiftWindow(cached)
          .then((_) => AppLogger.activity('Geofence scheduler activated'))
          .catchError((_) {});
    } catch (_) {}
  });
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final _bench = Stopwatch()..start();
  _initLogCapture();
  AppLogger.activity('Application Starting');

  // Hive
  await Hive.initFlutter();
  Hive.registerAdapter(OfflinePunchAdapter());
  // Open boxes in parallel — sequential opens serialized directory IO
  // (~650ms cold); parallel cuts it to roughly the slowest single box.
  await Future.wait([
    Hive.openBox<OfflinePunch>(AppConstants.offlinePunchBox),
    Hive.openBox(AppConstants.cacheBox),
    Hive.openBox(AppConstants.geofenceSettingsBox),
    Hive.openBox(AppConstants.shiftsBox),
    Hive.openBox(AppConstants.tokenBackupBox),
  ]);
  debugPrint('[BENCH] Hive boxes: ${_bench.elapsedMilliseconds}ms');

  // Sync geofence flag to SharedPreferences BEFORE any service starts,
  // so the background worker's _isEnabled() reads the correct value from
  // the very first GPS fix — no race with _initGeofence() post-frame callback.
  await _syncGeofenceFlag();
  debugPrint('[BENCH] geofence flag sync: ${_bench.elapsedMilliseconds}ms');

  // Local notifications (for geofence auto-punch alerts)
  await initLocalNotifications();
  debugPrint('[BENCH] local notifications: ${_bench.elapsedMilliseconds}ms');

  // Create notification channels explicitly BEFORE any background service
  // starts. Android 14+ requires the channel to exist at startForeground time
  // or the system throws CannotPostForegroundServiceNotificationException.
  final androidPlugin = localNotifications.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  if (androidPlugin != null) {
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'mattendance_field_tracking',
        'Field Tracking',
        description: 'Background location tracking for attendance',
        importance: Importance.low,
      ),
    );
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'geofence_monitor',
        'Geofence Monitor',
        description: 'Geofence background monitoring',
        importance: Importance.low,
      ),
    );
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'gps_disabled',
        'GPS Disabled',
        description: 'Alerts when GPS is turned off while geofence is active',
        importance: Importance.high,
      ),
    );
    await androidPlugin.createNotificationChannel(
      const AndroidNotificationChannel(
        'user_alignment',
        'Attendance Alerts',
        description:
            'Heads-up alerts when a phone setting breaks auto punch '
            '(GPS off, airplane mode, location permission)',
        importance: Importance.high,
      ),
    );
  }

  // Background field tracking service — registers the entrypoint before runApp.
  await FieldTrackingService.init();
  debugPrint('[BENCH] field tracking init: ${_bench.elapsedMilliseconds}ms');

  // Workmanager for shift-start alarm scheduling
  await GeofenceScheduler.init();
  debugPrint('[BENCH] workmanager init: ${_bench.elapsedMilliseconds}ms');

  // Background manager for the offline punch queue — periodic safety-net
  // sync every 15 min while connected (one-off tasks are scheduled on enqueue).
  await OfflineSyncManager.start();
  debugPrint('[BENCH] offline sync start: ${_bench.elapsedMilliseconds}ms');

  // Schedule initial Workmanager alarm from cached shifts
  // so the geofence service auto-starts at the next shift without
  // requiring the user to open the app.
  //
  // Deferred to after first frame so the activity is visible — starting
  // a foreground service before runApp() triggers
  // CannotPostForegroundServiceNotificationException on Android 14+.
  WidgetsBinding.instance.addPostFrameCallback((_) => _scheduleAlarmFromCachedShifts());

  // Firebase — deferred: initializing BEFORE runApp() blocks the first frame
  // for seconds on slow networks (config/metadata fetch).  Initialized
  // fire-and-forget; the FCM background handler is registered once ready.
  // MainShell._initFCM() waits for Firebase readiness before requesting
  // tokens, so push notifications are unaffected.
  unawaited(Firebase.initializeApp().then((_) {
    FirebaseMessaging.onBackgroundMessage(fcmBackgroundHandler);
  }).catchError((Object e) {
    // Firebase not configured — FCM and push notifications unavailable.
  }));

  runApp(const ProviderScope(child: MAttendanceApp()));
  debugPrint('[BENCH] runApp: ${_bench.elapsedMilliseconds}ms');
}
