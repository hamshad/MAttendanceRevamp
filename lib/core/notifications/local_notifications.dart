import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Global singleton — initialized once in main() before runApp.
final localNotifications = FlutterLocalNotificationsPlugin();

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
  );
}
