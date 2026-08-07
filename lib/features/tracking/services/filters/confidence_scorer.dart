import '../../models/location_result.dart';

class ConfidenceScorer {
  /// Calculate confidence (0.0 to 1.0) that this location is reliable
  static double score(LocationResult location, TrackingState state, {double jumpScore = 0.0}) {
    double confidence = 1.0;

    // Factor 1: GPS accuracy (lower is better)
    confidence *= _accuracyFactor(location.accuracy, state);

    // Factor 2: Jump Rejection (Soft Rejection)
    // A jumpScore of 1.0 reduces confidence to near zero
    confidence *= (1.0 - jumpScore);

    // Factor 3: Speed consistency (stable speed = higher confidence)
    // In stationary state, high speed reduces confidence
    if (state == TrackingState.STATIONARY && location.speed > 1.5) {
      confidence *= 0.5;
    }

    return confidence.clamp(0.0, 1.0);
  }

  static double _accuracyFactor(double accuracy, TrackingState state) {
    // Relaxed gates — 80m for stationary, 80m for moving.
    //
    // The background worker already absorbs raw accuracy via its GPS margin
    // (radius + 2×accuracy, clamped 10–250m), so the confidence gate must NOT
    // re-punish the same accuracy with a tighter absolute limit.  Demanding
    // ≤16m accuracy (old 40m stationary gate at 0.8 threshold) silently
    // blocked real indoor/urban fixes on devices like Samsung (20–60m GPS),
    // while margin logic would have accepted them. 80m stationary aligns the
    // gate with the margin's tolerance; fixes above that are still rejected.
    final maxAllowed = 80.0;
    if (accuracy > maxAllowed) return 0.2;

    // Linear decay from 1.0 (at 0m accuracy) to 0.5 (at maxAllowed accuracy)
    return 1.0 - (accuracy / maxAllowed) * 0.5;
  }

  static const double CONFIDENCE_THRESHOLD = 0.6; // Was 0.8 — see _accuracyFactor
}
