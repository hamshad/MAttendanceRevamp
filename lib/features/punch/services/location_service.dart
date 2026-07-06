import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import '../../../core/utils/app_logger.dart';

class LocationResult {
  final double latitude;
  final double longitude;
  final double accuracy; // meters
  final double? altitude;

  const LocationResult({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    this.altitude,
  });
}

class LocationPermissionDeniedException implements Exception {
  final String message;
  const LocationPermissionDeniedException(this.message);
}

class LocationService {
  Future<LocationResult> getCurrentPosition() async {
    AppLogger.d('LOCATION: Requesting current position...');

    // Check if location services are enabled
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      AppLogger.w('LOCATION: Services are disabled');
      throw const LocationPermissionDeniedException(
        'Location services are disabled. Please enable GPS in device settings.',
      );
    }

    // Check/request permission
    var permission = await Geolocator.checkPermission();
    AppLogger.d('LOCATION: Current permission level: $permission');

    if (permission == LocationPermission.denied) {
      AppLogger.i('LOCATION: Permission denied, requesting...');
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        AppLogger.e('LOCATION: Permission request denied again');
        throw const LocationPermissionDeniedException(
          'Location permission denied. Please allow location access for GPS punch.',
        );
      }
    }

    if (permission == LocationPermission.deniedForever) {
      AppLogger.e('LOCATION: Permission permanently denied');
      throw const LocationPermissionDeniedException(
        'Location permission permanently denied. Please enable it in app settings.',
      );
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      AppLogger.i('LOCATION: Position acquired: ${position.latitude}, ${position.longitude} (Acc: ${position.accuracy})');

      return LocationResult(
        latitude: position.latitude,
        longitude: position.longitude,
        accuracy: position.accuracy,
        altitude: position.altitude,
      );
    } catch (e) {
      AppLogger.e('LOCATION: Failed to get current position', e);
      rethrow;
    }
  }

  /// Reverse-geocode coordinates into a human-readable address string.
  /// Returns null if the lookup fails or returns no results.
  Future<String?> getAddressFromCoordinates(double lat, double lng) async {
    AppLogger.d('LOCATION: Reverse geocoding $lat, $lng');
    try {
      final placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isEmpty) {
        AppLogger.w('LOCATION: No placemarks found for coordinates');
        return null;
      }
      final p = placemarks.first;
      // Build: "Street, SubLocality, Locality, AdministrativeArea"
      // Skip any empty parts so we don't get ",,"-style gaps.
      final parts = [
        p.street,
        p.subLocality,
        p.locality,
        p.administrativeArea,
      ].where((s) => s != null && s.isNotEmpty).toList();
      
      final address = parts.isEmpty ? null : parts.join(', ');
      AppLogger.d('LOCATION: Resolved address: $address');
      return address;
    } catch (e) {
      AppLogger.e('LOCATION: Reverse geocoding failed', e);
      return null;
    }
  }

  /// Distance in meters between two coordinates (Haversine formula via geolocator)
  double distanceBetween(
    double lat1, double lon1,
    double lat2, double lon2,
  ) {
    return Geolocator.distanceBetween(lat1, lon1, lat2, lon2);
  }

  Stream<Position> getPositionStream() {
    AppLogger.i('LOCATION: Starting position track stream');
    return Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10, // update every 10m movement
      ),
    ).handleError((error) {
      AppLogger.e('LOCATION: Stream error', error);
    });
  }
}
