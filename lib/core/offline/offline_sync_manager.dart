import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../../models/offline_punch.dart';
import '../api/api_endpoints.dart';
import '../punch/punch_coordinator.dart';
import '../utils/constants.dart';

/// Background manager for the offline punch queue.
///
/// A dedicated Workmanager task (with a network constraint) syncs queued
/// punches to the backend as soon as connectivity returns, then the task
/// completes and Workmanager closes itself.  Works even when the app is
/// killed.  Task routing happens in [GeofenceScheduler]'s dispatcher
/// (Workmanager allows only ONE registered callback per app).
class OfflineSyncManager {
  OfflineSyncManager._();

  static const String syncTaskName = 'offline_sync';
  static const String periodicTaskName = 'offline_sync_periodic';

  static const Duration _periodicFrequency = Duration(minutes: 15);

  /// Must be called after `Workmanager().initialize(...)` — registers the
  /// periodic safety-net sync (every 15 min while connected).  `keep`
  /// policy so enqueue-triggered one-offs are never replaced by this.
  static Future<void> start() async {
    await Workmanager().registerPeriodicTask(
      periodicTaskName,
      periodicTaskName,
      frequency: _periodicFrequency,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  /// One-off sync requested right after a punch is queued.  Workmanager
  /// holds the task until a network is available, then executes it.  The
  /// task completes and the manager closes itself.
  static Future<void> scheduleNow() async {
    await Workmanager().registerOneOffTask(
      syncTaskName,
      syncTaskName,
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingWorkPolicy.keep,
    );
  }

  /// Cancels all offline sync tasks (on logout — no queue, no sync).
  static Future<void> cancel() async {
    await Workmanager().cancelByUniqueName(syncTaskName);
    await Workmanager().cancelByUniqueName(periodicTaskName);
  }

  /// True when [taskName] belongs to the offline sync manager.
  static bool handles(String taskName) =>
      taskName == syncTaskName || taskName == periodicTaskName;

  /// Executed inside the Workmanager isolate.  Returns true when finished —
  /// Workmanager then closes the isolate.  [testDio] replaces the
  /// self-built dio in unit tests.
  static Future<bool> executeSyncTask({Dio? testDio}) async {
    try {
      // Auth guard: no token → nothing to sync.
      final prefs = await SharedPreferences.getInstance();
      var token = prefs.getString('bg_access_token');
      if (token == null || token.isEmpty) return true;

      // Initialize Hive in this isolate and open the queue box.
      await Hive.initFlutter();
      if (!Hive.isAdapterRegistered(0)) {
        Hive.registerAdapter(OfflinePunchAdapter());
      }
      final box = await Hive.openBox<OfflinePunch>(AppConstants.offlinePunchBox);
      await Hive.openBox(AppConstants.cacheBox);
      await Hive.openBox(AppConstants.tokenBackupBox);

      final pending = box.values
          .where((p) => p.retryCount < AppConstants.maxRetryCount)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (pending.isEmpty) return true;

      var dio = testDio ?? _buildDio(token);

      for (final punch in pending) {
        // ── Server-truth gate + freshness (PunchCoordinator) ─────────────
        // Queued punches can be stale or already-covered by a punch we can't
        // see (biometric machine / website).  Re-check before POSTing.
        if (await _shouldDropPunch(punch, dio, box)) continue;

        try {
          final resp = await dio.post(ApiEndpoints.punch, data: _buildBody(punch));
          if (resp.statusCode == 200 || resp.statusCode == 201) {
            await box.delete(punch.key);
            await _publishLocalState(punch);
            continue;
          }
          // Unexpected success status (e.g. 202 accepted) → treat as done.
          if (resp.statusCode != null && resp.statusCode! < 300) {
            await box.delete(punch.key);
            await _publishLocalState(punch);
            continue;
          }
          // 4xx/5xx definitive → stop retrying this punch.
          punch.retryCount = 99;
          punch.errorMessage = 'Rejected by server (${resp.statusCode})';
          await punch.save();
        } on DioException catch (e) {
          final handled = await _handleDioError(e, punch, dio, prefs);
          if (!handled) {
            // Transient (network/timeout) → bump retry, keep for next run.
            punch.retryCount++;
            punch.errorMessage = 'Network error — will retry';
            await punch.save();
            // Stop the batch; next periodic run continues.
            return true;
          }
        } catch (e) {
          punch.retryCount++;
          punch.errorMessage = e.toString();
          await punch.save();
        }
      }
      return true;
    } catch (_) {
      // Never rethrow into Workmanager — a swallowed error just ends the
      // task; the periodic task re-runs it later.
      return true;
    }
  }

  static Dio _buildDio(String token) => Dio(BaseOptions(
        baseUrl: AppConstants.apiBaseUrl,
        connectTimeout: AppConstants.connectTimeout,
        receiveTimeout: AppConstants.receiveTimeout,
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      ));

  /// Returns true when the queued punch should be dropped (stale or already
  /// covered by a punch the app can't see), false when it may be POSTed.
  ///
  /// Auto punches (geofence/WiFi) also expire after [AppConstants
  /// .autoPunchQueueTtl] — an enter event + long outage is stale.  Manual
  /// punches are user intent and never expire, but still pass the
  /// server-truth gate so a manual IN can't toggle a biometric IN to OUT.
  static Future<bool> _shouldDropPunch(
    OfflinePunch punch,
    Dio dio,
    Box<OfflinePunch> box,
  ) async {
    final direction = punch.direction ?? 'In';
    final isAuto = punch.method == 'GeofenceAuto' || punch.method == 'WiFi';

    if (isAuto &&
        DateTime.now().difference(punch.createdAt) >
            AppConstants.autoPunchQueueTtl) {
      await box.delete(punch.key);
      return true;
    }

    final verdict =
        await PunchCoordinator.check(dio: dio, direction: direction);
    if (verdict == PunchCheck.duplicate || verdict == PunchCheck.blocked) {
      // Server already has this state (biometric/website) → drop.
      await box.delete(punch.key);
      return true;
    }
    if (verdict == PunchCheck.undecided) {
      // Status unreachable → keep queued; the periodic task (network
      // constrained) retries it later.
      punch.retryCount++;
      punch.errorMessage = 'Server truth unreachable — will retry';
      await punch.save();
      return true;
    }
    return false;
  }

  /// Keep the local punch-state prefs coherent after a successful sync so the
  /// handler gates (`gf_last_punch_type == direction → skip`) never act on a
  /// stale value.  Mirrors PunchStateInterceptor for the foreground paths.
  static Future<void> _publishLocalState(OfflinePunch punch) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('gf_last_punch_type', punch.direction ?? 'In');
      await prefs.setString(
          'gf_last_punch_time', punch.createdAt.toIso8601String());
    } catch (_) {}
  }

