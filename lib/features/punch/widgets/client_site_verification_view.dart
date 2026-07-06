import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../models/client_site.dart';
import '../services/camera_service.dart';
import '../services/location_service.dart';

class ClientSiteVerificationView extends ConsumerStatefulWidget {
  final Function(Map<String, dynamic> data) onDataChanged;

  const ClientSiteVerificationView({super.key, required this.onDataChanged});

  @override
  ConsumerState<ClientSiteVerificationView> createState() => _ClientSiteVerificationViewState();
}

class _ClientSiteVerificationViewState extends ConsumerState<ClientSiteVerificationView> {
  final _cameraService = CameraService();
  final _locationService = LocationService();

  bool _sitesLoading = true;
  String? _sitesError;
  List<ClientSite> _sites = [];

  bool _locationLoading = true;
  String? _locationError;
  LocationResult? _location;

  bool _cameraReady = false;
  String? _cameraError;

  ClientSite? _selectedSite;
  double? _distance;

  @override
  void initState() {
    super.initState();
    _loadSites();
    _loadLocation();
    _initCamera();
  }

  @override
  void dispose() {
    _cameraService.dispose();
    super.dispose();
  }

  Future<void> _loadSites() async {
    try {
      final dio = ref.read(dioClientProvider).dio;
      final response = await dio.get(ApiEndpoints.clientSitesActive);
      final list = response.data['data'] as List<dynamic>? ?? [];
      if (mounted) {
        setState(() {
          _sites = list.map((e) => ClientSite.fromJson(e as Map<String, dynamic>)).toList();
          _sitesLoading = false;
          if (_sites.isNotEmpty) _selectedSite = _sites.first;
          _recompute();
        });
      }
    } catch (_) {
      if (mounted) setState(() { _sitesError = 'Failed to load sites'; _sitesLoading = false; });
    }
  }

  Future<void> _loadLocation() async {
    try {
      final loc = await _locationService.getCurrentPosition();
      if (mounted) {
        setState(() { _location = loc; _locationLoading = false; _recompute(); });
      }
    } catch (_) {
      if (mounted) setState(() { _locationError = 'GPS error'; _locationLoading = false; });
    }
  }

  Future<void> _initCamera() async {
    try {
      await _cameraService.initialize();
      if (mounted) setState(() => _cameraReady = true);
    } catch (_) {
      if (mounted) setState(() => _cameraError = 'Camera error');
    }
  }

  void _recompute() {
    if (_selectedSite == null || _location == null) {
      _distance = null;
    } else {
      _distance = Geolocator.distanceBetween(
        _location!.latitude, _location!.longitude,
        _selectedSite!.latitude, _selectedSite!.longitude,
      );
    }
    _notify();
  }

  Future<void> _notify() async {
    if (_selectedSite == null || _location == null || !_cameraReady) return;
    
    // We only capture when handlePunch is called in parent, 
    // but the parent needs to know the siteId and location.
    widget.onDataChanged({
      'clientSiteId': _selectedSite?.id,
      'latitude': _location?.latitude,
      'longitude': _location?.longitude,
      'cameraService': _cameraService, // Pass service to allow parent to capture
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Label('Select Site'),
          const SizedBox(height: 8),
          _buildDropdown(),
          const SizedBox(height: 20),
          _Label('Your Location'),
          const SizedBox(height: 8),
          _buildLocationCard(theme),
          const SizedBox(height: 20),
          _Label('Selfie'),
          const SizedBox(height: 8),
          _buildCamera(theme),
        ],
      ),
    );
  }

  Widget _buildDropdown() {
    if (_sitesLoading) return _Skeleton(height: 56);
    if (_sites.isEmpty) return const Text('No active sites');
    return DropdownButtonFormField<ClientSite>(
      value: _selectedSite,
      isExpanded: true,
      items: _sites.map((s) => DropdownMenuItem(
        value: s,
        child: Text(
          s.displayName,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
        ),
      )).toList(),
      onChanged: (s) => setState(() { _selectedSite = s; _recompute(); }),
      decoration: const InputDecoration(prefixIcon: Icon(Icons.business_outlined)),
    );
  }

  Widget _buildLocationCard(ThemeData theme) {
    if (_locationLoading) return _Skeleton(height: 70);
    final within = _selectedSite != null && _distance != null && _distance! <= _selectedSite!.radiusMeters;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: within ? AppColors.success.withAlpha(50) : AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.location_on, size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 8),
              if (_location != null)
                Flexible(
                  child: Text(
                    '${_location!.latitude.toStringAsFixed(5)}, ${_location!.longitude.toStringAsFixed(5)}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const Spacer(),
              IconButton(icon: const Icon(Icons.refresh, size: 16), onPressed: () => setState(() { _locationLoading = true; _loadLocation(); })),
            ],
          ),
          if (_selectedSite != null && _distance != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(within ? Icons.check_circle : Icons.cancel, size: 16, color: within ? AppColors.success : AppColors.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    within ? 'Within site geofence (${_distance!.toStringAsFixed(0)}m)' : 'Too far from site (${_distance!.toStringAsFixed(0)}m)',
                    style: TextStyle(fontSize: 12, color: within ? AppColors.success : AppColors.error),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCamera(ThemeData theme) {
    if (!_cameraReady) return _Skeleton(height: 180);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(height: 180, child: Stack(fit: StackFit.expand, children: [
        CameraPreview(_cameraService.controller!),
        CustomPaint(painter: _OvalPainter()),
      ])),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(text, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: AppColors.textSecondary));
}

class _Skeleton extends StatelessWidget {
  final double height;
  const _Skeleton({required this.height});
  @override
  Widget build(BuildContext context) => Container(height: height, decoration: BoxDecoration(color: AppColors.graySubtle, borderRadius: BorderRadius.circular(10)));
}

class _OvalPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.4;
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy), width: size.width * 0.5, height: size.height * 0.7), 
                    Paint()..color = Colors.white.withAlpha(150)..style = PaintingStyle.stroke..strokeWidth = 2);
  }
  @override
  bool shouldRepaint(CustomPainter old) => false;
}
