import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Global singleton — initialized once in main() before runApp.
final localNotifications = FlutterLocalNotificationsPlugin();

/// Tap handler for local notification payloads — set by the app layer
/// (MainShell) once a Navigator is available. Receives the raw JSON payload
/// string carried by the notification (or null when absent).
///
/// Mirrors FCM's [onDeepLink] pattern so notification routing stays out of
/// core. The worker (background isolate) fires tap-to-punch prompts with a
/// `client_site_punch` payload; tapping routes to the selfie screen.
void Function(String? payload)? localNotificationTapHandler;

Future<void> initLocalNotifications() async {
  await localNotifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        // Request permission on demand (from settings screen), not at startup.
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      ),
    ),
    onDidReceiveNotificationResponse: (response) {
      final payload = response.payload;
      if (payload == null || payload.isEmpty) return;
      // Validate it is JSON before handing off (some legacy notifications may
      // carry non-JSON payloads).
      try {
        jsonDecode(payload);
      } catch (_) {
        return;
      }
      localNotificationTapHandler?.call(payload);
    },
  );
}
