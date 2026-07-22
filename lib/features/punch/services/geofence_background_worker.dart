import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/api/punch_state_interceptor.dart';
import '../../../core/utils/constants.dart';
import '../../../models/office.dart';
import '../../tracking/models/location_result.dart';

/// iOS-native geofence auto-punch worker.
///
/// Runs inside the same flutter_background_service isolate as
/// [WifiBackgroundWorker]. On each location fix, checks distance
/// against cached office geofences. Enters → punches IN (GPS method).
/// Exits → punches OUT.
///
/// Minimum interval between geofence checks: 30s.
/// Exit radius = 2× geofenceRadius (hysteresis prevents boundary flicker).
class GeofenceBackgroundWorker {
  final ServiceInstance _service;

  late final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  List<Office> _offices = [];
  String? _currentOfficeName;
  DateTime? _lastCheck;

  static const _minInterval = Duration(seconds: 30);
  static const _exitMultiplier = 2.0;

  // SharedPreferences keys
  static const _kLastPunchType = 'gf_last_punch_type';
  static const _kCurrentOffice = 'gf_current_office';
  static const _kLastPunchTime = 'gf_last_punch_time';
  static const _kMatchedOfficeName = 'gf_last_punch_office';

  GeofenceBackgroundWorker(this._service);

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  Future<void> loadData() async {
    debugPrint('[GF_BG] loadData()');
    await _loadOffices();
    final prefs = await SharedPreferences.getInstance();
    _currentOfficeName = prefs.getString(_kCurrentOffice);
    if (_currentOfficeName?.isEmpty == true) _currentOfficeName = null;
    debugPrint('[GF_BG] Restored office: $_currentOfficeName');
  }

  /// Called on every location fix from the GPS stream.
  /// Rate-limited to 30s between checks.
  Future<void> onLocationFix(dynamic locDyn, dynamic stateDyn, dynamic confidenceDyn) async {
    if (_offices.isEmpty) return;

    // Rate limit
    final now = DateTime.now();
    if (_lastCheck != null && now.difference(_lastCheck!) < _minInterval) return;
    _lastCheck = now;

    final loc = locDyn as LocationResult;

    // Find nearest office within enter/exit thresholds
    Office? enterOffice;  // within geofenceRadius
    Office? stayOffice;   // within geofenceRadius * exitMultiplier
    double minEnterDist = double.infinity;
    double minStayDist = double.infinity;

    for (final office in _offices) {
      if (!office.hasCoordinates) continue;
      final dist = Geolocator.distanceBetween(
        loc.latitude, loc.longitude,
        office.latitude!, office.longitude!,
      );
      final radius = (office.geofenceRadius ?? 100).toDouble();

      if (dist <= radius && dist < minEnterDist) {
        enterOffice = office;
        minEnterDist = dist;
      }
      if (dist <= radius * _exitMultiplier && dist < minStayDist) {
        stayOffice = office;
        minStayDist = dist;
      }
    }

    final wasIn = _currentOfficeName != null;
    final nowIn = enterOffice != null;
    final stillIn = stayOffice != null;

    if (nowIn && (!wasIn || _currentOfficeName != enterOffice!.name)) {
      debugPrint('[GF_BG] ENTER geofence: ${enterOffice!.name}');
      _currentOfficeName = enterOffice!.name;
      await _saveCurrentOffice(enterOffice!.name);
      await _onEnter(enterOffice!);
    } else if (!stillIn && wasIn) {
      debugPrint('[GF_BG] EXIT geofence: $_currentOfficeName');
      final exitedName = _currentOfficeName;
      _currentOfficeName = null;
      await _saveCurrentOffice('');
      await _onExit(exitedName!);
    }
  }

  // ── Enter / Exit ───────────────────────────────────────────────────────────

  Future<void> _onEnter(Office office) async {
    final prefs = await SharedPreferences.getInstance();
    final lastType = prefs.getString(_kLastPunchType);
    if (lastType == 'In') {
      debugPrint('[GF_BG] Already IN — skip');
      return;
    }

    // Check if connected to office WiFi — WifiBgWorker should handle that
    // but we punch as GPS method anyway (more reliable for geofence)
    await _punchIn(office);
  }

  Future<void> _onExit(String officeName) async {
    final prefs = await SharedPreferences.getInstance();
    final lastType = prefs.getString(_kLastPunchType);
    if (lastType != 'In') {
      debugPrint('[GF_BG] Not IN — skip exit');
      return;
    }
    await _punchOut(officeName);
  }

  // ── Office Data ────────────────────────────────────────────────────────────

  Future<void> _loadOffices() async {
    debugPrint('[GF_BG] Loading offices...');
    try {
      final dio = await _buildDio();
      if (dio == null) {
        debugPrint('[GF_BG] No auth token — cannot load offices');
        return;
      }

      final resp = await dio.get(ApiEndpoints.employeeOffices);
      final data = resp.data;
      final list = (data is List ? data : data['data'] ?? []) as List;

      _offices = list
          .map((e) => Office.fromJson(e as Map<String, dynamic>))
          .toList();

      debugPrint('[GF_BG] Loaded ${_offices.length} offices');
    } catch (e) {
      debugPrint('[GF_BG] Failed to load offices: $e');
    }
  }

  // ── Punch ──────────────────────────────────────────────────────────────────

