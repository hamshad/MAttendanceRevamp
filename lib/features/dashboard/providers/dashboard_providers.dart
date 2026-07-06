import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:network_info_plus/network_info_plus.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/offline/offline_providers.dart';
import '../../punch/services/manual_geo_service.dart';
import '../../../models/attendance.dart';
import '../../../models/offline_punch.dart';

/// Set to `true` when the user manually punches "Out" from the UI.
/// Consumed by [MainShell] to distinguish manual punch-out (→ stop geofence)
/// from auto punch-out (→ keep geofence running for re-entry).
final manualPunchOutProvider = StateProvider<bool>((ref) => false);

// ── Attendance Status ─────────────────────────────────────────────────────────

final attendanceStatusProvider = AsyncNotifierProvider<AttendanceStatusNotifier, EmployeeStatus?>(
  () => AttendanceStatusNotifier(),
);

class AttendanceStatusNotifier extends AsyncNotifier<EmployeeStatus?> {
  @override
  Future<EmployeeStatus?> build() => _fetch();

  Future<EmployeeStatus?> _fetch() async {
    try {
      final dio = ref.read(dioClientProvider).dio;
      final response = await dio.get(ApiEndpoints.todayStatus);
      print('[DEBUG_SHIFT] Raw /attendance/status JSON (dashboard): ${response.data}');
      final data = response.data['data'] as Map<String, dynamic>?;
      return data != null ? EmployeeStatus.fromJson(data) : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }
}

// ── Punch ─────────────────────────────────────────────────────────────────────

final selectedMethodProvider = StateProvider<String>((ref) => 'GPS');

final manualGeoServiceProvider = Provider<ManualGeoService>((ref) {
  return ManualGeoService(dio: ref.read(dioClientProvider).dio);
});

final punchProvider = AsyncNotifierProvider<PunchNotifier, void>(
  () => PunchNotifier(),
);

class PunchNotifier extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  Future<PunchResult> punch(String method, {Map<String, dynamic>? extras}) async {
    state = const AsyncLoading();

    // Check connectivity before attempting the API call
    final isOnline = await ref.read(connectivityMonitorProvider).isOnline;

    if (!isOnline) {
      return _queueOffline(method, extras, reason: 'offline');
    }

    try {
      final dio = ref.read(dioClientProvider).dio;
      
      // Get IP Address (Mandatory for backend)
      String ip = '0.0.0.0';
      try {
        ip = await NetworkInfo().getWifiIP() ?? '0.0.0.0';
      } catch (_) {}

      // Capitalize keys to match backend expectations (PascalCase)
      final body = <String, dynamic>{
        'Method': method,
        'Direction': extras?['direction'] ?? 'In',
        'IPAddress': ip,
      };

      // Merge extras while ensuring location fields are correctly named and formatted
      if (extras != null) {
        for (final entry in extras.entries) {
          final key = entry.key.toLowerCase();
          final value = entry.value;

          if (key == 'latitude') {
            body['Latitude'] = value.toString();
          } else if (key == 'longitude') {
            body['Longitude'] = value.toString();
          } else if (key == 'address') {
            body['Address'] = value.toString();
          } else if (key == 'direction') {
            body['Direction'] = value.toString();
          } else {
            // Keep other extras as-is (e.g. selfieBase64, qrCodeToken)
            body[entry.key] = value;
          }
        }
      }

      final response = await dio.post(ApiEndpoints.punch, data: body);
      final wrapper = response.data as Map<String, dynamic>;
      // ApiResponse<PunchResponse> — unwrap data field
      final data = wrapper['data'] as Map<String, dynamic>?;
      final result = PunchResult.fromJson(data ?? wrapper);

      if (body['Direction'] == 'Out') {
        ref.read(manualPunchOutProvider.notifier).state = true;
      }

      state = const AsyncData(null);
      ref.invalidate(attendanceStatusProvider);
      return result;
    } on DioException catch (e) {
      state = AsyncError(e, StackTrace.current);

      // Network-level failure (no response received) → queue offline for retry
      if (e.type != DioExceptionType.badResponse) {
        return _queueOffline(method, extras, reason: 'network');
      }

      // Server returned 4xx/5xx → definitive rejection, do not queue
      final msg = (e.response?.data as Map?)?['message'] as String? ?? 'Punch failed';
      return PunchResult(success: false, message: msg);
    }
  }

