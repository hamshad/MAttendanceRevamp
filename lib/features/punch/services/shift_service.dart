import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/constants.dart';
import '../../../models/shift.dart';

class ShiftService {
  final Dio _dio;

  ShiftService(this._dio);

  Future<List<Shift>> fetchShifts() async {
    try {
      final response = await _dio.get(ApiEndpoints.shifts);
      final data = response.data;
      final list = (data is List ? data : data['data'] ?? []) as List;
      return list.map((e) => Shift.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      AppLogger.e('SHIFT_SERVICE: Failed to fetch shifts', e);
      return [];
    }
  }

  static Future<void> cacheShifts(List<Shift> shifts) async {
    final box = await Hive.openBox(AppConstants.shiftsBox);
    final json = shifts.map((s) => s.toJson()).toList();
    await box.put('cached', jsonEncode(json));
  }

  static List<Shift> loadCachedShifts() {
    try {
      final box = Hive.box(AppConstants.shiftsBox);
      final raw = box.get('cached') as String?;
      if (raw == null) return [];
      final list = jsonDecode(raw) as List;
      return list.map((e) => Shift.fromJson(e as Map<String, dynamic>)).toList();
    } catch (e) {
      AppLogger.e('SHIFT_SERVICE: Failed to load cached shifts', e);
      return [];
    }
  }

  static Shift? findShiftByName(List<Shift> shifts, String name) {
    for (final s in shifts) {
      if (s.name == name) return s;
    }
    return null;
  }
}
