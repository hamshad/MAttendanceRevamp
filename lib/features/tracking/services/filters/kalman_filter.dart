import 'dart:math' as math;
import '../../models/location_result.dart';

class KalmanFilter2D {
  double? _lat, _lng;
  double _varianceLat = 0.0, _varianceLng = 0.0;
  
  // Q: Process Noise (How much we trust the system state to change)
  // Higher Q = Filter reacts faster to real movement but is noisier.
  // Lower Q = Filter is smoother but "lags" behind real movement.
  // 50 reflects ~7m walking movement per 5s GPS tick (~7² = 49 m²).
  final double _q = 50.0; 

  LocationResult update(LocationResult measurement) {
    // 1. Initialization
    if (_lat == null || _lng == null) {
      _lat = measurement.latitude;
      _lng = measurement.longitude;
      _varianceLat = measurement.accuracy * measurement.accuracy;
      _varianceLng = measurement.accuracy * measurement.accuracy;
      return measurement;
    }

    // 2. Prediction Step
    _varianceLat += _q;
    _varianceLng += _q;

    // 3. Update Step (Kalman Gain)
    // Dynamic R: If jumpScore is high, we increase measurement noise 
    // to make the filter less reactive to this specific point, 
    // while still moving slightly toward it.
    double r = measurement.accuracy * measurement.accuracy;
    if (measurement.jumpScore > 0) {
      r *= (1 + measurement.jumpScore * 5); // Penalize suspicious points
    }
    
    final double kLat = _varianceLat / (_varianceLat + r);
    final double kLng = _varianceLng / (_varianceLng + r);

    _lat = _lat! + kLat * (measurement.latitude - _lat!);
    _lng = _lng! + kLng * (measurement.longitude - _lng!);

    _varianceLat = (1 - kLat) * _varianceLat;
    _varianceLng = (1 - kLng) * _varianceLng;

    // Estimate new accuracy based on variance
    final newAccuracy = math.sqrt((_varianceLat + _varianceLng) / 2);

    return measurement.copyWith(
      latitude: _lat,
      longitude: _lng,
      accuracy: newAccuracy,
    );
  }

  void reset() {
    _lat = null;
    _lng = null;
  }
}
