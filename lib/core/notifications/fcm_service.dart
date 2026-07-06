import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_provider.dart';
import '../device/device_registration.dart';
import 'local_notifications.dart';

// ── Background handler (top-level — required by FCM) ─────────────────────────

/// Runs in a separate isolate when a data-only message arrives while the app
/// is killed. Notifications that carry a `notification` payload are displayed
/// automatically by the system without this handler.
@pragma('vm:entry-point')
Future<void> fcmBackgroundHandler(RemoteMessage message) async {
  // Nothing needed for notification-payload messages — the OS shows them.
  // Add data-only handling here if required in a future sprint.
}

// ── Notification channel (Android 8+) ────────────────────────────────────────

const _pushChannel = AndroidNotificationChannel(
  'mattendance_push',
  'MAttendance Notifications',
  description: 'Leave approvals, payroll alerts, and attendance reminders',
  importance: Importance.high,
);

const _notificationDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'mattendance_push',
    'MAttendance Notifications',
    importance: Importance.high,
    priority: Priority.high,
  ),
  iOS: DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
  ),
);

// ── FCM Service ───────────────────────────────────────────────────────────────

/// Call [initialize] once from the main shell after login.
///
/// [onDeepLink] receives the route string and the full message data map
/// whenever a notification tap should navigate somewhere. Implement this in
/// the calling widget so routing stays out of core.
class FCMService {
  final WidgetRef _ref;
  final void Function(String route, Map<String, dynamic> data)? onDeepLink;

  const FCMService(this._ref, {this.onDeepLink});

  Future<void> initialize() async {
    // Register the background handler before anything else (FCM requirement).
    FirebaseMessaging.onBackgroundMessage(fcmBackgroundHandler);

    // Create the Android high-importance channel.
    await localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_pushChannel);

    // Request permission (mandatory on iOS, needed on Android 13+).
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    if (settings.authorizationStatus == AuthorizationStatus.denied) return;

    // Get the current FCM token and register the device.
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null) await _registerDevice(token);

    // Re-register whenever the token rotates.
    FirebaseMessaging.instance.onTokenRefresh.listen(_registerDevice);

    // Foreground messages — show a local notification.
    FirebaseMessaging.onMessage.listen(_onForeground);

    // App was backgrounded; user tapped a notification.
    FirebaseMessaging.onMessageOpenedApp.listen(_onTap);

    // App was killed; notification tap launched the app.
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) _onTap(initial);
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<void> _registerDevice(String token) async {
    final dio = _ref.read(dioClientProvider).dio;
    await DeviceRegistrationService(dio).register(fcmToken: token);
  }

  void _onForeground(RemoteMessage message) {
    final n = message.notification;
    if (n == null) return;
    localNotifications.show(
      message.hashCode,
      n.title,
      n.body,
      _notificationDetails,
    );
  }

  void _onTap(RemoteMessage message) {
    final route = message.data['route'] as String?;
    if (route == null) return;
    onDeepLink?.call(route, message.data);
  }
}
