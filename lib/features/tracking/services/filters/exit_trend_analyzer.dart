import 'dart:math';
import '../../models/location_result.dart';

/// Analyzes movement trends to confirm if a user is truly exiting a geofence.
/// 
/// This handles "soft jumps" (suspicious GPS points) by looking at consistency
/// and trend rather than trusting individual points.
class ExitTrendAnalyzer {
  // Configuration thresholds
  final double requiredConfirmationScore;
  final int minSoftJumpsForExit;
  final int minTimeOutsideSeconds;
  final double movementAwayBonus;
  final double consistencyBonus;
  final double stationarySpeedThreshold;
  final double forcedConfirmationDistanceFactor;
  final int minInsidePointsForReset;
  final double minMovementAwayThreshold;
  final double largeJitterBackThreshold;
  final double moveBackThreshold;
  final double softJumpScoreThreshold;
  final double baseGainFactor;
  final double minBaseGain;
  final double maxBaseGain;

  // State
  double _cumulativeScore = 0.0;
  int _consecutiveOutsideCount = 0;
  int _consecutiveInsideCount = 0;
  int _softJumpCount = 0;
  DateTime? _firstExitAttempt;
  double? _lastDistance;
  double _totalDistanceGained = 0.0;
  TrackingState _lastState = TrackingState.MOVING;
  
  int _consecutiveMoveAwayCount = 0;
  final List<double> _confidenceHistory = [];
  int _waryCount = 0;
  
  ExitTrendAnalyzer({
    this.requiredConfirmationScore = 1.5,
    this.minSoftJumpsForExit = 3,
    this.minTimeOutsideSeconds = 30,
    this.movementAwayBonus = 0.4,
    this.consistencyBonus = 0.2,
    this.stationarySpeedThreshold = 1.5,
    this.forcedConfirmationDistanceFactor = 2.0, // Was 1.5 — GPS noise routinely drifts 1.5x radius on physical devices
    this.minInsidePointsForReset = 3,            // Was 2 — require more inside points before full reset
    this.minMovementAwayThreshold = 3.0, // Was 0.5 — tiny distance fluctuations should not count as moving away
    this.largeJitterBackThreshold = -12.0,
    this.moveBackThreshold = -6.0,
    this.softJumpScoreThreshold = 0.2,
    this.baseGainFactor = 0.45,
    this.minBaseGain = 0.08,
    this.maxBaseGain = 0.5,
  });

  double get score => _cumulativeScore;
  int get moveAwayStreak => _consecutiveMoveAwayCount;

  /// Resets the tracker (e.g., when user moves back inside the radius)
  /// 
  /// [force] if true, resets immediately. Otherwise, it might be deferred 
  /// to handle jitter at the boundary.
  void reset({bool force = true}) {
    if (force) {
      _cumulativeScore = 0.0;
      _consecutiveOutsideCount = 0;
      _consecutiveInsideCount = 0;
      _softJumpCount = 0;
      _consecutiveMoveAwayCount = 0;
      _firstExitAttempt = null;
      _lastDistance = null;
      _totalDistanceGained = 0.0;
      _isConfirmed = false;
      _confidenceHistory.clear();
      _waryCount = 0;
    } else {
      _consecutiveOutsideCount = 0;
      _isConfirmed = false;
      _consecutiveInsideCount++;
      _consecutiveMoveAwayCount = 0;
      
      // If we've seen multiple points inside, or we are deep inside, then reset.
      if (_consecutiveInsideCount >= minInsidePointsForReset) {
        reset(force: true);
      } else {
        _cumulativeScore = (_cumulativeScore - 0.25).clamp(0.0, requiredConfirmationScore + 0.2);
      }
    }
  }