  Future<PunchResult> _queueOffline(
    String method,
    Map<String, dynamic>? extras, {
    required String reason,
  }) async {
    final queue = ref.read(offlineQueueServiceProvider);

    final punch = OfflinePunch()
      ..method = method
      ..direction = extras?['direction'] as String?
      ..latitude = (extras?['latitude'] as num?)?.toDouble()
      ..longitude = (extras?['longitude'] as num?)?.toDouble()
      ..selfieBase64 = extras?['selfieBase64'] as String?
      ..qrToken = extras?['qrCodeToken'] as String?
      ..wifiMAC = extras?['wifiMAC'] as String?
      ..wifiSSID = extras?['wifiSSID'] as String?
      ..deviceId = extras?['deviceId'] as String?
      ..beaconUUID = extras?['beaconUUID'] as String?
      ..beaconMajor = extras?['beaconMajor'] as int?
      ..beaconMinor = extras?['beaconMinor'] as int?
      ..nfcTagId = extras?['nfcTagId'] as String?
      ..faceEmbedding = extras?['faceEmbedding'] as String?;

    await queue.enqueue(punch);

    // Notify UI — update the reactive pending count
    ref.read(pendingOfflineCountProvider.notifier).state = queue.pendingCount;

    state = const AsyncData(null);

    final count = queue.pendingCount;
    final msg = reason == 'offline'
        ? "You're offline — punch saved locally ($count pending)"
        : 'Network error — punch saved locally ($count pending)';

    return PunchResult(success: true, message: msg);
  }
}

// ── Monthly Stats ─────────────────────────────────────────────────────────────

class MonthlyStats {
  final int present;
  final int absent;
  final int late;
  final int leave;
  const MonthlyStats({
    required this.present,
    required this.absent,
    required this.late,
    required this.leave,
  });
  static const zero = MonthlyStats(present: 0, absent: 0, late: 0, leave: 0);
}

final monthlyStatsProvider = FutureProvider<MonthlyStats>((ref) async {
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return MonthlyStats.zero;

  try {
    final now = DateTime.now();
    final from =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
    final lastDay = DateTime(now.year, now.month + 1, 0).day;
    final to =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${lastDay.toString().padLeft(2, '0')}';

    final dio = ref.read(dioClientProvider).dio;
    final response = await dio.get(
      ApiEndpoints.attendanceHistory,
      queryParameters: {'from': from, 'to': to, 'page': 1, 'pageSize': 31},
    );

    final data = response.data['data'] as Map<String, dynamic>;
    final items = (data['items'] as List)
        .map((e) => AttendanceDay.fromJson(e as Map<String, dynamic>))
        .toList();

    int present = 0, absent = 0, late = 0, leave = 0;
    for (final day in items) {
      final s = day.status;
      if (s == 'Present' || s == 'OnDuty' || s == 'WFH') {
        present++;
      } else if (s == 'Absent') {
        absent++;
      } else if (s == 'Late') {
        late++;
      } else if (s == 'Leave' || s == 'HalfDay' || s == 'CompOff') {
        leave++;
      }
    }

    return MonthlyStats(
      present: present,
      absent: absent,
      late: late,
      leave: leave,
    );
  } catch (_) {
    return MonthlyStats.zero;
  }
});

// ── Access Permissions ────────────────────────────────────────────────────────

final accessPermissionsProvider = FutureProvider<AccessPermissions>((ref) async {
  // Watch auth state so this provider re-fetches whenever the logged-in user changes.
  final user = ref.watch(authNotifierProvider).value;
  if (user == null) return AccessPermissions.defaultMinimal;

  try {
    final dio = ref.read(dioClientProvider).dio;
    final response = await dio.get(ApiEndpoints.accessPermissions);
    final data = response.data['data'] as Map<String, dynamic>?;
    if (data != null) return AccessPermissions.fromJson(data);
  } catch (_) {
    // Fall through to minimal defaults on any error
  }
  // Fail-safe: only GPS + Selfie when API is unreachable
  return AccessPermissions.defaultMinimal;
});
