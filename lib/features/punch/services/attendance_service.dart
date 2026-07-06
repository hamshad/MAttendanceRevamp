import 'package:dio/dio.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/utils/app_logger.dart';
import '../../../models/attendance.dart';
import '../../../models/office.dart';

class AttendanceService {
  final Dio _dio;

  Dio get dio => _dio;

  AttendanceService(this._dio);

  Future<EmployeeStatus?> getTodayStatus() async {
    try {
      final response = await _dio.get(ApiEndpoints.todayStatus);
      print('[DEBUG_SHIFT] Raw /attendance/status JSON (service): ${response.data}');
      final data = response.data['data'] as Map<String, dynamic>?;
      return data != null ? EmployeeStatus.fromJson(data) : null;
    } catch (e) {
      AppLogger.e('ATTENDANCE_SERVICE: Failed to fetch today status', e);
      return null;
    }
  }

  Future<bool> punch({
    required String method,
    required String direction,
    required double latitude,
    required double longitude,
    String? address,
    String? ipAddress,
  }) async {
    try {
      final response = await _dio.post(ApiEndpoints.punch, data: {
        'Method': method,
        'Direction': direction,
        'Latitude': latitude.toString(),
        'Longitude': longitude.toString(),
        'Address': address ?? 'Auto-detected',
        'IPAddress': ipAddress ?? 'Background-Service',
      });
      
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      AppLogger.e('ATTENDANCE_SERVICE: Punch failed', e);
      return false;
    }
  }

  Future<List<Office>> fetchOffices() async {
    try {
      final response = await _dio.get(ApiEndpoints.employeeOffices);
      final data = response.data;
      final list = (data is List ? data : data['data'] ?? []) as List;
      return list.map((e) => Office.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      AppLogger.e('ATTENDANCE_SERVICE: Failed to fetch offices', e);
      return [];
    }
  }
}
