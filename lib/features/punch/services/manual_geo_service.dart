import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/utils/app_logger.dart';
import '../../../models/office.dart';
import '../../punch/services/location_service.dart';

/// FEATURE 1: MANUAL GEO PUNCH SERVICE
/// 
/// Triggered manually when the user taps the "Geo" button.
/// Performs a one-time location check. No background task.
class ManualGeoService {
  final Dio _dio;

  ManualGeoService({required Dio dio}) : _dio = dio;

  /// Validates if the user is currently within any assigned office geofence.
  /// Returns the office if inside, null otherwise.
  Future<Office?> validateProximity() async {
    try {
      AppLogger.d('MANUAL_GEO: Validating proximity...');
      
      // 1. Get current position
      final position = await LocationService().getCurrentPosition();
      
      // 2. Fetch offices
      final response = await _dio.get(ApiEndpoints.employeeOffices);
      final list = (response.data is List ? response.data : response.data['data'] ?? []) as List;
      final offices = list.map((e) => Office.fromJson(e as Map<String, dynamic>)).toList();

      // 3. Check proximity to each office
      for (final office in offices) {
        if (!office.hasCoordinates) continue;

        final distance = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          office.latitude!,
          office.longitude!,
        );

        if (office.geofenceRadius == null) continue;
        final radius = office.geofenceRadius!.toDouble();

        if (distance <= radius) {
          AppLogger.i('MANUAL_GEO: Inside ${office.name} (Dist: ${distance.toStringAsFixed(1)}m)');
          return office;
        }
      }

      AppLogger.w('MANUAL_GEO: User is not inside any office geofence.');
      return null;
    } catch (e) {
      AppLogger.e('MANUAL_GEO: Proximity validation failed', e);
      return null;
    }
  }
}
