class GeofenceScheduler {
  GeofenceScheduler._();
  static Future<void> init() async {}
  static Future<void> startIfWithinShiftWindow(List list) async {}
  static Future<void> scheduleNextShift(dynamic shift) async {}
  static Future<void> scheduleRestartAlarm() async {}
  static Future<void> cancel() async {}
  static Future<void> stopGeofenceService() async {}
  static Future<String?> consumeMissedAlarmFlag() async => null;
}