  Future<void> _punchIn(Office office) async {
    try {
      final dio = await _buildDio();
      if (dio == null) {
        debugPrint('[GF_BG] No auth token — cannot punch IN');
        return;
      }

      final resp = await dio.post(ApiEndpoints.punch, data: {
        'Method': 'GPS',
        'Direction': 'In',
        'Latitude': office.latitude,
        'Longitude': office.longitude,
        'remarks': 'Auto-Punch In (Geofence)',
      });

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        debugPrint('[GF_BG] Punched IN at ${office.name}');
        await _setLastPunchType('In', office.name);
        await _clearManualIn();
        await _showNotification('Geofence In', '${office.name} · ${_fmtTime(DateTime.now())}');

        _service.invoke('gf_punch', {
          'direction': 'In',
          'officeName': office.name,
          'time': DateTime.now().toIso8601String(),
        });
      }
    } on DioException catch (e) {
      debugPrint('[GF_BG] Punch IN DioException: ${e.message}');
      await _handleDuplicate(e, 'In', office.name);
    } catch (e) {
      debugPrint('[GF_BG] Punch IN error: $e');
    }
  }

  Future<void> _punchOut(String officeName) async {
    try {
      final dio = await _buildDio();
      if (dio == null) {
        debugPrint('[GF_BG] No auth token — cannot punch OUT');
        return;
      }

      final resp = await dio.post(ApiEndpoints.punch, data: {
        'Method': 'GPS',
        'Direction': 'Out',
        'remarks': 'Auto-Punch Out (Geofence exit)',
      });

      if (resp.statusCode == 200 || resp.statusCode == 201) {
        debugPrint('[GF_BG] Punched OUT');
        await _setLastPunchType('Out', '');
        await _clearManualIn();
        await _showNotification('Geofence Out', '${_fmtTime(DateTime.now())}');

        _service.invoke('gf_punch', {
          'direction': 'Out',
          'officeName': officeName,
          'time': DateTime.now().toIso8601String(),
        });
      }
    } on DioException catch (e) {
      debugPrint('[GF_BG] Punch OUT DioException: ${e.message}');
      await _handleDuplicate(e, 'Out', '');
    } catch (e) {
      debugPrint('[GF_BG] Punch OUT error: $e');
    }
  }

  Future<void> _handleDuplicate(DioException e, String direction, String officeName) async {
    if (e.response != null) {
      final body = e.response?.data;
      if (body is Map && body['message'] is String) {
        final msg = body['message'] as String;
        if (msg.contains('already recorded') || msg.contains('Duplicate')) {
          debugPrint('[GF_BG] Duplicate detected — syncing state');
          await _setLastPunchType(direction, officeName);
        }
      }
    }
  }

  // ── SharedPreferences State ────────────────────────────────────────────────

  Future<void> _setLastPunchType(String type, String officeName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastPunchType, type);
    await prefs.setString(_kLastPunchTime, DateTime.now().toIso8601String());
    await prefs.setString(_kMatchedOfficeName, officeName);
  }

  Future<void> _saveCurrentOffice(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kCurrentOffice, name);
  }

  Future<void> _clearManualIn() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wifi_manual_in', false);
  }

  // ── HTTP Helpers ───────────────────────────────────────────────────────────

  Future<Dio?> _buildDio() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('bg_access_token');
    if (token == null) return null;

    final dio = Dio(BaseOptions(
      baseUrl: AppConstants.apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Authorization': 'Bearer $token',
        'X-Client-Type': 'mobile',
        'X-Platform': Platform.isIOS ? 'ios' : 'android',
      },
    ));

    dio.interceptors.addAll([
      InterceptorsWrapper(
        onError: (error, handler) async {
          if (error.response?.statusCode != 401) return handler.next(error);
          debugPrint('[GF_BG] 401 — refreshing token');

          try {
            final refreshed = await _refreshToken();
            if (refreshed == null) return handler.next(error);
            error.requestOptions.headers['Authorization'] = 'Bearer $refreshed';
            final retry = await dio.fetch(error.requestOptions);
            return handler.resolve(retry);
          } catch (e) {
            debugPrint('[GF_BG] Token refresh error: $e');
            return handler.next(error);
          }
        },
      ),
      PunchStateInterceptor(),
    ]);

    return dio;
  }

  Future<String?> _refreshToken() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    final lockTs = prefs.getInt('bg_refresh_lock') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lockTs > 0 && (now - lockTs) < 30000) {
      debugPrint('[GF_BG] Another isolate refreshing — skip');
      return null;
    }

    await prefs.setInt('bg_refresh_lock', now);

    try {
      final refreshToken = prefs.getString('bg_refresh_token');
      final accessToken = prefs.getString('bg_access_token');
      if (refreshToken == null || accessToken == null) {
        await prefs.remove('bg_refresh_lock');
        return null;
      }

      final rdio = Dio(BaseOptions(
        baseUrl: AppConstants.apiBaseUrl,
        connectTimeout: const Duration(seconds: 15),
      ));

      final resp = await rdio.post('/api/v1/auth/refresh', data: {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
      });

      final newAccess = resp.data['accessToken'] as String;
      final newRefresh = resp.data['refreshToken'] as String;

      await Future.wait([
        prefs.setString('bg_access_token', newAccess),
        prefs.setString('bg_refresh_token', newRefresh),
        prefs.setInt('bg_token_ts', DateTime.now().millisecondsSinceEpoch),
        prefs.remove('bg_refresh_lock'),
      ]);

      return newAccess;
    } catch (e) {
      await prefs.remove('bg_refresh_lock');
      return null;
    }
  }

  // ── Notification ───────────────────────────────────────────────────────────

  String _fmtTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  Future<void> _showNotification(String title, String body) async {
    try {
      await _notifications.show(
        996,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'geofence_punch_bg',
            'Geofence Auto-Punch',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[GF_BG] Notification failed: $e');
    }
  }
}