  /// Handles 401 (token refresh + retry) and duplicates.  Returns true when
  /// the punch was resolved (deleted / marked failed), false on transient.
  static Future<bool> _handleDioError(
    DioException e,
    OfflinePunch punch,
    Dio dio,
    SharedPreferences prefs,
  ) async {
    if (e.response?.statusCode == 401) {
      // Try refreshing once using the background mirror keys.
      final refreshToken = prefs.getString('bg_refresh_token');
      if (refreshToken != null && refreshToken.isNotEmpty) {
        try {
          final refreshDio = Dio(BaseOptions(
            baseUrl: AppConstants.apiBaseUrl,
            connectTimeout: AppConstants.connectTimeout,
            receiveTimeout: AppConstants.receiveTimeout,
          ));
          final resp = await refreshDio.post(
            ApiEndpoints.refreshToken,
            data: {
              'accessToken': prefs.getString('bg_access_token') ?? '',
              'refreshToken': refreshToken,
            },
          );
          final newAccess = resp.data['accessToken'] as String;
          final newRefresh = resp.data['refreshToken'] as String;
          await Future.wait([
            prefs.setString('bg_access_token', newAccess),
            prefs.setString('bg_refresh_token', newRefresh),
            prefs.setInt('bg_token_ts', DateTime.now().millisecondsSinceEpoch),
          ]);
          dio = _buildDio(newAccess);
          final retry = await dio.post(ApiEndpoints.punch, data: _buildBody(punch));
          if (retry.statusCode == 200 || retry.statusCode == 201) {
            await punch.delete();
            return true;
          }
        } catch (_) {
          // Refresh failed → transient, retry next run.
          return false;
        }
      }
      return false;
    }

    if (e.response != null) {
      final body = e.response?.data;
      final msg = body is Map && body['message'] is String
          ? body['message'] as String
          : '';
      if (msg.contains('Duplicate') || msg.contains('already recorded')) {
        // Server already has this punch — drop it from the queue.
        await punch.delete();
        return true;
      }
      if (e.response!.statusCode != null && e.response!.statusCode! < 500) {
        // Definitive client rejection → stop retrying.
        punch.retryCount = 99;
        punch.errorMessage = msg.isNotEmpty ? msg : 'Rejected by server';
        await punch.save();
        return true;
      }
      return false; // 5xx → transient
    }
    return false; // no response → transient
  }

  /// Mirrors SyncService._buildBody — PascalCase keys the backend expects.
  static Map<String, dynamic> _buildBody(OfflinePunch punch) {
    final body = <String, dynamic>{
      'Method': punch.method,
      'offlineTimestamp': punch.createdAt.toIso8601String(),
      'Direction': punch.direction ?? 'In',
      'IPAddress': '0.0.0.0',
    };
    if (punch.latitude != null) body['Latitude'] = punch.latitude.toString();
    if (punch.longitude != null) body['Longitude'] = punch.longitude.toString();
    if (punch.wifiMAC != null) body['WifiMAC'] = punch.wifiMAC;
    if (punch.wifiSSID != null) body['WifiSSID'] = punch.wifiSSID;
    return body;
  }
}
