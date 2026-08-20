import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/client_site.dart';
import '../../models/office.dart';
import '../api/api_endpoints.dart';
import '../utils/app_logger.dart';
import '../utils/constants.dart';

class OfficeDataService {
  final Dio _dio;
  bool _hasLoggedThisSession = false;

  OfficeDataService(this._dio);

  Future<void> fetchAndSaveOffices() async {
    if (_hasLoggedThisSession) return;

    const endpoint = ApiEndpoints.employeeOffices;

    try {
      final response = await _dio.get(endpoint);
      final data = response.data;

      _logResponse(endpoint, response.statusCode, data);
      await _saveToLocalCache(endpoint, data);

      final list = (data is List ? data : data['data'] ?? []) as List;
      final offices = list
          .map((e) => Office.fromJson(e as Map<String, dynamic>))
          .toList();
      await _persistOffices(offices);

      _hasLoggedThisSession = true;
      AppLogger.i('OFFICE_DATA: Successfully processed and cached offices');
    } catch (e) {
      AppLogger.e('OFFICE_DATA: Failed to fetch offices', e);
    }
  }

  void _logResponse(String endpoint, int? status, dynamic data) {
    const divider =
        '══════════════════════════════════════════════════════════════════════════════════════════';
    final url = '${AppConstants.apiBaseUrl}$endpoint';

    print('╔╣ Response ║ GET ║ Status: $status OK ║');
    print('║ URL: $url');
    print('╚$divider╝');
    print('╔ Body');
    print('║');

    final prettyJson = const JsonEncoder.withIndent('    ').convert(data);
    for (final line in prettyJson.split('\n')) {
      print('║    $line');
    }
    print('║');
    print('╚$divider╝');
  }

  Future<void> _saveToLocalCache(String endpoint, dynamic data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('cached_offices_api', endpoint);
    await prefs.setString('cached_offices_response', jsonEncode(data));
  }

  Future<void> _persistOffices(List<Office> offices) async {
    final box = Hive.box(AppConstants.cacheBox);
    final json = offices.map((o) => o.toJson()).toList();
    await box.put('offices', jsonEncode(json));
    AppLogger.i(
        'OFFICE_DATA: Persisted ${offices.length} offices to local cache');
  }

  static List<Office>? getCachedOffices() {
    final box = Hive.box(AppConstants.cacheBox);
    final raw = box.get('offices') as String?;
    if (raw == null) return null;
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => Office.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Fetches active client sites and caches them locally (same pattern as
  /// offices) so the auto-geofence engine and the places screen can use them
  /// without a network round-trip.
  Future<List<ClientSite>> fetchAndSaveClientSites() async {
    const endpoint = ApiEndpoints.clientSitesActive;

    try {
      final response = await _dio.get(endpoint);
      final data = response.data;
      _logResponse(endpoint, response.statusCode, data);

      final list = (data is List ? data : data['data'] ?? []) as List;
      final sites = list
          .map((e) => ClientSite.fromJson(e as Map<String, dynamic>))
          .toList();
      await _persistClientSites(sites);

      AppLogger.i(
          'OFFICE_DATA: Successfully fetched and cached ${sites.length} client sites');
      return sites;
    } catch (e) {
      AppLogger.e('OFFICE_DATA: Failed to fetch client sites', e);
      return getCachedClientSites() ?? [];
    }
  }

  Future<void> _persistClientSites(List<ClientSite> sites) async {
    final box = Hive.box(AppConstants.cacheBox);
    final json = sites.map((s) => s.toJson()).toList();
    await box.put('client_sites', jsonEncode(json));
  }

  static List<ClientSite>? getCachedClientSites() {
    final box = Hive.box(AppConstants.cacheBox);
    final raw = box.get('client_sites') as String?;
    if (raw == null) return null;
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => ClientSite.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  void reset() {
    _hasLoggedThisSession = false;
  }
}
