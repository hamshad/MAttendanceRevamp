import 'package:dio/dio.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/utils/app_logger.dart';
import '../../../models/attendance.dart';

/// Server-derived punch state for "today".
///
/// This is the single source of truth for whether an employee is currently
/// punched IN/OUT, including punches recorded by OTHER methods (Web, GPS,
/// Biometric, etc.) on other devices — which local Hive/SharedPreferences
/// state in the WiFi auto-punch services does NOT see.
class ServerPunchState {
  final bool isPunchedIn;
  final bool isPunchedOut;

  /// The most recent punch record for today, or null if none.
  final PunchSummary? lastPunch;

  const ServerPunchState({
    required this.isPunchedIn,
    required this.isPunchedOut,
    this.lastPunch,
  });

  /// Method of the latest punch, if any (e.g. 'WiFi', 'GPS', 'Web', 'Biometric').
  String? get lastMethod => lastPunch?.method;
}

/// Mediator that asks the backend which punch was last recorded before the
/// WiFi auto-punch decides to fire an IN/OUT. Prevents duplicate punches when
/// the employee already checked in/out via Web / GPS / Biometric.
class PunchStateService {
  final Dio dio;

  PunchStateService(this.dio);

  static const _timeout = Duration(seconds: 15);

  /// Returns the employee's current server punch state, or `null` on any
  /// error so callers can safely fall back to local state without blocking
  /// the auto-punch flow.
  Future<ServerPunchState?> fetch() async {
    try {
      final resp = await dio.get(
        ApiEndpoints.todayStatus,
        options: Options(
          sendTimeout: _timeout,
          receiveTimeout: _timeout,
        ),
      );

      final body = resp.data;
      final data = body is Map ? body['data'] as Map<String, dynamic>? : null;
      if (data == null) return null;

      final status = EmployeeStatus.fromJson(data);
      final last = status.todaysPunches.isEmpty
          ? null
          : status.todaysPunches.reduce(
              (a, b) => a.punchTime.isAfter(b.punchTime) ? a : b,
            );

      return ServerPunchState(
        isPunchedIn: status.isPunchedIn,
        isPunchedOut: status.isPunchedOut,
        lastPunch: last,
      );
    } on DioException catch (e) {
      // Network/timeout/unauthorized — fall back to local state.
      AppLogger.w('PunchStateService: fetch failed, falling back to local state', e);
      return null;
    } catch (e) {
      AppLogger.w('PunchStateService: unexpected error, falling back to local state', e);
      return null;
    }
  }
}
