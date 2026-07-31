import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/offline/offline_providers.dart';
import '../../../core/offline/offline_sync_manager.dart';
import '../../../core/utils/constants.dart';
import '../../punch/services/manual_geo_service.dart';
import '../../punch/services/location_service.dart';
import '../../../models/attendance.dart';
import '../../../models/offline_punch.dart';

/// Injected so we don't create a new instance per punch (on iOS cellular
/// a fresh [NetworkInfo] can freeze or throw trying to read WiFi IP).
final networkInfoProvider = Provider<NetworkInfo>((_) => NetworkInfo());

/// Set to `true` when the user manually punches "Out" from the UI.
/// Consumed by [MainShell] to distinguish manual punch-out (→ stop geofence)
/// from auto punch-out (→ keep geofence running for re-entry).
final manualPunchOutProvider = StateProvider<bool>((ref) => false);

final manualPunchInProvider = StateProvider<bool>((ref) => false);

// ── Attendance Status ─────────────────────────────────────────────────────────

final attendanceStatusProvider = AsyncNotifierProvider<AttendanceStatusNotifier, EmployeeStatus?>(
  () => AttendanceStatusNotifier(),
);

class AttendanceStatusNotifier extends AsyncNotifier<EmployeeStatus?> {
  EmployeeStatus? _lastKnownValue;

  @override
  Future<EmployeeStatus?> build() async {
    ref.watch(authNotifierProvider);
    // Cache-first: if today's cached status exists, render it instantly and
    // refresh in the background — no skeleton flash, no waiting on the
    // network before the home screen shows real data.
    final cached = _loadFromCache();
    if (cached != null) {
      _lastKnownValue = cached;
      _refreshInBackground();
      return cached;
    }
    final result = await _fetch();
    if (result != null) return result;
    return _loadFromCache();
  }

  /// Fetch fresh data in the background and swap it into the UI when it
  /// arrives.  Never clobbers a loading/error state with stale data.
  Future<void> _refreshInBackground() async {
    try {
      final fresh = await _fetch();
      if (fresh != null && state is AsyncData) {
        state = AsyncData<EmployeeStatus?>(fresh);
      }
    } catch (_) {}
  }

  Future<EmployeeStatus?> _fetch() async {
    try {
      final dio = ref.read(dioClientProvider).dio;
      final response = await dio.get(ApiEndpoints.todayStatus);
      print('[DEBUG_SHIFT] Raw /attendance/status JSON (dashboard): ${response.data}');
      final data = response.data['data'] as Map<String, dynamic>?;
      _lastKnownValue = data != null ? EmployeeStatus.fromJson(data) : null;
      if (data != null) _saveToCache(data);
      return _lastKnownValue;
    } catch (_) {
      try {
        await Future.delayed(const Duration(milliseconds: 800));
        final dio = ref.read(dioClientProvider).dio;
        final response = await dio.get(ApiEndpoints.todayStatus);
        final data = response.data['data'] as Map<String, dynamic>?;
        _lastKnownValue = data != null ? EmployeeStatus.fromJson(data) : null;
        if (data != null) _saveToCache(data);
        return _lastKnownValue;
      } catch (_) {
        return _lastKnownValue;
      }
    }
  }

  /// Persist raw API response to Hive so it survives app restart.
  void _saveToCache(Map<String, dynamic> data) {
    try {
      final box = Hive.box(AppConstants.cacheBox);
      box.put('cached_status', jsonEncode(data));
    } catch (_) {}
  }

  /// Restore cached status from Hive for fresh-offline launches.
  EmployeeStatus? _loadFromCache() {
    try {
      final box = Hive.box(AppConstants.cacheBox);
      final raw = box.get('cached_status') as String?;
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final status = EmployeeStatus.fromJson(data);
      // Discard cached data if it's from a different day
      if (status.date != _todayString()) return null;
      _lastKnownValue = status;
      return status;
    } catch (_) {
      return null;
    }
  }

