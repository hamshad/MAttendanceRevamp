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
import '../../dashboard/providers/dashboard_providers.dart';

// ── Screen ────────────────────────────────────────────────────────────────────

class ClientSiteScreen extends ConsumerStatefulWidget {
  final String direction;

  /// Optional client site to preselect when opened from a geofence prompt
  /// notification. When null, defaults to the first site in the list.
  final int? initialSiteId;

  const ClientSiteScreen({
    super.key,
    required this.direction,
    this.initialSiteId,
  });

  @override
  ConsumerState<ClientSiteScreen> createState() => _ClientSiteScreenState();
}

class _ClientSiteScreenState extends ConsumerState<ClientSiteScreen> {
  final _cameraService = CameraService();
  final _locationService = LocationService();

  // ── Loading state ──────────────────────────────────────────────────────────
  bool _sitesLoading = true;
  String? _sitesError;
  List<ClientSite> _sites = [];

  bool _locationLoading = true;
  String? _locationError;
  LocationResult? _location;

  bool _cameraReady = false;
  String? _cameraError;

  // ── Selection / validation state ───────────────────────────────────────────
  ClientSite? _selectedSite;
  double? _distance; // meters from selected site

  bool get _isWithinGeofence =>
      _selectedSite != null &&
      _distance != null &&
      _distance! <= _selectedSite!.radiusMeters;

  // ── Submit state ───────────────────────────────────────────────────────────
  bool _isSubmitting = false;

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

  // ── Loaders ────────────────────────────────────────────────────────────────

  Future<void> _loadSites() async {
    try {
      final dio = ref.read(dioClientProvider).dio;
      final response = await dio.get(ApiEndpoints.clientSitesActive);
      final list = response.data['data'] as List<dynamic>? ?? [];
      if (mounted) {
        setState(() {
          _sites = list
              .map((e) => ClientSite.fromJson(e as Map<String, dynamic>))
              .toList();
          _sitesLoading = false;
          if (_sites.isNotEmpty) {
            // Preselect the requested site (geofence prompt), else the first.
            _selectedSite = _sites.firstWhere(
              (s) => s.id == widget.initialSiteId,
              orElse: () => _sites.first,
            );
          } else {
            _selectedSite = null;
          }
          _recomputeDistance();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _sitesError = 'Could not load client sites.';
          _sitesLoading = false;
        });
      }
    }
  }

  Future<void> _loadLocation() async {
    try {
      final loc = await _locationService.getCurrentPosition();
      if (mounted) {
        setState(() {
          _location = loc;
          _locationLoading = false;
          _recomputeDistance();
        });
      }
    } on LocationPermissionDeniedException catch (e) {
      if (mounted) {
        setState(() {
          _locationError = e.message;
          _locationLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _locationError = 'Could not get your location.';
          _locationLoading = false;
        });
      }
    }
  }

