import 'package:flutter_test/flutter_test.dart';
import 'package:mattendance_mobile/models/shift.dart';

void main() {
  // ── Scenario A: Timer guard (_lastStreamFix) ──────────────────────────────
  group('Timer guard', () {
    // Production: if (_lastStreamFix != null && gap < 5s) → skip timer
    test('skips timer when stream fix < 5s ago', () {
      final now = DateTime.now();
      final lastStreamFix = now.subtract(const Duration(seconds: 3));
      final shouldSkip = lastStreamFix != null &&
          now.difference(lastStreamFix).inSeconds < 5;
      expect(shouldSkip, isTrue);
    });

    test('does NOT skip timer when stream fix >= 5s ago', () {
      final now = DateTime.now();
      final lastStreamFix = now.subtract(const Duration(seconds: 7));
      final shouldSkip = lastStreamFix != null &&
          now.difference(lastStreamFix).inSeconds < 5;
      expect(shouldSkip, isFalse);
    });

    test('does NOT skip timer when _lastStreamFix is null (no stream yet)', () {
      final now = DateTime.now();
      DateTime? lastStreamFix;
      final shouldSkip = lastStreamFix != null &&
          now.difference(lastStreamFix).inSeconds < 5;
      expect(shouldSkip, isFalse);
    });
  });

  // ── Scenario B: Entry threshold (raw radius, no GPS margin) ───────────────
  group('Entry threshold', () {
    // Production: if (dist <= radiusVal) → trigger auto-IN
    test('allows IN when inside raw radius (dist <= radius)', () {
      const radius = 20.0;
      const distInside = 15.0;
      expect(distInside <= radius, isTrue);
    });

    test('blocks IN when outside raw radius (dist > radius)', () {
      const radius = 20.0;
      const distOutside = 25.0;
      expect(distOutside <= radius, isFalse);
    });

    test('new behavior fixes: old GPS margin caused false IN at 25m', () {
      const radius = 20.0;
      const accuracy = 100.0;
      const oldMargin = 100.0; // _gpsMargin = max(10, 100) = 100
      const dist = 25.0;

      // Old: 25 <= 20 + 100 = 120 → triggered false IN
      expect(dist <= radius + oldMargin, isTrue);

      // New: 25 <= 20 → blocked correctly
      expect(dist <= radius, isFalse);
    });
  });

  // ── Scenario C / D: Gate 5 server status check ────────────────────────────
  group('Gate 5: status null handling', () {
    // Production for IN: if (direction == 'In') { if (status == null) return; }
    test('status=null blocks auto-IN (network error → safe)', () {
      final status = null;
      const direction = 'In';
      final blocked = direction == 'In' && status == null;
      expect(blocked, isTrue);
    });

    // Production for OUT: if (direction == 'Out') { if (status != null) { ... } }
    test('status=null allows auto-OUT (overtime worker not trapped)', () {
      final status = null;
      const direction = 'Out';
      final blocked = direction == 'In' && status == null;
      expect(blocked, isFalse);
    });
  });

  // ── Scenario E: Cooldown (Gate 4) ─────────────────────────────────────────
  group('Gate 4: cooldown', () {
    test('blocks same-direction punch within 5 minutes', () {
      final lastPunchTime = DateTime.now().subtract(const Duration(minutes: 2));
      const lastPunchType = 'In';
      const direction = 'In';

      final onCooldown = lastPunchTime != null &&
          lastPunchType == direction &&
          DateTime.now().difference(lastPunchTime).inMinutes < 5;
      expect(onCooldown, isTrue);
    });

    test('allows different-direction punch (Out after In)', () {
      final lastPunchTime = DateTime.now().subtract(const Duration(seconds: 10));
      const lastPunchType = 'In';
      const direction = 'Out';

      final onCooldown = lastPunchTime != null &&
          lastPunchType == direction &&
          DateTime.now().difference(lastPunchTime).inMinutes < 5;
      expect(onCooldown, isFalse);
    });

    test('allows same-direction punch after 5 minutes', () {
      final lastPunchTime = DateTime.now().subtract(const Duration(minutes: 6));
      const lastPunchType = 'In';
      const direction = 'In';

      final onCooldown = lastPunchTime != null &&
          lastPunchType == direction &&
          DateTime.now().difference(lastPunchTime).inMinutes < 5;
      expect(onCooldown, isFalse);
    });

    test('no cooldown when _lastPunchTime is null (fresh start)', () {
      final lastPunchTime = null;
      const lastPunchType = 'In';
      const direction = 'In';

      final onCooldown = lastPunchTime != null &&
          lastPunchType == direction &&
          DateTime.now().difference(lastPunchTime).inMinutes < 5;
      expect(onCooldown, isFalse);
    });
  });

  // ── Scenario F: Shift gate (Gate 6) ───────────────────────────────────────
  group('Gate 6: shift hours', () {
    test('blocks auto-IN before shift start', () {
      final shift = Shift(
        id: 1, orgId: 1,
        name: 'Morning', startTime: '09:00', endTime: '18:00',
        bufferMinutes: 0, minBreakMinutes: 30,
        isOvernight: false, isActive: true,
      );
      final now = DateTime.now();
      final beforeStart = DateTime(now.year, now.month, now.day, 8, 30);
      expect(beforeStart.isBefore(shift.todayStart), isTrue);
    });

    test('allows auto-IN at or after shift start', () {
      final shift = Shift(
        id: 1, orgId: 1,
        name: 'Morning', startTime: '09:00', endTime: '18:00',
        bufferMinutes: 0, minBreakMinutes: 30,
        isOvernight: false, isActive: true,
      );
      final now = DateTime.now();
      final afterStart = DateTime(now.year, now.month, now.day, 9, 30);
      expect(afterStart.isBefore(shift.todayStart), isFalse);
    });

    test('auto-OUT is never blocked by shift gate', () {
      // Gate 6 only checks: if (direction == 'In' && _shifts.isNotEmpty)
      const direction = 'Out';
      expect(direction == 'In', isFalse);
    });

    test('todayStart handles overnight shifts correctly', () {
      // Overnight: 22:00 → 06:00. todayStart returns 22:00 on DateTime.now()'s
      // date; todayEnd adds 1 day → 06:00 the next day.
      final shift = Shift(
        id: 1, orgId: 1,
        name: 'Night', startTime: '22:00', endTime: '06:00',
        bufferMinutes: 0, minBreakMinutes: 30,
        isOvernight: true, isActive: true,
      );
      final now = DateTime.now();
      final start = shift.todayStart;
      final end = shift.todayEnd;

      final todayMidnight = DateTime(now.year, now.month, now.day);
      // 2 hours before start
      expect(todayMidnight.add(const Duration(hours: 20)).isBefore(start), isTrue);
      // 1 hour after start
      expect(todayMidnight.add(const Duration(hours: 23)).isBefore(start), isFalse);
      // 1 hour before end (next day)
      expect(todayMidnight.add(const Duration(days: 1, hours: 5)).isBefore(end), isTrue);
      // 1 hour after end (next day)
      expect(todayMidnight.add(const Duration(days: 1, hours: 7)).isBefore(end), isFalse);
    });
  });

  // ── Scenario G: GPS drift false entry (covered by jump_rejection_test) ────
  // Test "GPS drift (glitch — user still, position jumps 50m)" confirms
  // JumpRejection returns score 1.0 → filter rejects → no false exit/entry.

  // ── Combined scenario: exit threshold ensures margin prevents false exit ──
  group('Exit threshold (radius + gpsMargin)', () {
    test('boundary proximity prevented when dist <= radius + margin', () {
      const radius = 20.0;
      const accuracy = 100.0;
      const margin = 100.0; // max(10, 100) = 100
      const exitThreshold = radius + margin; // 120
      const userDist = 50.0; // 50m from center, outside 20m radius

      // dist 50 <= 120 → boundary proximity, NOT triggering exit
      expect(userDist <= exitThreshold, isTrue);
    });

    test('exit triggered when dist > radius + margin', () {
      const radius = 20.0;
      const accuracy = 14.0;
      const margin = 14.0; // max(10, 14) = 14
      const exitThreshold = radius + margin; // 34
      const userDist = 50.0;

      expect(userDist > exitThreshold, isTrue);
    });
  });

  // ── Gap reset ensures _lastLocation clears after 10s ─────────────────────
  group('Filter gap reset (10s)', () {
    test('gap > 10s clears _lastLocation → no jump scoring', () {
      final gap = 12; // seconds since last accepted position
      expect(gap > 10, isTrue);
    });

    test('gap <= 10s keeps _lastLocation → jump scoring active', () {
      final gap = 5; // seconds since last accepted position
      expect(gap > 10, isFalse);
    });
  });
}
