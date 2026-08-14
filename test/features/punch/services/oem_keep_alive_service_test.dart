import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mattendance_mobile/features/punch/services/oem_keep_alive_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OemKeepAliveService.withinShiftWindow', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('null shift prefs → false (nothing cached, e.g. first launch)', () {
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 10, 0)), isFalse);
    });

    test('missing end → false (fingerprint) — fail-safe', () {
      prefs.setString('gf_cached_shift_start_time', '08:00');
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 10, 0)), isFalse);
    });

    test('inside window → true (10:00 in 08:00–18:00)', () {
      prefs.setString('gf_cached_shift_start_time', '08:00');
      prefs.setString('gf_shift_end_time', DateTime(2026, 8, 14, 18, 0).toIso8601String());
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 10, 0)), isTrue);
    });

    test('before start → false (07:59)', () {
      prefs.setString('gf_cached_shift_start_time', '08:00');
      prefs.setString('gf_shift_end_time', DateTime(2026, 8, 14, 18, 0).toIso8601String());
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 7, 59)), isFalse);
    });

    test('after end → false (18:01) — FGS/chain rest outside window', () {
      prefs.setString('gf_cached_shift_start_time', '08:00');
      prefs.setString('gf_shift_end_time', DateTime(2026, 8, 14, 18, 0).toIso8601String());
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 18, 1)), isFalse);
    });

    test('exact boundaries inclusive (08:00 and 18:00)', () {
      prefs.setString('gf_cached_shift_start_time', '08:00');
      prefs.setString('gf_shift_end_time', DateTime(2026, 8, 14, 18, 0).toIso8601String());
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 8, 0)), isTrue);
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 18, 0)), isTrue);
    });

    test('overnight shift 22:00–02:00: 23:30 inside, post-midnight outside today\'s window', () {
      // End stored for the day the shift STARTED (14th 02:00 next day).
      prefs.setString('gf_cached_shift_start_time', '22:00');
      prefs.setString('gf_shift_end_time', DateTime(2026, 8, 14, 2, 0).toIso8601String());
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 23, 30)), isTrue);
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 15, 3, 0)), isFalse);
      // 01:00 next morning belongs to YESTERDAY's window instance — today's
      // window starts 22:00 tonight.  Matches native semantics: punched-IN
      // state covers the user; OS geofence ENTER is the primary re-entry path.
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 15, 1, 0)), isFalse);
    });

    test('trailing-Z end is treated as local time, not UTC', () {
      prefs.setString('gf_cached_shift_start_time', '08:00');
      prefs.setString('gf_shift_end_time', '2026-08-14T18:00:00.000Z');
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 10, 0)), isTrue);
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 19, 0)), isFalse);
    });

    test('leave day (next shift cached, no end today) → false', () {
      prefs.setString('gf_cached_shift_start_time', '2026-08-17T08:00:00.000'); // next workday
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 10, 0)), isFalse);
    });

    test('leave day (explicit marker FALSE today) → false even with stale window prefs', () {
      // Stale shift times from last workday + app learned today = leave day.
      prefs.setString('gf_cached_shift_start_time', '08:00');
      prefs.setString('gf_shift_end_time', DateTime(2026, 8, 13, 18, 0).toIso8601String());
      prefs.setBool('gf_shift_today', false);
      prefs.setString('gf_shift_today_date', '2026-08-14');
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 10, 0)), isFalse);
    });

    test('stale marker (app not opened today) → workday assumption true', () {
      prefs.setString('gf_cached_shift_start_time', '08:00');
      prefs.setString('gf_shift_end_time', DateTime(2026, 8, 13, 18, 0).toIso8601String());
      prefs.setBool('gf_shift_today', false); // learned leave on Aug 13
      prefs.setString('gf_shift_today_date', '2026-08-13');
      // Today Aug 14: marker stale → assume workday → stale window applies
      // (morning-IN headless self-heal must not regress).
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 10, 0)), isTrue);
    });

    test('marker never written (fresh install) → window logic applies', () {
      prefs.setString('gf_cached_shift_start_time', '08:00');
      prefs.setString('gf_shift_end_time', DateTime(2026, 8, 14, 18, 0).toIso8601String());
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 10, 0)), isTrue);
    });

    test('workday with fresh TRUE marker → normal window logic', () {
      prefs.setString('gf_cached_shift_start_time', '08:00');
      prefs.setString('gf_shift_end_time', DateTime(2026, 8, 14, 18, 0).toIso8601String());
      prefs.setBool('gf_shift_today', true);
      prefs.setString('gf_shift_today_date', '2026-08-14');
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 10, 0)), isTrue);
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 19, 0)), isFalse);
    });

    test('leave-day marker does not suppress overnight-shift window on NEXT workday', () {
      // Leave Aug 14 learned; overnight shift 22:00–02:00 window prefs.
      prefs.setString('gf_cached_shift_start_time', '22:00');
      prefs.setString('gf_shift_end_time', DateTime(2026, 8, 15, 2, 0).toIso8601String());
      prefs.setBool('gf_shift_today', false);
      prefs.setString('gf_shift_today_date', '2026-08-14');
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 15, 23, 30)), isTrue);
    });

    test('malformed start → false', () {
      prefs.setString('gf_cached_shift_start_time', 'garbage');
      prefs.setString('gf_shift_end_time', DateTime(2026, 8, 14, 18, 0).toIso8601String());
      expect(OemKeepAliveService.withinShiftWindow(prefs, DateTime(2026, 8, 14, 10, 0)), isFalse);
    });
  });
}