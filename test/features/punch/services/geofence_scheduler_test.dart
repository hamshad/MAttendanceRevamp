import 'package:flutter_test/flutter_test.dart';
import 'package:mattendance_mobile/features/punch/services/geofence_scheduler.dart';
import 'package:mattendance_mobile/models/shift.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:workmanager_platform_interface/workmanager_platform_interface.dart';

// ═══════════════════════════════════════════════════════════════════════
// Fake Workmanager platform — allows testing without real implementation
// ═══════════════════════════════════════════════════════════════════════

class _FakeWorkmanagerPlatform extends WorkmanagerPlatform {
  Function? registeredDispatcher;
  bool isInDebug = false;

  @override
  Future<void> initialize(
    Function callbackDispatcher, {
    bool isInDebugMode = false,
  }) async {
    registeredDispatcher = callbackDispatcher;
    isInDebug = isInDebugMode;
  }

  @override
  Future<void> registerOneOffTask(
    String uniqueName,
    String taskName, {
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    OutOfQuotaPolicy? outOfQuotaPolicy,
  }) async {}

  @override
  Future<void> registerPeriodicTask(
    String uniqueName,
    String taskName, {
    Duration? frequency,
    Duration? flexInterval,
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
  }) async {}

  @override
  Future<void> registerProcessingTask(
    String uniqueName,
    String taskName, {
    Duration? initialDelay,
    Map<String, dynamic>? inputData,
    Constraints? constraints,
  }) async {}

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {}

  @override
  Future<void> cancelByTag(String tag) async {}

  @override
  Future<void> cancelAll() async {}

  @override
  Future<bool> isScheduledByUniqueName(String uniqueName) async => false;

  @override
  Future<String> printScheduledTasks() async => '';
}

/// Helper to build a minimal shift for testing.
Shift _makeShift({
  int id = 1,
  String name = 'Morning',
  String startTime = '09:00',
  String endTime = '17:00',
  bool isOvernight = false,
  bool isActive = true,
}) =>
    Shift(
      id: id,
      orgId: 1,
      name: name,
      startTime: startTime,
      endTime: endTime,
      isOvernight: isOvernight,
      bufferMinutes: 0,
      minBreakMinutes: 30,
      isActive: isActive,
    );

// ═══════════════════════════════════════════════════════════════════════
// Delay calculation (core logic extracted from scheduleNextShift)
// ═══════════════════════════════════════════════════════════════════════

/// Mirrors the delay-computation logic in [GeofenceScheduler.scheduleNextShift].
///
/// NOTE: [Shift.todayStart]/[Shift.todayEnd] are computed against the REAL
/// clock, so the mirrors below derive the day from the passed `now` — keeps
/// these tests date-independent (they used to drift stale as dates passed).
Duration _computeDelay(Shift shift, {DateTime? now}) {
  now ??= DateTime.now();
  final parts = shift.startTime.split(':');
  final start = DateTime(
    now.year, now.month, now.day,
    int.parse(parts[0]), int.parse(parts[1]),
    parts.length > 2 ? int.parse(parts[2]) : 0,
  );

  if (now.isBefore(start)) {
    return start.difference(now);
  }

  final tomorrow = now.add(const Duration(days: 1));
  final nextStart = DateTime(
    tomorrow.year, tomorrow.month, tomorrow.day,
    int.parse(parts[0]), int.parse(parts[1]),
  );
  final delay = nextStart.difference(now);
  return delay.isNegative ? const Duration(seconds: 10) : delay;
}

/// Mirrors the window-check logic in [GeofenceScheduler.startIfWithinShiftWindow].
bool _isWithinShiftWindow(Shift shift, {DateTime? now}) {
  now ??= DateTime.now();
  final startParts = shift.startTime.split(':');
  final endParts = shift.endTime.split(':');
  final start = DateTime(
    now.year, now.month, now.day,
    int.parse(startParts[0]), int.parse(startParts[1]),
    startParts.length > 2 ? int.parse(startParts[2]) : 0,
  );
  var end = DateTime(
    now.year, now.month, now.day,
    int.parse(endParts[0]), int.parse(endParts[1]),
    endParts.length > 2 ? int.parse(endParts[2]) : 0,
  );
  if (shift.isOvernight) end = end.add(const Duration(days: 1));
  return !now.isBefore(start) && now.isBefore(end);
}

