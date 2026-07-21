import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models/offline_punch.dart';
import 'core/notifications/fcm_service.dart';
import 'core/notifications/local_notifications.dart';
import 'core/utils/constants.dart';
import 'core/utils/app_logger.dart';
import 'core/utils/log_buffer.dart';
import 'features/tracking/services/field_tracking_service.dart';
import 'features/punch/services/shift_service.dart';
import 'app.dart';

/// Override debugPrint to capture all logs in our in-memory buffer.
void _initLogCapture() {
  debugPrint = debugPrintWithBuffer;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _initLogCapture();
  AppLogger.activity('Application Starting');

  // Hive
  await Hive.initFlutter();
  Hive.registerAdapter(OfflinePunchAdapter());
  await Hive.openBox<OfflinePunch>(AppConstants.offlinePunchBox);
  await Hive.openBox(AppConstants.cacheBox);
  await Hive.openBox(AppConstants.shiftsBox);

  // Local notifications
  await initLocalNotifications();

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
  }

  // Background field tracking service — registers the entrypoint before runApp.
  await FieldTrackingService.init();

  // Firebase — requires google-services.json (Android) / GoogleService-Info.plist (iOS).
  // Wrapped in try/catch so the app runs normally without the config files.
  try {
    await Firebase.initializeApp();
    // Register the background handler before runApp (FCM requirement).
    FirebaseMessaging.onBackgroundMessage(fcmBackgroundHandler);
  } catch (_) {
    // Firebase not configured — FCM and push notifications will be unavailable.
  }

  runApp(const ProviderScope(child: MAttendanceApp()));
}
