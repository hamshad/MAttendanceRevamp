import '../../models/location_result.dart';

class StationaryDetector {
  static const double SPEED_THRESHOLD = 0.6; // m/s (~2 km/h)
  static const int TIME_THRESHOLD_SEC = 45; // seconds to confirm stopped
  
  DateTime? _stopStartTime;

  TrackingState evaluate(LocationResult loc, TrackingState current) {
    // Ignore soft jumps (telemetry glitches) for stationary evaluation
    if (loc.jumpScore > 0.5) {
      return current;
    }

    if (loc.speed < SPEED_THRESHOLD) {
      _stopStartTime ??= DateTime.now();
      
      final duration = DateTime.now().difference(_stopStartTime!).inSeconds;
      if (duration >= TIME_THRESHOLD_SEC) {
        return TrackingState.STATIONARY;
      }
    } else {
      _stopStartTime = null;
      if (current == TrackingState.STATIONARY) return TrackingState.MOVING;
    }
    return current;
  }
}