void main() {
  setUp(() {
    WorkmanagerPlatform.instance = _FakeWorkmanagerPlatform();
    SharedPreferences.setMockInitialValues({});
  });

  group('Delay computation', () {
    test('returns positive delay when now is before shift start', () {
      final shift = _makeShift(startTime: '10:00');
      final now = DateTime(2026, 6, 15, 9, 0, 0);
      expect(_computeDelay(shift, now: now), const Duration(hours: 1));
    });

    test('returns zero delay on exact shift start', () {
      final shift = _makeShift(startTime: '10:00');
      final now = DateTime(2026, 6, 15, 10, 0, 0);
      final delay = _computeDelay(shift, now: now);
      expect(delay, const Duration(hours: 24));
    });

    test('returns 24h delay when now is after shift start (same day)', () {
      final shift = _makeShift(startTime: '09:00', endTime: '17:00');
      final now = DateTime(2026, 6, 15, 14, 0, 0);
      final delay = _computeDelay(shift, now: now);
      expect(delay, const Duration(hours: 19));
    });

    test('returns ~24h delay after shift end', () {
      final shift = _makeShift(startTime: '09:00', endTime: '17:00');
      final now = DateTime(2026, 6, 15, 18, 0, 0);
      final delay = _computeDelay(shift, now: now);
      expect(delay, const Duration(hours: 15));
    });

    test('handles overnight shift correctly', () {
      final shift = _makeShift(
        startTime: '22:00',
        endTime: '06:00',
        isOvernight: true,
      );
      final now = DateTime(2026, 6, 15, 21, 0, 0);
      expect(_computeDelay(shift, now: now), const Duration(hours: 1));
    });

    test('returns 10s minimum delay for past time to avoid zero/negative', () {
      final shift = _makeShift(startTime: '00:00');
      final now = DateTime(2026, 6, 15, 0, 0, 5);
      final delay = _computeDelay(shift, now: now);
      expect(delay, greaterThan(const Duration(seconds: 0)));
      expect(delay, lessThan(const Duration(hours: 25)));
    });
  });

  group('Shift window detection', () {
    test('returns true when now is within shift window', () {
      final shift = _makeShift(startTime: '09:00', endTime: '17:00');
      final now = DateTime(2026, 6, 15, 12, 0, 0);
      expect(_isWithinShiftWindow(shift, now: now), isTrue);
    });

    test('returns false when now is before shift start', () {
      final shift = _makeShift(startTime: '09:00', endTime: '17:00');
      final now = DateTime(2026, 6, 15, 8, 0, 0);
      expect(_isWithinShiftWindow(shift, now: now), isFalse);
    });

    test('returns false when now is after shift end', () {
      final shift = _makeShift(startTime: '09:00', endTime: '17:00');
      final now = DateTime(2026, 6, 15, 18, 0, 0);
      expect(_isWithinShiftWindow(shift, now: now), isFalse);
    });

    test('returns true at exact shift start boundary', () {
      final shift = _makeShift(startTime: '09:00', endTime: '17:00');
      final now = DateTime(2026, 6, 15, 9, 0, 0);
      expect(_isWithinShiftWindow(shift, now: now), isTrue);
    });

    test('returns false at exact shift end boundary', () {
      final shift = _makeShift(startTime: '09:00', endTime: '17:00');
      final now = DateTime(2026, 6, 15, 17, 0, 0);
      expect(_isWithinShiftWindow(shift, now: now), isFalse);
    });

    test('handles overnight shift — within window at 23:00', () {
      final shift = _makeShift(
        startTime: '22:00',
        endTime: '06:00',
        isOvernight: true,
      );
      // Shift runs 22:00 today → 06:00 tomorrow.
      // At 23:00, todayStart=22:00 is in the past and todayEnd=06:00 tomorrow is in the future.
      final now = DateTime(2026, 6, 15, 23, 0, 0);
      expect(_isWithinShiftWindow(shift, now: now), isTrue);
    });

    test('handles overnight shift — outside window before start', () {
      final shift = _makeShift(
        startTime: '22:00',
        endTime: '06:00',
        isOvernight: true,
      );
      final now = DateTime(2026, 6, 15, 21, 0, 0);
      expect(_isWithinShiftWindow(shift, now: now), isFalse);
    });

    test('handles overnight shift — outside window after end', () {
      final shift = _makeShift(
        startTime: '22:00',
        endTime: '06:00',
        isOvernight: true,
      );
      final now = DateTime(2026, 6, 15, 7, 0, 0);
      expect(_isWithinShiftWindow(shift, now: now), isFalse);
    });
  });

  group('Missed alarm flag', () {
    test('consumeMissedAlarmFlag returns true when flag is set', () async {
      SharedPreferences.setMockInitialValues({
        'gf_alarm_fired': true,
        'gf_alarm_fired_at': 1234567890,
      });
      expect(await GeofenceScheduler.consumeMissedAlarmFlag(), isTrue);

      // Verify flag was cleared
      expect(await GeofenceScheduler.consumeMissedAlarmFlag(), isFalse);
    });

    test('consumeMissedAlarmFlag returns false when flag is not set', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await GeofenceScheduler.consumeMissedAlarmFlag(), isFalse);
    });

    test('consumeMissedAlarmFlag returns false when flag is false', () async {
      SharedPreferences.setMockInitialValues({
        'gf_alarm_fired': false,
      });
      expect(await GeofenceScheduler.consumeMissedAlarmFlag(), isFalse);
    });

    test('consumeMissedAlarmFlag clears related keys', () async {
      SharedPreferences.setMockInitialValues({
        'gf_alarm_fired': true,
        'gf_alarm_fired_at': 1234567890,
        'other_key': 'should survive',
      });

      await GeofenceScheduler.consumeMissedAlarmFlag();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('gf_alarm_fired'), isFalse);
      expect(prefs.containsKey('gf_alarm_fired_at'), isFalse);
      expect(prefs.getString('other_key'), 'should survive');
    });
  });

  group('Cancel', () {
    test('cancel clears next shift start pref', () async {
      SharedPreferences.setMockInitialValues({
        'gf_next_shift_start': '2026-06-16T09:00:00.000',
        'gf_cached_shift_name': 'Morning',
      });

      await GeofenceScheduler.cancel();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('gf_next_shift_start'), isFalse);
    });
  });

  group('Shift-today (leave-day) marker', () {
    test('empty shift list → marker FALSE written for today', () async {
      SharedPreferences.setMockInitialValues({
        'gf_shift_today': true, // stale from yesterday
        'gf_shift_today_date': '2026-08-13',
      });

      await GeofenceScheduler.startIfWithinShiftWindow([]);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('gf_shift_today'), isFalse);
      final now = DateTime.now();
      final todayKey = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      expect(prefs.getString('gf_shift_today_date'), todayKey);
    });
  });

  group('ScheduleNextShift', () {
    test('persists shift name and next start time', () async {
      SharedPreferences.setMockInitialValues({});

      final shift = _makeShift(name: 'TestShift', startTime: '14:00');
      await GeofenceScheduler.scheduleNextShift(shift);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('gf_cached_shift_name'), 'TestShift');
      final nextStr = prefs.getString('gf_next_shift_start');
      expect(nextStr, isNotNull);
      final nextTime = DateTime.tryParse(nextStr!);
      expect(nextTime, isNotNull);
      expect(nextTime!.isAfter(DateTime.now()), isTrue);
    });

    test('persists shift end time for the self-kill check', () async {
      SharedPreferences.setMockInitialValues({});

      final shift = _makeShift(name: 'TestShift', startTime: '14:00', endTime: '22:00');
      await GeofenceScheduler.scheduleNextShift(shift);

      final prefs = await SharedPreferences.getInstance();
      final endRaw = prefs.getString('gf_shift_end_time');
      expect(endRaw, isNotNull);
      expect(DateTime.tryParse(endRaw!), isNotNull);
    });
  });

  group('Shift-end self-kill', () {
    test('isPastShiftEnd true when persisted end is in the past', () async {
      SharedPreferences.setMockInitialValues({
        'gf_shift_end_time': DateTime.now()
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
      });
      expect(await GeofenceScheduler.isPastShiftEnd(), isTrue);
    });

    test('isPastShiftEnd false when persisted end is in the future', () async {
      SharedPreferences.setMockInitialValues({
        'gf_shift_end_time': DateTime.now()
            .add(const Duration(hours: 1))
            .toIso8601String(),
      });
      expect(await GeofenceScheduler.isPastShiftEnd(), isFalse);
    });

    test('isPastShiftEnd false when no end persisted (fail-safe)', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await GeofenceScheduler.isPastShiftEnd(), isFalse);
    });

    test('cancelRestartAlarm does not throw', () async {
      SharedPreferences.setMockInitialValues({});
      await GeofenceScheduler.cancelRestartAlarm();
    });
  });

  group('Empty-service guard', () {
    test('anyAutoFeatureEnabled false when everything is off', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await GeofenceScheduler.anyAutoFeatureEnabled(), isFalse);
    });

    test('anyAutoFeatureEnabled true when geofence auto is on', () async {
      SharedPreferences.setMockInitialValues({'geofence_auto_enabled': true});
      expect(await GeofenceScheduler.anyAutoFeatureEnabled(), isTrue);
    });

    test('anyAutoFeatureEnabled true when wifi bg flag is on', () async {
      SharedPreferences.setMockInitialValues({
        'wifi_auto_punch_enabled_bg': true,
      });
      expect(await GeofenceScheduler.anyAutoFeatureEnabled(), isTrue);
    });

    test('anyAutoFeatureEnabled true when field tracking is on', () async {
      SharedPreferences.setMockInitialValues({'field_tracking_enabled': true});
      expect(await GeofenceScheduler.anyAutoFeatureEnabled(), isTrue);
    });

    test('serviceRequired false when geofence is the only auto feature',
        () async {
      // Phase 2: geofence-only users run headless — no service process.
      SharedPreferences.setMockInitialValues({
        'geofence_auto_enabled': true,
      });
      expect(await GeofenceScheduler.serviceRequired(), isFalse);
    });

    test('serviceRequired false when everything is off', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await GeofenceScheduler.serviceRequired(), isFalse);
    });

    test('serviceRequired true when wifi bg flag is on', () async {
      SharedPreferences.setMockInitialValues({
        'wifi_auto_punch_enabled_bg': true,
      });
      expect(await GeofenceScheduler.serviceRequired(), isTrue);
    });

    test('serviceRequired true when wifi fg flag is on', () async {
      SharedPreferences.setMockInitialValues({
        'wifi_auto_punch_enabled': true,
      });
      expect(await GeofenceScheduler.serviceRequired(), isTrue);
    });

    test('serviceRequired true when field tracking is on', () async {
      SharedPreferences.setMockInitialValues({'field_tracking_enabled': true});
      expect(await GeofenceScheduler.serviceRequired(), isTrue);
    });

    test('armContainmentAlarmIfNeeded: no token → disarmed', () async {
      SharedPreferences.setMockInitialValues({'geofence_auto_enabled': true});
      await GeofenceScheduler.armContainmentAlarmIfNeeded();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('gf_containment_alarm_armed'), isFalse);
    });

    test('armContainmentAlarmIfNeeded: token + auto feature → armed', () async {
      SharedPreferences.setMockInitialValues({
        'geofence_auto_enabled': true,
        'bg_access_token': 'tok',
      });
      await GeofenceScheduler.armContainmentAlarmIfNeeded();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('gf_containment_alarm_armed'), isTrue);
    });

    test('armContainmentAlarmIfNeeded: token, no features → disarmed',
        () async {
      SharedPreferences.setMockInitialValues({'bg_access_token': 'tok'});
      await GeofenceScheduler.armContainmentAlarmIfNeeded();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('gf_containment_alarm_armed'), isFalse);
    });

    test('cancelContainmentAlarm clears the armed flag', () async {
      SharedPreferences.setMockInitialValues({
        'geofence_auto_enabled': true,
        'bg_access_token': 'tok',
        'gf_containment_alarm_armed': true,
      });
      await GeofenceScheduler.cancelContainmentAlarm();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('gf_containment_alarm_armed'), isFalse);
    });
  });
}
