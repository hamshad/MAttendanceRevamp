import 'package:geolocator/geolocator.dart';
import '../../models/location_result.dart';
import 'kalman_filter.dart';
import 'jump_rejection.dart';
import 'stationary_detector.dart';

class LocationFilter {
  final KalmanFilter2D _kalman = KalmanFilter2D();
  final StationaryDetector _stationary = StationaryDetector();
  LocationResult? _lastLocation;

  // Configuration Constants
  /// Raised from 80m → 120m to accept more fixes on physical devices
  /// (urban/indoor often 50-100m). Trade-off: more noise, but better coverage.
  static const double MIN_ACCURACY = 120.0;

  LocationResult? process(LocationResult raw, TrackingState currentState) {
    // LAYER 1: Accuracy Gate
    // If the GPS point is too blurry, we don't even look at it
    if (raw.accuracy > MIN_ACCURACY) {
      return null;
    }

    // Gap Reset: if the previous accepted position is too old, the user could
    // genuinely be far away (stream killed, fast movement, etc.).  Clear
    // _lastLocation so jump scoring doesn't reject legitimate new positions.
    if (_lastLocation != null) {
      final gap = raw.timestamp.difference(_lastLocation!.timestamp).inSeconds.abs();
      if (gap > 10) {
        _lastLocation = null;
      }
    }

    // LAYER 2: Jump Scoring (Soft Rejection)
    double jumpScore = 0.0;
    if (_lastLocation != null) {
      jumpScore = JumpRejection.calculateJumpScore(_lastLocation!, raw);
    }
    
    // Attachment of jumpScore
    final pointWithScore = raw.copyWith(jumpScore: jumpScore);

    // LAYER 3: Hard Rejection for Extreme Jumps
    // If a point is > 80% likely to be a jump, discard it entirely
    if (jumpScore > 0.8) {
      return null;
    }

    // LAYER 4: Kalman Smoothing
    final smoothed = _kalman.update(pointWithScore);

    // Calculate speed based on smoothed coordinates to avoid raw GPS speed spikes / jitter
    double smoothedSpeed = raw.speed;
    if (_lastLocation != null) {
      final distance = Geolocator.distanceBetween(
        _lastLocation!.latitude, _lastLocation!.longitude,
        smoothed.latitude, smoothed.longitude,
      );
      final timeDiffMs = smoothed.timestamp.difference(_lastLocation!.timestamp).inMilliseconds;
      if (timeDiffMs > 0) {
        smoothedSpeed = distance / (timeDiffMs / 1000.0);
      }
    }

    // Ensure jumpScore and smoothed speed are preserved in smoothed result for downstream confidence scoring
    final result = smoothed.copyWith(
      jumpScore: jumpScore,
      speed: smoothedSpeed,
    );

    _lastLocation = result;
    return result;
  }
  
  TrackingState evaluateState(LocationResult loc, TrackingState current) {
    return _stationary.evaluate(loc, current);
  }

  // Use this when STATIONARY to get a "locked" position
  LocationResult getStableCentroid(List<LocationResult> recentPoints) {
    if (recentPoints.isEmpty) return _lastLocation!;
    
    // Median lat/lng is more robust against outliers than average
    final lats = recentPoints.map((p) => p.latitude).toList()..sort();
    final lngs = recentPoints.map((p) => p.longitude).toList()..sort();
    
    return _lastLocation!.copyWith(
      latitude: lats[lats.length ~/ 2],
      longitude: lngs[lngs.length ~/ 2],
      accuracy: 5.0, // High confidence when stationary
      jumpScore: 0.0 // Reset jump score for centroid
    );
  }
}
