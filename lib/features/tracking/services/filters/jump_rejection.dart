import 'package:geolocator/geolocator.dart';
import '../../models/location_result.dart';

class JumpRejection {
  /// Returns a score from 0.0 (clean) to 1.0 (highly suspicious)
  static double calculateJumpScore(LocationResult last, LocationResult current) {
    final distance = Geolocator.distanceBetween(
      last.latitude, last.longitude,
      current.latitude, current.longitude
    );

    // Time difference in seconds
    final timeDiffMs = current.timestamp.millisecondsSinceEpoch - last.timestamp.millisecondsSinceEpoch;
    final timeDiffSec = timeDiffMs > 0 ? timeDiffMs / 1000.0 : 1.0;
    
    // The "effective speed" of the jump in m/s
    final jumpSpeed = distance / timeDiffSec;

    double score = 0.0;

    // 1. Accuracy Check: How far is the jump relative to reported accuracy?
    // threshold = baseline where we start suspecting (e.g. 1.5x accuracy)
    // maxThreshold = baseline where we are 100% sure it's a jump (e.g. 5.0x accuracy)
    final threshold = (current.accuracy * 1.5).clamp(10.0, 50.0);
    final maxThreshold = (current.accuracy * 5.0).clamp(50.0, 200.0);

    if (distance > threshold) {
      final ratio = (distance - threshold) / (maxThreshold - threshold);
      score = ratio.clamp(0.0, 1.0);
    }
    
    // 2. Speed Check: if the "effective speed" of the jump is > 10 m/s (~36 km/h) 
    // AND the user's actual device-reported speed is low (< 1 m/s)
    if (jumpSpeed > 10.0 && current.speed < 1.0) {
      score = (score + 0.6).clamp(0.0, 1.0);
    }
    
    // 3. Acceleration Check: Impossible acceleration
    if (last.speed < 1.0 && current.speed > 25.0 && timeDiffSec < 5) {
      score = (score + 0.8).clamp(0.0, 1.0);
    }
    
    // 4. Extreme Displacement: > 80m in < 2s is almost always a glitch in an office setting
    if (distance > 80.0 && timeDiffSec < 2.0) {
      score = 1.0;
    }

    return score;
  }
}
