import 'dart:async';

/// A lightweight broadcast bus for geofence auto-punch debug events.
///
/// [GeofenceMonitor] writes events here; the Field Tracking
/// debug console subscribes alongside [FieldTrackingService.debugStream].
///
/// Map keys (matching the field-tracking event schema):
/// - `ts`          — ISO-8601 timestamp
/// - `event`       — event type string (see geofence_monitor.dart)
/// - `state`       — current TrackingState name
/// - `lat`/`lng`   — location coordinates (nullable)
/// - `accuracy`    — GPS accuracy in metres (nullable)
/// - `speed`       — speed in m/s (nullable)
/// - `reason`      — human-readable description
/// - `geofenceId`  — geofence zone id (nullable)
/// - `distM`       — distance to boundary in metres (nullable)
/// - `thresholdM`  — threshold used for comparison (nullable)
/// - `confidence`  — confidence score 0.0–1.0 (nullable)
class GeofenceDebugBus {
  GeofenceDebugBus._();

  static final _ctrl =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Emit one debug event. Called only from [GeofenceMonitor].
  static void emit(Map<String, dynamic> event) {
    if (!_ctrl.isClosed) _ctrl.add(event);
  }

  /// Subscribe in the UI to receive geofence debug events.
  static Stream<Map<String, dynamic>> get stream => _ctrl.stream;
}