  String _todayString() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
  }

  Future<void> refresh() async {
    final previous = state.value;
    final cached = _loadFromCache() ?? previous;
    if (cached != null) {
      // Keep showing current data — swap when fresh arrives (no flash).
      state = AsyncData<EmployeeStatus?>(cached);
      await _refreshInBackground();
    } else {
      state = const AsyncLoading();
      state = await AsyncValue.guard(() => _fetch().then((v) => v ?? previous));
    }
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
        ip = await ref.read(networkInfoProvider).getWifiIP() ?? '0.0.0.0';
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
      } else if (body['Direction'] == 'In') {
        ref.read(manualPunchInProvider.notifier).state = true;
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

    // ── GPS-only policy ─────────────────────────────────────────────────
    // Offline punches are GPS punches: the backend timeline alternates and
    // a location is required.  Other methods are NOT queued offline — the
    // user gets a clear failure instead of a silently-failed queued punch.
    if (method != 'GPS') {
      state = const AsyncData(null);
      return PunchResult(
        success: false,
        message: 'Offline punches only supported with GPS — select GPS or go online',
      );
    }

    // ── Location is mandatory ───────────────────────────────────────────
    // The caller may pass coords (GPSPunchScreen) or not (punch flow when
    // the location provider hadn't resolved).  Never queue a GPS punch
    // without coordinates — sync validation would permanently fail it.
    double? lat = (extras?['latitude'] as num?)?.toDouble();
    double? lng = (extras?['longitude'] as num?)?.toDouble();
    if (lat == null || lng == null) {
      final loc = await _captureLocation();
      if (loc == null) {
        state = const AsyncData(null);
        return PunchResult(
          success: false,
          message: 'Could not get GPS location — enable GPS and try again',
        );
      }
      lat = loc.latitude;
      lng = loc.longitude;
    }

    // ── Alternation guard ───────────────────────────────────────────────
    // If the most recent queued (non-failed) punch is the same direction,
    // don't enqueue a duplicate — the server alternates In/Out.
    final direction = extras?['direction'] as String? ?? 'In';
    if (queue.lastPendingDirection == direction) {
      state = const AsyncData(null);
      return PunchResult(
        success: false,
        message: 'A $direction punch is already queued — waiting to sync',
      );
    }

    final punch = OfflinePunch()
      ..method = 'GPS'
      ..direction = direction
      ..latitude = lat
      ..longitude = lng;

    await queue.enqueue(punch);

    // Notify UI — update the reactive pending count
    ref.read(pendingOfflineCountProvider.notifier).state = queue.pendingCount;

    // Ask the background manager to sync as soon as connectivity returns.
    OfflineSyncManager.scheduleNow();

    state = const AsyncData(null);

    final count = queue.pendingCount;
    final msg = reason == 'offline'
        ? "You're offline — punch saved locally ($count pending)"
        : 'Network error — punch saved locally ($count pending)';

    return PunchResult(success: true, message: msg);
  }

  /// Tries to obtain a fresh GPS fix (3 attempts).  Returns null on failure.
  Future<LocationResult?> _captureLocation() async {
    for (int i = 0; i < 3; i++) {
      try {
        return await LocationService().getCurrentPosition();
      } catch (_) {
        if (i < 2) await Future.delayed(const Duration(seconds: 1));
      }
    }
    return null;
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
    if (data != null) {
      final perms = AccessPermissions.fromJson(data);
      // Mirror the geofence permission to SharedPreferences so the background
      // worker (_isEnabled) can enforce it — the bg isolate has no access to
      // this Riverpod provider.  Written ONLY on success: a transient fetch
      // failure must never revoke a previously-permitted user (the flag is
      // absent → treated as "unknown/legacy", which does not block).
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('bg_allow_geofence_auto', perms.allowGeofenceAuto);
      return perms;
    }
  } catch (_) {
    // Fall through to minimal defaults on any error
  }
  // Fail-safe: only GPS + Selfie when API is unreachable
  return AccessPermissions.defaultMinimal;
});
