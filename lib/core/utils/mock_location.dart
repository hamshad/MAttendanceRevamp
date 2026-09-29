import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';

/// Detects mock/spoofed GPS locations.
///
/// On Android (API 18+), `Position.isMocked` is true when the location
/// came from a mock provider (developer settings → "Select mock location app"
/// or third-party fake GPS apps).  iOS does not expose a mock flag; on iOS
/// this always returns false (fail-open).
///
/// Additional heuristics (unrealistic accuracy, speed, altitude) are
/// applied as defense-in-depth — they never replace the OS flag, they only
/// catch edge cases where the OS fails to mark a spoofed fix.
class MockLocationDetector {
  MockLocationDetector._();

  /// Notification ID for mock location alerts (shared with alignment warnings).
  static const int mockLocationNotificationId = 999;

  /// Notification channel used for mock location alerts.
  static const AndroidNotificationDetails mockLocationChannel = AndroidNotificationDetails(
    'user_alignment',
    'Attendance Alerts',
    importance: Importance.high,
    priority: Priority.high,
  );

  /// Notification details for mock location alerts.
  static const NotificationDetails mockLocationDetails = NotificationDetails(android: mockLocationChannel);

  /// Returns true if [fix] is likely a mock/spoofed location.
  ///
  /// Checks (in order):
  ///   1. OS mock flag (`Position.isMocked`) — primary signal on Android
  ///   2. Unrealistic accuracy (< 1m claimed accuracy = fake GPS often claims
  ///      "perfect" precision)
  ///   3. Unrealistic speed (> 100 m/s ≈ 360 km/h = not walking)
  ///   4. Unrealistic altitude (extreme values some mock apps produce)
  ///
  /// Fail-open: any error → false (never block a legitimate punch on a
  /// detection failure).
  static bool isMocked(Position fix) {
    try {
      // 1. OS mock flag — the definitive signal on Android
      if (fix.isMocked) {
        AppLogger.w('MOCK_DETECT: OS mock flag set');
        return true;
      }

      // 2. Unrealistic accuracy — fake GPS apps often claim ±0.x or ±1m
      // Real GPS indoors/urban is typically 5-50m; < 1m is suspicious
      if (fix.accuracy < 1.0) {
        AppLogger.w('MOCK_DETECT: Unrealistic accuracy ${fix.accuracy}m');
        return true;
      }

      // 3. Unrealistic speed — walking is ~1.4 m/s, driving ~30 m/s
      // > 100 m/s (360 km/h) is not human movement
      if (fix.speed > 100.0) {
        AppLogger.w('MOCK_DETECT: Unrealistic speed ${fix.speed}m/s');
        return true;
      }

      // 4. Unrealistic altitude — some mock apps produce extreme values
      // Real world: -500m (Dead Sea) to +9000m (Everest)
      if (fix.altitude < -1000 || fix.altitude > 10000) {
        AppLogger.w('MOCK_DETECT: Unrealistic altitude ${fix.altitude}m');
        return true;
      }

      return false;
    } catch (e) {
      AppLogger.e('MOCK_DETECT: check failed — fail-open', e);
      return false;
    }
  }

  /// Returns true if the stream position is mocked.
  ///
  /// For streams, we also check for sudden teleportation (position jumps
  /// that are physically impossible between consecutive fixes).  This
  /// requires the previous position — pass null for the first fix.
  static bool isMockedStream(Position fix, Position? previousFix) {
    if (isMocked(fix)) return true;

    if (previousFix != null) {
      try {
        final distance = Geolocator.distanceBetween(
          previousFix.latitude,
          previousFix.longitude,
          fix.latitude,
          fix.longitude,
        );
        final timeDiff = fix.timestamp
            .difference(previousFix.timestamp)
            .inMilliseconds;
        if (timeDiff > 0) {
          final speed = distance / (timeDiff / 1000.0);
          // Teleportation: > 100 m/s between consecutive stream fixes
          if (speed > 100.0) {
            AppLogger.w('MOCK_DETECT: Teleportation detected (${speed.toStringAsFixed(1)}m/s)');
            return true;
          }
        }
      } catch (e) {
        AppLogger.e('MOCK_DETECT: stream teleportation check failed', e);
      }
    }

    return false;
  }

  /// Shows a persistent notification warning the user about mock location.
  ///
  /// Rate-limited via SharedPreferences to avoid spam (max once per hour).
  /// Returns true if notification was shown, false if rate-limited.
  static Future<bool> showMockLocationWarning() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now().millisecondsSinceEpoch;
      final lastShown = prefs.getInt('mock_location_warned_ts') ?? 0;
      
      // Rate limit: once per hour (3600000 ms)
      if (now - lastShown < 3600000) {
        return false;
      }
      
      await prefs.setInt('mock_location_warned_ts', now);
      
      final notif = FlutterLocalNotificationsPlugin();
      await notif.show(
        mockLocationNotificationId,
        'Mock Location Detected',
        'A mock/fake GPS location was detected. Auto-punch and tracking '
        'will not work correctly. Disable "Select mock location app" in '
        'Developer Options, or turn off any fake GPS apps.',
        mockLocationDetails,
      );
      
      AppLogger.i('MOCK_DETECT: Warning notification shown');
      return true;
    } catch (e) {
      AppLogger.e('MOCK_DETECT: Failed to show warning notification', e);
      return false;
    }
  }

  /// Cancels the mock location warning notification.
  static Future<void> cancelMockLocationWarning() async {
    try {
      final notif = FlutterLocalNotificationsPlugin();
      await notif.cancel(mockLocationNotificationId);
    } catch (e) {
      AppLogger.e('MOCK_DETECT: Failed to cancel warning notification', e);
    }
  }
}