  /// Processes a new location point that is OUTSIDE the geofence.
  void update(double distanceToCenter, double radius, double confidence, double jumpScore, [TrackingState state = TrackingState.MOVING]) {
    _lastState = state;
    _firstExitAttempt ??= DateTime.now();
    _consecutiveOutsideCount++;
    _consecutiveInsideCount = 0; 
    
    // 0. Sudden Jump Protection: If a hard jump is detected, start over.
    if (jumpScore > 0.75) {
      reset(force: true);
      return; // Stop processing this point
    }

    // 0b. Fluctuation Protection: Store history and check for wild spikes/drops
    _confidenceHistory.add(confidence);
    if (_confidenceHistory.length > 4) _confidenceHistory.removeAt(0);

    if (_confidenceHistory.length >= 2) {
      final lastConf = _confidenceHistory[_confidenceHistory.length - 2];
      final diff = (confidence - lastConf).abs();
      
      // If score jumps/drops by more than 40% in one tick, it's highly suspicious
      if (diff > 0.45) {
        _waryCount = 2; // Stay wary for this point and the next
      } else if (_waryCount > 0) {
        _waryCount--;
      }
    }

    final isWary = _waryCount > 0;

    // 1. Base Gain from Confidence
    // If we are in "Wary" state (suspicious fluctuation), we zero out the gain.
    double gain = isWary ? 0.0 : (confidence * (state == TrackingState.STATIONARY ? 0.15 : 0.5)).clamp(minBaseGain, maxBaseGain);

    // 2. Trend Analysis: Is the user moving FURTHER away?
    if (_lastDistance != null && !isWary) {
      final delta = distanceToCenter - _lastDistance!;
      if (delta > minMovementAwayThreshold) {
        _consecutiveMoveAwayCount++;
        
        // Multiplier for continuous distance increase (per user request)
        double trendMultiplier = 1.0 + (_consecutiveMoveAwayCount * 0.25).clamp(0.0, 1.0);
        gain += (movementAwayBonus * trendMultiplier);
        
        _totalDistanceGained += delta;
      } else {
        _consecutiveMoveAwayCount = 0; // Break the streak
        
        if (delta < largeJitterBackThreshold && jumpScore > (softJumpScoreThreshold * 2)) {
          gain -= 0.15;
        } else if (delta < moveBackThreshold) {
          gain -= 0.4;
        }
      }
    }

    // 3. Time Duration Bonus (only if not wary)
    final secondsOutside = DateTime.now().difference(_firstExitAttempt!).inSeconds;
    if (secondsOutside > minTimeOutsideSeconds && !isWary) {
      gain += 0.15;
    }

    // 4. Consistency Bonus
    if (_consecutiveOutsideCount > 4 && !isWary) {
      gain += consistencyBonus;
    }

    // 80% Confidence Rule: 
    // If confidence is low (< 0.8) while outside, we allow faster score buildup 
    // to "trust the exit" if it's trending away consistently.
    if (confidence < 0.8 && _consecutiveMoveAwayCount >= 2) {
      gain += 0.1;
    }

    _cumulativeScore = (_cumulativeScore + gain).clamp(0.0, requiredConfirmationScore + 0.2);
    
    // 6. Force confirmation gates
    
    // A. Excessive soft jumps while trending away
    if (_softJumpCount >= 6 && _totalDistanceGained > (radius * 0.4)) {
      _cumulativeScore = requiredConfirmationScore;
    }

    // B. Large Distance: If user is far away enough, we trust it.
    if (distanceToCenter > radius * forcedConfirmationDistanceFactor && confidence > 0.15 && _consecutiveOutsideCount >= 2) {
      _cumulativeScore = requiredConfirmationScore;
    }

    // C. Sufficient Distance Gained or Continuous Streak (3-4 points as requested)
    if (_totalDistanceGained > radius || _consecutiveMoveAwayCount >= 4) {
      _cumulativeScore = requiredConfirmationScore;
    }

    _lastDistance = distanceToCenter;
    checkConfirmation(distanceToCenter, radius);
  }

  bool _isConfirmed = false;
  bool get isConfirmed => _isConfirmed;

  /// Returns true if the analyzer is sufficiently certain that an exit has occurred.
  bool checkConfirmation(double distanceToCenter, double radius) {
    if (_cumulativeScore < requiredConfirmationScore) {
      _isConfirmed = false;
      return false;
    }

    // Relaxed STATIONARY gate: 
    // If we've gained some distance or have a streak of moving away, don't block.
    if (_lastState == TrackingState.STATIONARY) {
      if (_totalDistanceGained > 15.0 || _consecutiveMoveAwayCount >= 2) {
        _isConfirmed = true;
        return true; 
      }
      
      final safeBuffer = radius * 1.25; // Reduced from 1.5
      if (distanceToCenter < safeBuffer) {
        _isConfirmed = false;
        return false;
      }
    }

    _isConfirmed = true;
    return true;
  }

  String getReasoning() {
    final List<String> reasons = [];
    if (_consecutiveOutsideCount > 0) reasons.add('pts:$_consecutiveOutsideCount');
    if (_softJumpCount > 0) reasons.add('soft_jumps:$_softJumpCount');
    if (_firstExitAttempt != null) {
      final secs = DateTime.now().difference(_firstExitAttempt!).inSeconds;
      reasons.add('time:${secs}s');
    }
    if (_totalDistanceGained > 0) reasons.add('dist_gain:${_totalDistanceGained.toStringAsFixed(1)}m');
    reasons.add('score:${_cumulativeScore.toStringAsFixed(2)}/${requiredConfirmationScore.toStringAsFixed(2)}');
    return reasons.join(' | ');
  }
}
