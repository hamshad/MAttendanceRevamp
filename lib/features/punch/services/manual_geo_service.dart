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
  ///
  /// When [knownPosition] is provided (the fix already shown on the punch
  /// screen map), it is reused instead of reading GPS again — a second
  /// `getCurrentPosition()` call can return a stale cached fused fix on some
  /// devices (Samsung), producing coordinates different from what the user
  /// sees, and wrongly denying a punch that is inside the geofence.
  Future<Office?> validateProximity([LocationResult? knownPosition]) async {
    try {
      AppLogger.d('MANUAL_GEO: Validating proximity...');

      // 1. Get current position — reuse the on-screen fix when available.
      final position =
          knownPosition ?? await LocationService().getCurrentPosition();

      // 2. Fetch offices
      final response = await _dio.get(ApiEndpoints.employeeOffices);
      final list = (response.data is List ? response.data : response.data['data'] ?? []) as List;
      final offices = list.map((e) => Office.fromJson(e as Map<String, dynamic>)).toList();

      // 3. Check proximity to each office
      //    Mirror the background worker: allow radius + GPS margin
      //    (2× accuracy, clamped 10–250m) so borderline fixes at the geofence
      //    edge are not wrongly rejected.
      final margin = (position.accuracy * 2.0).clamp(10.0, 250.0);
      for (final office in offices) {
        if (!office.hasCoordinates) continue;
        if (office.geofenceRadius == null) continue;

        final distance = Geolocator.distanceBetween(
          position.latitude,
          position.longitude,
          office.latitude!,
          office.longitude!,
        );
        final radius = office.geofenceRadius!.toDouble();

        if (distance <= radius + margin) {
          AppLogger.i('MANUAL_GEO: Inside ${office.name} (Dist: ${distance.toStringAsFixed(1)}m, margin: ${margin.toStringAsFixed(1)}m)');
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
