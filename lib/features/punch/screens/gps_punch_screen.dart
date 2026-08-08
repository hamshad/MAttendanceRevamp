import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/location_service.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/constants.dart';
import '../../../core/utils/app_logger.dart';
import '../../../models/office.dart';

// ── Providers ─────────────────────────────────────────────────────────────────

final _gpsLocationProvider = FutureProvider.autoDispose<LocationResult>((ref) async {
  AppLogger.d('GPS_PUNCH: Requesting current position');
  final position = await LocationService().getCurrentPosition();
  AppLogger.i('GPS_PUNCH: Position obtained: ${position.latitude}, ${position.longitude} (Accuracy: ${position.accuracy}m)');
  return position;
});

/// Fetches offices that have coordinates so we can draw geofence circles.
/// Failures are swallowed — map works without circles.
final _officeGeofencesProvider = FutureProvider.autoDispose<List<Office>>((ref) async {
  try {
    AppLogger.d('GPS_PUNCH: Fetching office geofences');
    final dio = ref.read(dioClientProvider).dio;
    final response = await dio.get(ApiEndpoints.employeeOffices);
    final list = (response.data['data'] as List<dynamic>?) ?? [];
    final offices = list
        .map((e) => Office.fromJson(e as Map<String, dynamic>))
        .where((o) => o.hasCoordinates)
        .toList();
    AppLogger.i('GPS_PUNCH: Found ${offices.length} offices with geofences');
    return offices;
  } catch (e) {
    AppLogger.e('GPS_PUNCH: Failed to fetch office geofences', e);
    return [];
  }
});

// ── Screen ────────────────────────────────────────────────────────────────────

class GPSPunchScreen extends ConsumerStatefulWidget {
  final String direction; // 'In' | 'Out' | 'BreakStart' | 'BreakEnd'
  final String method;    // Usually 'GPS' or 'GeofenceAuto'

  const GPSPunchScreen({
    super.key,
    required this.direction,
    this.method = 'GPS',
  });

  @override
  ConsumerState<GPSPunchScreen> createState() => _GPSPunchScreenState();
}

class _GPSPunchScreenState extends ConsumerState<GPSPunchScreen> {
  final MapController _mapController = MapController();
  bool _isPunching = false;

  Future<void> _confirmPunch(LocationResult location) async {
    AppLogger.activity('User confirmed GPS Punch ${widget.direction}', data: {
      'latitude': location.latitude,
      'longitude': location.longitude,
      'accuracy': location.accuracy,
    });
    setState(() => _isPunching = true);

    // FEATURE 1: Manual Proximity Check
    // Validate against the SAME fix shown on the map (the one being punched) —
    // not a second GPS read, which on some devices (Samsung) returns a stale
    // fused fix different from what the user sees and wrongly denies the punch.
    if (widget.method == 'GeofenceAuto') {
      final office =
          await ref.read(manualGeoServiceProvider).validateProximity(location);
      if (office == null) {
        if (!mounted) return;
        setState(() => _isPunching = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You are not inside any office geofence. Manual Geo punch denied.'),
            backgroundColor: AppColors.error,
          ),
        );
        return;
      }
    }

    var result = await ref.read(punchProvider.notifier).punch(
      widget.method,
      extras: {
        'latitude': location.latitude,
        'longitude': location.longitude,
        'direction': widget.direction,
      },
    );

