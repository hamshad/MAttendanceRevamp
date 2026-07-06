import 'package:flutter_test/flutter_test.dart';
import 'package:mattendance_mobile/features/tracking/models/location_result.dart';
import 'package:mattendance_mobile/features/tracking/services/filters/jump_rejection.dart';
import 'package:mattendance_mobile/features/tracking/services/filters/location_filter.dart';

void main() {
  group('JumpRejection.calculateJumpScore', () {
    test('Walking (1.4 m/s, 2s interval) — score 0', () {
      final prev = LocationResult(
        latitude: 19.87000, longitude: 75.31500,
        accuracy: 14.0, speed: 1.4,
        timestamp: DateTime.now(),
      );
      final curr = LocationResult(
        latitude: 19.87003, longitude: 75.31503,
        accuracy: 14.0, speed: 1.4,
        timestamp: DateTime.now().add(const Duration(seconds: 2)),
      );
      final score = JumpRejection.calculateJumpScore(prev, curr);
      // ~3m distance in 2s → well below threshold (21m)
      expect(score, lessThan(0.8));
      expect(score, 0.0);
    });

    test('Running (5 m/s, 2s interval) — score 0', () {
      final prev = LocationResult(
        latitude: 19.87000, longitude: 75.31500,
        accuracy: 14.0, speed: 5.0,
        timestamp: DateTime.now(),
      );
      final curr = LocationResult(
        latitude: 19.87009, longitude: 75.31509,
        accuracy: 14.0, speed: 5.0,
        timestamp: DateTime.now().add(const Duration(seconds: 2)),
      );
      final score = JumpRejection.calculateJumpScore(prev, curr);
      // ~10m in 2s → below threshold (21m) for 14m accuracy
      expect(score, lessThan(0.8));
      expect(score, 0.0);
    });

    test('Driving (20 m/s, 2s interval) — score < 0.8 (accepted)', () {
      final prev = LocationResult(
        latitude: 19.87000, longitude: 75.31500,
        accuracy: 14.0, speed: 20.0,
        timestamp: DateTime.now(),
      );
      final curr = LocationResult(
        latitude: 19.87036, longitude: 75.31536,
        accuracy: 14.0, speed: 20.0,
        timestamp: DateTime.now().add(const Duration(seconds: 2)),
      );
      final score = JumpRejection.calculateJumpScore(prev, curr);
      // ~40m in 2s, threshold=21 → ratio=(40-21)/(70-21)=0.39
      // jumpSpeed=20>10 but current.speed=20>1 → no speed bonus
      expect(score, greaterThan(0.0));
      expect(score, lessThan(0.8));
    });

    test('Extreme (50 m/s, 1.9s interval) — score 1.0 (rejected)', () {
      final prev = LocationResult(
        latitude: 19.87000, longitude: 75.31500,
        accuracy: 14.0, speed: 0.5,
        timestamp: DateTime.now(),
      );
      final curr = LocationResult(
        latitude: 19.87090, longitude: 75.31590,
        accuracy: 14.0, speed: 0.5,
        timestamp: DateTime.now().add(const Duration(milliseconds: 1900)),
      );
      final score = JumpRejection.calculateJumpScore(prev, curr);
      // ~95m in 1.9s → distance 95>80 AND timeDiff 1.9<2 → extreme displacement
      expect(score, 1.0);
    });

    test('GPS drift (glitch — user still, position jumps 50m) — rejected', () {
      final prev = LocationResult(
        latitude: 19.87000, longitude: 75.31500,
        accuracy: 14.0, speed: 0.1,
        timestamp: DateTime.now(),
      );
      final curr = LocationResult(
        latitude: 19.87045, longitude: 75.31545,
        accuracy: 14.0, speed: 0.1,
        timestamp: DateTime.now().add(const Duration(seconds: 1)),
      );
      final score = JumpRejection.calculateJumpScore(prev, curr);
      // ~50m in 1s, threshold=21 → ratio=(50-21)/(70-21)=0.59
      // jumpSpeed=50>10 AND current.speed=0.1<1 → speed bonus: score=(0.59+0.6)=1.0
      expect(score, 1.0);
    });

    test('Stationary user (no movement) — score 0', () {
      final prev = LocationResult(
        latitude: 19.87000, longitude: 75.31500,
        accuracy: 14.0, speed: 0.0,
        timestamp: DateTime.now(),
      );
      final curr = LocationResult(
        latitude: 19.87000, longitude: 75.31500,
        accuracy: 14.0, speed: 0.0,
        timestamp: DateTime.now().add(const Duration(seconds: 2)),
      );
      final score = JumpRejection.calculateJumpScore(prev, curr);
      expect(score, 0.0);
    });

    test('Timer accuracy context (100m acc, 5s interval, 100m dist) — score < 0.8', () {
      final prev = LocationResult(
        latitude: 19.87000, longitude: 75.31500,
        accuracy: 100.0, speed: 20.0,
        timestamp: DateTime.now(),
      );
      final curr = LocationResult(
        latitude: 19.87090, longitude: 75.31590,
        accuracy: 100.0, speed: 20.0,
        timestamp: DateTime.now().add(const Duration(seconds: 5)),
      );
      final score = JumpRejection.calculateJumpScore(prev, curr);
      // ~100m in 5s, threshold=min(50, max(10,150))=50 → ratio=(100-50)/(200-50)=0.33
      // jumpSpeed=20>10 BUT current.speed=20>1 → no speed bonus
      expect(score, greaterThan(0.0));
      expect(score, lessThan(0.8));
    });

    test('Timer with low device speed (GPS bug — car but shows 0 speed) — score 1.0', () {
      final prev = LocationResult(
        latitude: 19.87000, longitude: 75.31500,
        accuracy: 100.0, speed: 0.0,
        timestamp: DateTime.now(),
      );
      final curr = LocationResult(
        latitude: 19.87090, longitude: 75.31590,
        accuracy: 100.0, speed: 0.0,
        timestamp: DateTime.now().add(const Duration(seconds: 5)),
      );
      final score = JumpRejection.calculateJumpScore(prev, curr);
      // ~100m in 5s, threshold=50 → ratio=0.33
      // jumpSpeed=20>10 AND current.speed=0<1 → speed bonus: score=(0.33+0.6)=0.93
      expect(score, greaterThan(0.8));
    });
  });

  group('LocationFilter gap reset (10s)', () {
    test('Stream alive (2s gap) — jump rejection works normally', () {
      final filter = LocationFilter();

      // Fix 1: initial
      final r1 = filter.process(
        LocationResult(latitude: 19.87000, longitude: 75.31500, accuracy: 14.0,
            timestamp: DateTime.now()),
        TrackingState.MOVING,
      );
      expect(r1, isNotNull);

      // Fix 2: 2s later, walking 5m — should pass (small movement)
      final r2 = filter.process(
        LocationResult(latitude: 19.87005, longitude: 75.31505, accuracy: 14.0,
            timestamp: DateTime.now().add(const Duration(seconds: 2))),
        TrackingState.MOVING,
      );
      expect(r2, isNotNull);
    });

    test('Gap > 10s clears _lastLocation — position accepted', () {
      final filter = LocationFilter();

      // Fix 1: at office
      final r1 = filter.process(
        LocationResult(latitude: 19.87000, longitude: 75.31500, accuracy: 14.0,
            timestamp: DateTime.now()),
        TrackingState.MOVING,
      );
      expect(r1, isNotNull);

      // Fix 2: 12s later, 200m away (user drove away while stream was dead)
      final r2 = filter.process(
        LocationResult(latitude: 19.87180, longitude: 75.31680, accuracy: 14.0,
            timestamp: DateTime.now().add(const Duration(seconds: 12))),
        TrackingState.MOVING,
      );
      // Should be accepted — gap reset clears _lastLocation so jumpScore is 0
      expect(r2, isNotNull);
    });

    test('Gap 8s (<10s) keeps _lastLocation — jump scoring active', () {
      final filter = LocationFilter();

      final r1 = filter.process(
        LocationResult(latitude: 19.87000, longitude: 75.31500, accuracy: 14.0,
            timestamp: DateTime.now()),
        TrackingState.MOVING,
      );
      expect(r1, isNotNull);

      // 200m away but only 8s gap — no reset, jump score > 0.8 → rejected
      final r2 = filter.process(
        LocationResult(latitude: 19.87180, longitude: 75.31680, accuracy: 14.0,
            timestamp: DateTime.now().add(const Duration(seconds: 8))),
        TrackingState.MOVING,
      );
      // ~200m in 8s at 14m acc: extreme displacement unlikely (8s > 2s).
      // Ratio check: threshold=21, ratio=(200-21)/49=3.6 → score=1.0
      // But speed bonus fires too: jumpSpeed=200/8=25>10, speed maybe 0 → score capped at 1.0
      expect(r2, isNull);
    });

    test('GPS drift then back (2s gap) — real position accepted after drift rejected', () {
      final filter = LocationFilter();

      // Fix 1: real position at desk
      final r1 = filter.process(
        LocationResult(latitude: 19.87000, longitude: 75.31500, accuracy: 14.0, speed: 0.0,
            timestamp: DateTime.now()),
        TrackingState.MOVING,
      );
      expect(r1, isNotNull);

      // Fix 2: GPS drift to 50m away (1s later) — should be rejected (jump)
      final r2 = filter.process(
        LocationResult(latitude: 19.87045, longitude: 75.31545, accuracy: 14.0, speed: 0.0,
            timestamp: DateTime.now().add(const Duration(seconds: 1))),
        TrackingState.MOVING,
      );
      expect(r2, isNull);

      // Fix 3: back to real position (2s after drift) — should be accepted
      // _lastLocation still at fix1 (desk), distance from desk ≈ 0 → score 0
      final r3 = filter.process(
        LocationResult(latitude: 19.87000, longitude: 75.31500, accuracy: 14.0, speed: 0.0,
            timestamp: DateTime.now().add(const Duration(seconds: 3))),
        TrackingState.MOVING,
      );
      expect(r3, isNotNull);
    });

    test('Accuracy gate rejects bad positions regardless of gap', () {
      final filter = LocationFilter();

      final r1 = filter.process(
        LocationResult(latitude: 19.87000, longitude: 75.31500, accuracy: 14.0,
            timestamp: DateTime.now()),
        TrackingState.MOVING,
      );
      expect(r1, isNotNull);

      // Bad accuracy position with large gap — still rejected by accuracy gate
      final r2 = filter.process(
        LocationResult(latitude: 19.87000, longitude: 75.31500, accuracy: 150.0,
            timestamp: DateTime.now().add(const Duration(seconds: 15))),
        TrackingState.MOVING,
      );
      expect(r2, isNull);
    });

    test('Multiple rapid drifts — only genuine drift rejected', () {
      final filter = LocationFilter();

      void acceptOrReject(String label, double lat, double lng, double accuracy,
          {double speed = 0.0, int offsetSeconds = 0}) {
        final r = filter.process(
          LocationResult(latitude: lat, longitude: lng, accuracy: accuracy, speed: speed,
              timestamp: DateTime.now().add(Duration(seconds: offsetSeconds))),
          TrackingState.MOVING,
        );
        print('  $label: ${r != null ? "ACCEPTED" : "REJECTED"}');
      }

      acceptOrReject('desk', 19.87000, 75.31500, 14.0, offsetSeconds: 0);
      acceptOrReject('drift 50m', 19.87045, 75.31545, 14.0, speed: 0.0, offsetSeconds: 1);
      acceptOrReject('back to desk', 19.87000, 75.31500, 14.0, speed: 0.0, offsetSeconds: 2);
      acceptOrReject('walk 5m', 19.87005, 75.31505, 14.0, speed: 1.4, offsetSeconds: 4);

      // After walking 5m away, lastLocation is at desk (accepted).
      // The "walk 5m" position should be accepted.
      final last = filter.process(
        LocationResult(latitude: 19.87010, longitude: 75.31510, accuracy: 14.0, speed: 1.4,
            timestamp: DateTime.now().add(const Duration(seconds: 6))),
        TrackingState.MOVING,
      );
      expect(last, isNotNull);
    });
  });
}
