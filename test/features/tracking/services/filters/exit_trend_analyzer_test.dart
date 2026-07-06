import 'package:flutter_test/flutter_test.dart';
import 'package:mattendance_mobile/features/tracking/models/location_result.dart';
import 'package:mattendance_mobile/features/tracking/services/filters/exit_trend_analyzer.dart';

void main() {
  group('ExitTrendAnalyzer Resilience Tests', () {
    late ExitTrendAnalyzer analyzer;
    const radius = 150.0;

    setUp(() {
      analyzer = ExitTrendAnalyzer();
    });

    test('Scenario 1: Clean Exit', () {
      final points = [
        {'dist': 155.0, 'conf': 0.9, 'jump': 0.0},
        {'dist': 160.0, 'conf': 0.9, 'jump': 0.0},
        {'dist': 170.0, 'conf': 0.9, 'jump': 0.1},
        {'dist': 185.0, 'conf': 0.9, 'jump': 0.0},
      ];
      
      _simulatePath(analyzer, radius, points);
      expect(analyzer.isConfirmed, isTrue);
    });

    test('Scenario 2: Exit with Soft Jumps (Jitter)', () {
      final points = [
        {'dist': 155.0, 'conf': 0.5, 'jump': 0.3}, // Soft jump
        {'dist': 152.0, 'conf': 0.4, 'jump': 0.4}, // Soft jump back
        {'dist': 165.0, 'conf': 0.6, 'jump': 0.2},
        {'dist': 149.0, 'conf': 0.3, 'jump': 0.5}, // Jitter INSIDE (should not reset immediately)
        {'dist': 175.0, 'conf': 0.5, 'jump': 0.3},
        {'dist': 190.0, 'conf': 0.7, 'jump': 0.2},
        {'dist': 210.0, 'conf': 0.8, 'jump': 0.1},
      ];
      
      _simulatePath(analyzer, radius, points);
      expect(analyzer.isConfirmed, isTrue);
    });

    test('Scenario 3: Passed completely (Large distance)', () {
      final points = [
        {'dist': 155.0, 'conf': 0.5, 'jump': 0.5},
        {'dist': 350.0, 'conf': 0.6, 'jump': 0.2}, // High distance fast confirmation
      ];
      
      _simulatePath(analyzer, radius, points);
      expect(analyzer.isConfirmed, isTrue);
    });

    test('Scenario 4: Genuine move back inside', () {
      final points = [
        {'dist': 160.0, 'conf': 0.9, 'jump': 0.0},
        {'dist': 170.0, 'conf': 0.9, 'jump': 0.0},
        {'dist': 140.0, 'conf': 0.9, 'jump': 0.0}, // Clean point inside
        {'dist': 130.0, 'conf': 0.9, 'jump': 0.0}, // Second clean point inside -> Reset
      ];
      
      for (var p in points) {
        final dist = p['dist']!;
        if (dist <= radius) {
          analyzer.reset(force: false);
        } else {
          analyzer.update(dist, radius, p['conf']!, p['jump']!, TrackingState.MOVING);
        }
      }
      expect(analyzer.isConfirmed, isFalse);
      expect(analyzer.score, closeTo(0.0, 0.1));
    });
    
    test('Scenario 5: Hard Jump Reset', () {
      final points = [
        {'dist': 160.0, 'conf': 0.4, 'jump': 0.0}, // Low base
        {'dist': 170.0, 'conf': 0.4, 'jump': 0.0}, // Still below threshold
        {'dist': 300.0, 'conf': 0.9, 'jump': 0.8}, // Hard jump -> Reset!
        {'dist': 175.0, 'conf': 0.6, 'jump': 0.0}, // Point after reset
      ];
      
      _simulatePath(analyzer, radius, points);
      expect(analyzer.isConfirmed, isFalse);
      expect(analyzer.score, lessThan(1.0));
    });

    test('Scenario 6: Fluctuation Protection Suppression', () {
      final points = [
        {'dist': 155.0, 'conf': 0.3, 'jump': 0.0}, // Low base
        {'dist': 170.0, 'conf': 0.9, 'jump': 0.0}, // Sudden spike -> Wary!
        {'dist': 180.0, 'conf': 0.85, 'jump': 0.0}, // Still in wary territory
      ];
      
      _simulatePath(analyzer, radius, points);
      expect(analyzer.score, lessThan(1.0));
    });

    test('Scenario 7: User specific sequence (21->23->25->16->18->29->30)', () {
      const gRadius = 10.0; // Radius + 1/2 radius = 15.0
      final points = [
        {'dist': 21.0, 'conf': 0.9, 'jump': 0.0}, // Start (Streak 0)
        {'dist': 23.0, 'conf': 0.9, 'jump': 0.0}, // (Streak 1)
        {'dist': 25.0, 'conf': 0.9, 'jump': 0.0}, // (Streak 2)
        {'dist': 16.0, 'conf': 0.9, 'jump': 0.0}, // Jump back (Streak 0)
        {'dist': 18.0, 'conf': 0.9, 'jump': 0.0}, // (Streak 1)
        {'dist': 29.0, 'conf': 0.9, 'jump': 0.0}, // (Streak 2)
        {'dist': 30.0, 'conf': 0.9, 'jump': 0.0}, // (Streak 3) -> Should trigger
      ];
      
      _simulatePath(analyzer, gRadius, points);
      expect(analyzer.isConfirmed, isTrue);
      // It might trigger at 30 if cumulative score reaches 1.0
    });
  });
}

void _simulatePath(ExitTrendAnalyzer analyzer, double radius, List<Map<String, double>> points) {
  for (var i = 0; i < points.length; i++) {
    final p = points[i];
    final dist = p['dist']!;
    final conf = p['conf']!;
    final jump = p['jump']!;
    
    if (dist <= radius) {
      analyzer.reset(force: false);
    } else {
      analyzer.update(dist, radius, conf, jump, TrackingState.MOVING);
    }
    
    if (analyzer.isConfirmed) break;
  }
}
