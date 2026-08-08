import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/attendance.dart';
import '../api/api_endpoints.dart';

/// Outcome of a server-truth punch check.
enum PunchCheck { valid, duplicate, blocked, undecided }

/// Server-truth gate for every punch path.
///
/// The app's local `gf_last_punch_type` can't see punches made through the
/// biometric machine or the website — a second IN would toggle the server to
/// OUT. So every punch path (manual, geofence, WiFi, offline queue) asks the
/// server who was last and decides whether the punch is still needed.
///
/// Reads `todayStatus` → `todaysPunches` (the day's punch timeline) and caches
/// the verdict in SharedPreferences for [_cacheTtl]. Background isolates share
/// no memory, so prefs is the only cross-isolate cache — a punch attempt from
/// the geofence isolate sees the status the WiFi worker fetched 5s ago.
class PunchCoordinator {
  PunchCoordinator._();

  static const Duration _cacheTtl = Duration(seconds: 20);
  static const String _cacheTypeKey = 'bg_server_last_type';
  static const String _cacheOnBreakKey = 'bg_server_on_break';
  static const String _cacheTsKey = 'bg_server_status_ts';

  /// Ask the server for the last punch type and decide whether [direction]
  /// is still needed. Never throws — returns [PunchCheck.undecided] when the
  /// server is unreachable and the caller must apply its own offline policy.
  static Future<PunchCheck> check({
    required Dio dio,
    required String direction,
  }) async {
    final prefs = await SharedPreferences.getInstance();

    // Fresh cache → decide without a network call.
    final ts = prefs.getInt(_cacheTsKey);
    if (ts != null &&
        DateTime.now().millisecondsSinceEpoch - ts < _cacheTtl.inMilliseconds) {
      return _decide(
        prefs.getString(_cacheTypeKey),
        isOnBreak: prefs.getBool(_cacheOnBreakKey) ?? false,
        direction: direction,
      );
    }

    try {
      final resp = await dio.get(ApiEndpoints.todayStatus);
      final data = resp.data['data'] as Map<String, dynamic>?;
      final status = data != null ? EmployeeStatus.fromJson(data) : null;
      if (status == null) return PunchCheck.undecided;

      final last = lastPunchType(status);
      await Future.wait([
        prefs.setString(_cacheTypeKey, last ?? ''),
        prefs.setBool(_cacheOnBreakKey, status.isOnBreak),
        prefs.setInt(_cacheTsKey, DateTime.now().millisecondsSinceEpoch),
      ]);
      return _decide(last, isOnBreak: status.isOnBreak, direction: direction);
    } catch (_) {
      return PunchCheck.undecided;
    }
  }

  /// Last punch type from the day's timeline; falls back to the status
  /// booleans (firstIn/lastOut) when the timeline is empty.
  static String? lastPunchType(EmployeeStatus status) {
    if (status.todaysPunches.isNotEmpty) {
      return status.todaysPunches.last.punchType;
    }
    if (status.isOnBreak) return 'BreakStart';
    if (status.firstInTime != null && status.lastOutTime == null) return 'In';
    if (status.lastOutTime != null) return 'Out';
    return null;
  }

  static PunchCheck _decide(
    String? last, {
    required bool isOnBreak,
    required String direction,
  }) {
    // No punches today: IN is the first punch; OUT is nonsense (would be
    // rejected — mirrors the server's hasNotPunchedIn semantics).
    if (last == null || last.isEmpty) {
      return direction == 'Out' ? PunchCheck.blocked : PunchCheck.valid;
    }
    // Same direction twice → the server would treat the second IN as an OUT
    // toggle. Almost always a punch we can't see (biometric / website).
    if (last == direction) return PunchCheck.duplicate;
    // Punching IN mid-break is invalid — user must /breaks/end first.
    if (direction == 'In' && isOnBreak) return PunchCheck.blocked;
    return PunchCheck.valid;
  }
}