  Future<void> _initCamera() async {
    try {
      await _cameraService.initialize();
      if (mounted) setState(() => _cameraReady = true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _cameraError = 'Camera unavailable: $e';
        });
      }
    }
  }

  void _recomputeDistance() {
    if (_selectedSite == null || _location == null) {
      _distance = null;
      return;
    }
    _distance = Geolocator.distanceBetween(
      _location!.latitude,
      _location!.longitude,
      _selectedSite!.latitude,
      _selectedSite!.longitude,
    );
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (_selectedSite == null) {
      _showSnack('Please select a client site.');
      return;
    }
    if (_location == null) {
      _showSnack('Location not available. Please wait or retry.');
      return;
    }
    if (!_isWithinGeofence) {
      final dist = _distance?.toStringAsFixed(0) ?? '?';
      _showSnack(
          'You are ${dist}m from the site. Must be within ${_selectedSite!.radiusMeters}m.');
      return;
    }

    setState(() => _isSubmitting = true);

    String selfieBase64;
    try {
      selfieBase64 = await _cameraService.captureAndEncode();
    } catch (e) {
      if (mounted) setState(() => _isSubmitting = false);
      _showSnack('Could not capture selfie: $e');
      return;
    }

    final result = await ref.read(punchProvider.notifier).punch(
      'ClientSite',
      extras: {
        'clientSiteId': _selectedSite!.id,
        'latitude': _location!.latitude,
        'longitude': _location!.longitude,
        'selfieBase64': selfieBase64,
        'direction': widget.direction,
      },
    );

    if (!mounted) return;
    setState(() => _isSubmitting = false);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
          result.message ?? (result.success ? 'Check-in recorded!' : 'Check-in failed')),
      backgroundColor:
          result.success ? AppColors.success : AppColors.error,
    ));

    if (result.success) Navigator.pop(context);
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Client Site Check-in'),
        leading: const CloseButton(),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Site selector ───────────────────────────────────────────
              _SectionLabel('Select Site'),
              const SizedBox(height: 8),
              _buildSiteDropdown(theme),
              const SizedBox(height: 20),

              // ── GPS status ──────────────────────────────────────────────
              _SectionLabel('Your Location'),
              const SizedBox(height: 8),
              _buildLocationCard(theme),
              const SizedBox(height: 20),

              // ── Camera preview ──────────────────────────────────────────
              _SectionLabel('Selfie'),
              const SizedBox(height: 8),
              _buildCameraPreview(theme),
              const SizedBox(height: 28),

              // ── Submit ──────────────────────────────────────────────────
              _buildSubmitButton(theme),
            ],
          ),
        ),
      ),
    );
  }

  // ── Section widgets ────────────────────────────────────────────────────────

  Widget _buildSiteDropdown(ThemeData theme) {
    if (_sitesLoading) {
      return const _CardSkeleton(height: 56);
    }
    if (_sitesError != null) {
      return _ErrorCard(
          message: _sitesError!, onRetry: _loadSites);
    }
    if (_sites.isEmpty) {
      return _InfoCard(
        icon: Icons.business_outlined,
        message: 'No active client sites found.',
      );
    }

    return DropdownButtonFormField<ClientSite>(
      initialValue: _selectedSite,
      isExpanded: true,
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.business_outlined),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      ),
      items: _sites
          .map((s) => DropdownMenuItem(
                value: s,
                child: Text(
                  s.displayName,
                  overflow: TextOverflow.ellipsis,
                ),
              ))
          .toList(),
      onChanged: (site) => setState(() {
        _selectedSite = site;
        _recomputeDistance();
      }),
    );
  }

  Widget _buildLocationCard(ThemeData theme) {
    if (_locationLoading) return const _CardSkeleton(height: 72);
    if (_locationError != null) {
      return _ErrorCard(message: _locationError!, onRetry: _loadLocation);
    }

    final isDark = theme.brightness == Brightness.dark;
    final loc = _location!;
    final withinGeofence = _isWithinGeofence;
    final dist = _distance;
    final statusColor = withinGeofence
        ? AppColors.getSuccess(isDark)
        : AppColors.getError(isDark);
    final textSecondary = isDark
        ? AppColors.darkTextSecondary
        : AppColors.textSecondary;
    final borderColor = dist == null
        ? (isDark ? AppColors.darkBorder : AppColors.border)
        : statusColor.withAlpha(isDark ? 60 : 30);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Coordinates
          Row(
            children: [
              Icon(Icons.location_on, size: 16, color: textSecondary),
              const SizedBox(width: 6),
              Text(
                '${loc.latitude.toStringAsFixed(5)}°, '
                '${loc.longitude.toStringAsFixed(5)}°',
                style: theme.textTheme.bodyMedium,
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() {
                  _locationLoading = true;
                  _distance = null;
                  _loadLocation();
                }),
                child: Icon(Icons.refresh, size: 16, color: textSecondary),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Geofence status
          if (dist != null && _selectedSite != null)
            Row(
              children: [
                Icon(
                  withinGeofence ? Icons.check_circle : Icons.cancel,
                  size: 16,
                  color: statusColor,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    withinGeofence
                        ? 'Within site geofence (${dist.toStringAsFixed(0)}m)'
                        : '${dist.toStringAsFixed(0)}m from site — must be within '
                            '${_selectedSite!.radiusMeters}m',
                    style: TextStyle(
                      fontSize: 12,
                      color: statusColor,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildCameraPreview(ThemeData theme) {
    const previewHeight = 200.0;

    if (_cameraError != null) {
      return _InfoCard(
        icon: Icons.camera_alt_outlined,
        message: _cameraError!,
        isError: true,
      );
    }

    if (!_cameraReady) {
      return const _CardSkeleton(height: previewHeight);
    }

    final controller = _cameraService.controller!;
    final previewSize = controller.value.previewSize!;
    final isPortrait =
        MediaQuery.of(context).orientation == Orientation.portrait;

    // The camera sensor reports LANDSCAPE dimensions (width > height).
    // CameraPreview is itself an AspectRatio widget that, in portrait,
    // displays the flipped ratio (1/aspectRatio) and rotates the texture on
    // Android. Sizing this container to the camera's natural display dims
    // keeps that internal AspectRatio from fighting us, so the FittedBox can
    // cover-crop uniformly — no stretching, no blank bars.
    final cameraWidth = isPortrait ? previewSize.height : previewSize.width;
    final cameraHeight = isPortrait ? previewSize.width : previewSize.height;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: double.infinity,
        height: previewHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Camera preview — child box matches the camera's native display
            // aspect; FittedBox cover-crops it to fill the fixed-height box.
            FittedBox(
              fit: BoxFit.cover,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: cameraWidth,
                height: cameraHeight,
                child: CameraPreview(controller),
              ),
            ),
            // Oval face guide overlay
            CustomPaint(painter: _OvalHint()),
          ],
        ),
      ),
    );
  }

  Widget _buildSubmitButton(ThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    final canSubmit = _selectedSite != null &&
        _location != null &&
        _isWithinGeofence &&
        _cameraReady &&
        !_isSubmitting;

    return ElevatedButton.icon(
      onPressed: canSubmit ? _submit : null,
      icon: _isSubmitting
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : const Icon(Icons.photo_camera),
      label: Text(
        _isSubmitting
            ? 'Recording check-in…'
            : _actionLabel,
        style: const TextStyle(
            fontSize: 15, fontWeight: FontWeight.w600),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: _buttonColor(isDark),
        foregroundColor: Colors.white,
        minimumSize: const Size(double.infinity, 52),
        disabledBackgroundColor:
            isDark ? AppColors.darkBorder : AppColors.border,
      ),
    );
  }

  String get _actionLabel => switch (widget.direction) {
        'In' => 'CHECK IN AT CLIENT',
        'Out' => 'CHECK OUT AT CLIENT',
        _ => 'CONFIRM AT CLIENT SITE',
      };

  Color _buttonColor(bool isDark) => switch (widget.direction) {
        'Out' => AppColors.getError(isDark),
        _ => AppColors.getSuccess(isDark),
      };
}

// ── Oval hint painter ─────────────────────────────────────────────────────────

class _OvalHint extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.42;
    final rx = size.width * 0.32;
    final ry = size.height * 0.42;

    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(cx, cy), width: rx * 2, height: ry * 2),
      Paint()
        ..color = Colors.white.withAlpha(180)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_OvalHint old) => false;
}

// ── Small helpers ─────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Text(
      text,
      style: Theme.of(context)
          .textTheme
          .labelMedium
          ?.copyWith(color: isDark ? AppColors.darkTextSecondary : AppColors.textSecondary),
    );
  }
}

class _CardSkeleton extends StatelessWidget {
  final double height;
  const _CardSkeleton({required this.height});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.graySubtle,
        borderRadius: BorderRadius.circular(10),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final String message;
  final bool isError;

  const _InfoCard(
      {required this.icon, required this.message, this.isError = false});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = isError
        ? AppColors.getError(isDark)
        : isDark
            ? AppColors.darkTextSecondary
            : AppColors.textSecondary;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withAlpha(isDark ? 25 : 20),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message,
                style: TextStyle(color: color, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorCard({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final error = AppColors.getError(isDark);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: error.withAlpha(isDark ? 25 : 20),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: error, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: TextStyle(color: error, fontSize: 12)),
          ),
          TextButton(
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
