
enum TrackingState {
  IDLE,       // Tracking is off
  MOVING,     // Normal walking/driving
  STATIONARY, // User has stopped (Accuracy Freeze active)
  ACTIVE_TRACKING // High frequency (e.g., during an active trip)
}

class LocationResult {
  final double latitude;
  final double longitude;
  final double accuracy;
  final double speed;
  final double altitude;
  final double heading;
  final DateTime timestamp;
  
  /// A score from 0.0 (clean) to 1.0 (highly suspicious jump)
  final double jumpScore;

  LocationResult({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    this.speed = 0.0,
    this.altitude = 0.0,
    this.heading = 0.0,
    this.jumpScore = 0.0,
    DateTime? timestamp,
  }) : this.timestamp = timestamp ?? DateTime.now();

  LocationResult copyWith({
    double? latitude,
    double? longitude,
    double? accuracy,
    double? speed,
    double? altitude,
    double? heading,
    double? jumpScore,
    DateTime? timestamp,
  }) {
    return LocationResult(
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      accuracy: accuracy ?? this.accuracy,
      speed: speed ?? this.speed,
      altitude: altitude ?? this.altitude,
      heading: heading ?? this.heading,
      jumpScore: jumpScore ?? this.jumpScore,
      timestamp: timestamp ?? this.timestamp,
    );
  }
}
