import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/location_service.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../models/office.dart';
import '../../../core/utils/app_logger.dart';

final gpsLocationProvider = FutureProvider.autoDispose<LocationResult>((ref) async {
  return await LocationService().getCurrentPosition();
});

final officeGeofencesProvider = FutureProvider.autoDispose<List<Office>>((ref) async {
  try {
    final dio = ref.read(dioClientProvider).dio;
    final response = await dio.get(ApiEndpoints.employeeOffices);
    final list = (response.data['data'] as List<dynamic>?) ?? [];
    return list
        .map((e) => Office.fromJson(e as Map<String, dynamic>))
        .where((o) => o.hasCoordinates)
        .toList();
  } catch (e) {
    return [];
  }
});

class GPSVerificationView extends ConsumerWidget {
  const GPSVerificationView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final locationAsync = ref.watch(gpsLocationProvider);
    final offices = ref.watch(officeGeofencesProvider).valueOrNull ?? [];

    return locationAsync.when(
      loading: () => const _LoadingView(),
      error: (e, _) => _ErrorView(
        message: 'Failed to get location. Please try again.',
        onRetry: () => ref.invalidate(gpsLocationProvider),
      ),
      data: (location) => _buildMap(context, theme, location, offices),
    );
  }

  Widget _buildMap(BuildContext context, ThemeData theme, LocationResult location, List<Office> offices) {
    final latLng = LatLng(location.latitude, location.longitude);

    return Column(
      children: [
        Expanded(
          child: FlutterMap(
            options: MapOptions(
              initialCenter: latLng,
              initialZoom: 16,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.mattendance.mattendance_mobile',
              ),
              if (offices.any((o) => o.geofenceRadius != null))
                CircleLayer(
                  circles: [
                    for (final office in offices)
                      if (office.geofenceRadius != null)
                        CircleMarker(
                          point: LatLng(office.latitude!, office.longitude!),
                          radius: office.geofenceRadius!.toDouble(),
                          useRadiusInMeter: true,
                          color: AppColors.warning.withAlpha(25),
                          borderColor: AppColors.warning.withAlpha(150),
                          borderStrokeWidth: 2,
                        ),
                  ],
                ),
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: latLng,
                    radius: location.accuracy,
                    useRadiusInMeter: true,
                    color: theme.colorScheme.primary.withAlpha(30),
                    borderColor: theme.colorScheme.primary.withAlpha(100),
                    borderStrokeWidth: 1.5,
                  ),
                ],
              ),
              MarkerLayer(
                markers: [
                  Marker(
                    point: latLng,
                    width: 40,
                    height: 40,
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: [
                          BoxShadow(
                            color: theme.colorScheme.primary.withAlpha(80),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                      child: const Icon(Icons.my_location, color: Colors.white, size: 18),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        _InfoPanel(location: location),
      ],
    );
  }
}

class _InfoPanel extends StatelessWidget {
  final LocationResult location;
  const _InfoPanel({required this.location});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      color: theme.scaffoldBackgroundColor,
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.location_on, size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              Text(
                '${location.latitude.toStringAsFixed(5)}°, ${location.longitude.toStringAsFixed(5)}°',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.radar, size: 16, color: _accuracyColor(location.accuracy)),
              const SizedBox(width: 8),
              Text(
                'Accuracy: ${location.accuracy.toStringAsFixed(0)}m',
                style: theme.textTheme.bodySmall?.copyWith(color: _accuracyColor(location.accuracy)),
              ),
              const Spacer(),
              Text(
                _accuracyLabel(location.accuracy),
                style: TextStyle(
                  fontSize: 11,
                  color: _accuracyColor(location.accuracy),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _accuracyColor(double acc) {
    if (acc <= 20) return AppColors.success;
    if (acc <= 50) return AppColors.warning;
    return AppColors.error;
  }

  String _accuracyLabel(double acc) {
    if (acc <= 20) return 'Excellent';
    if (acc <= 50) return 'Good';
    return 'Poor signal';
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();
  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Detecting GPS location...'),
      ],
    ),
  );
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.location_off, size: 48, color: AppColors.textSecondary),
        const SizedBox(height: 16),
        Text(message),
        TextButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    ),
  );
}