    // Server already has this punch (biometric/website) — short confirm
    // before forcing.
    if (result.isDuplicate && mounted) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Punch anyway?'),
          content: Text(result.message ?? 'Already punched'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes'),
            ),
          ],
        ),
      );
      if (confirm == true && mounted) {
        result = await ref.read(punchProvider.notifier).punch(
          widget.method,
          extras: {
            'latitude': location.latitude,
            'longitude': location.longitude,
            'direction': widget.direction,
          },
          force: true,
        );
      }
    }

    if (!mounted) return;
    setState(() => _isPunching = false);

    if (result.success) {
      AppLogger.i('GPS_PUNCH: Success - ${result.message}');
      AppLogger.activity('GPS Punch Success', data: {'direction': widget.direction});
    } else {
      AppLogger.w('GPS_PUNCH: Failed - ${result.message}');
      AppLogger.activity('GPS Punch Failed', data: {'direction': widget.direction, 'error': result.message});
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message ?? (result.success ? 'Punch recorded!' : 'Punch failed')),
        backgroundColor: result.success ? AppColors.success : AppColors.error,
      ),
    );

    if (result.success) Navigator.pop(context);
  }

  @override
  void initState() {
    super.initState();
    AppLogger.d('GPS_PUNCH: Screen initialized with direction: ${widget.direction}');
    AppLogger.activity('Opened GPS Punch Screen', data: {'direction': widget.direction});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final locationAsync = ref.watch(_gpsLocationProvider);
    // Offices load in parallel; failures yield empty list (circles optional).
    final offices = ref.watch(_officeGeofencesProvider).valueOrNull ?? [];
    final dirLabel = _directionLabel(widget.direction);

    return Scaffold(
      appBar: AppBar(
        title: Text('GPS Punch $dirLabel'),
        leading: const CloseButton(),
      ),
      body: locationAsync.when(
        loading: () => const _LoadingView(),
        error: (e, _) => _ErrorView(
          message: e is LocationPermissionDeniedException
              ? e.message
              : e is LocationPrecisionRequiredException
                  ? e.message
                  : 'Failed to get location. Please try again.',
          onRetry: () => ref.invalidate(_gpsLocationProvider),
        ),
        data: (location) => _buildContent(context, theme, location, dirLabel, offices),
      ),
    );
  }

  Widget _buildContent(
    BuildContext context,
    ThemeData theme,
    LocationResult location,
    String dirLabel,
    List<Office> offices,
  ) {
    final latLng = LatLng(location.latitude, location.longitude);

    return Column(
      children: [
        // ── Map ─────────────────────────────────────────────────────────────
        Expanded(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: latLng,
              initialZoom: 16,
            ),
            children: [
              // OpenStreetMap tiles — no API key required
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.mattendance.mattendance_mobile',
              ),
              // Office geofence circles
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
                          borderColor: AppColors.warning,
                          borderStrokeWidth: 2,
                        ),
                  ],
                ),
              // Accuracy circle
              CircleLayer(
                circles: [
                  CircleMarker(
                    point: latLng,
                    radius: location.accuracy,
                    useRadiusInMeter: true,
                    color: theme.colorScheme.primary.withAlpha(40),
                    borderColor: theme.colorScheme.primary.withAlpha(120),
                    borderStrokeWidth: 1.5,
                  ),
                ],
              ),
              // Current location marker
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

        // ── Info + Action panel ──────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(15),
                blurRadius: 12,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: Column(
            children: [
              // Coordinates row
              Row(
                children: [
                  const Icon(Icons.location_on, size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '${location.latitude.toStringAsFixed(5)}°, '
                      '${location.longitude.toStringAsFixed(5)}°',
                      style: theme.textTheme.bodyMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),

              // Accuracy row
              Row(
                children: [
                  Icon(
                    Icons.radar,
                    size: 16,
                    color: _accuracyColor(location.accuracy),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Accuracy: ${location.accuracy.toStringAsFixed(0)}m',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _accuracyColor(location.accuracy),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      _accuracyLabel(location.accuracy),
                      style: TextStyle(
                        fontSize: 11,
                        color: _accuracyColor(location.accuracy),
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Confirm button
              ElevatedButton.icon(
                onPressed: _isPunching ? null : () => _confirmPunch(location),
                icon: _isPunching
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.gps_fixed),
                label: Text(
                  _isPunching ? 'Recording...' : 'Confirm $dirLabel',
                  style: const TextStyle(fontSize: 16),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _directionColor(widget.direction),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _directionLabel(String dir) => switch (dir) {
        'In' => 'Punch In',
        'Out' => 'Punch Out',
        'BreakStart' => 'Break Start',
        'BreakEnd' => 'Break End',
        _ => dir,
      };

  Color _directionColor(String dir) => switch (dir) {
        'In' => AppColors.success,
        'Out' => AppColors.error,
        'BreakStart' => AppColors.warning,
        'BreakEnd' => AppColors.info,
        _ => AppColors.success,
      };

  Color _accuracyColor(double accuracy) {
    if (accuracy <= 20) return AppColors.success;
    if (accuracy <= 50) return AppColors.warning;
    return AppColors.error;
  }

  String _accuracyLabel(double accuracy) {
    if (accuracy <= 20) return '(Excellent)';
    if (accuracy <= 50) return '(Good)';
    return '(Poor — wait for better signal)';
  }
}

// ── Loading / Error ───────────────────────────────────────────────────────────

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Getting your location...'),
          SizedBox(height: 6),
          Text(
            'Make sure GPS is enabled',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorView({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.location_off, size: 64, color: AppColors.textSecondary),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }
}
