class AppConstants {
  AppConstants._();

  static const String appName = 'MAttendance';
  static const String appVersion = '1.0.0';

  // API
  static const String apiBaseUrl = 'https://api.mattendance.com'; // Production URL
  static const String apiDevUrl = 'http://10.0.2.2:5001'; // Android emulator → localhost

  // Hive box names
  static const String offlinePunchBox = 'offline_punches';
  static const String cacheBox = 'cache';
  static const String geofenceSettingsBox = 'geofence_settings';
  static const String shiftsBox = 'shifts';

  // Timeouts
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 30);

  // Offline queue
  static const int maxRetryCount = 3;

  // Punch
  static const int qrTokenExpiryMinutes = 5;
}
