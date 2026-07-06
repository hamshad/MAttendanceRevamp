import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/camera_service.dart';
import '../services/location_service.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../../core/theme/app_colors.dart';

class SelfiePunchScreen extends ConsumerStatefulWidget {
  final String direction;

  const SelfiePunchScreen({super.key, required this.direction});

  @override
  ConsumerState<SelfiePunchScreen> createState() => _SelfiePunchScreenState();
}

class _SelfiePunchScreenState extends ConsumerState<SelfiePunchScreen> {
  final _cameraService = CameraService();
  final _locationService = LocationService();

  bool _isInitializing = true;
  String? _initError;

  // After capture: store base64 for preview/confirm step
  String? _capturedBase64;
  bool _isSubmitting = false;

  // Location state — fetched in parallel with camera init
  double? _lat;
  double? _lng;
  String? _address;
  bool _locationLoading = true;
  String? _locationError;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _fetchLocation(); // start in parallel — ready by the time user confirms
  }

  Future<void> _initCamera() async {
    try {
      await _cameraService.initialize();
      if (mounted) setState(() => _isInitializing = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _initError = 'Camera error: ${e.toString()}';
        });
      }
    }
  }

  Future<void> _fetchLocation() async {
    if (mounted) setState(() { _locationLoading = true; _locationError = null; _address = null; });
    try {
      final pos = await _locationService.getCurrentPosition()
          .timeout(const Duration(seconds: 15));
      // Reverse-geocode in parallel — best effort, doesn't block punch
      final address = await _locationService.getAddressFromCoordinates(
        pos.latitude, pos.longitude,
      );
      if (mounted) {
        setState(() {
          _lat = pos.latitude;
          _lng = pos.longitude;
          _address = address;
          _locationLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _locationLoading = false;
          _locationError = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  Future<void> _capture() async {
    try {
      final base64 = await _cameraService.captureAndEncode();
      if (mounted) setState(() => _capturedBase64 = base64);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Capture failed: $e'), backgroundColor: AppColors.error),
      );
    }
  }

  void _retake() => setState(() => _capturedBase64 = null);

  Future<void> _submit() async {
    setState(() => _isSubmitting = true);

    final extras = <String, dynamic>{
      'selfieBase64': _capturedBase64,
      'direction': widget.direction,
      'latitude': _lat,
      'longitude': _lng,
      if (_address != null) 'address': _address,
    };

    final result = await ref.read(punchProvider.notifier).punch('Selfie', extras: extras);

    if (!mounted) return;
    setState(() => _isSubmitting = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(result.message ?? (result.success ? 'Punch recorded!' : 'Punch failed')),
        backgroundColor: result.success ? AppColors.success : AppColors.error,
      ),
    );

    if (result.success) Navigator.pop(context);
  }

  @override
  void dispose() {
    _cameraService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('Selfie ${_dirLabel(widget.direction)}'),
        leading: const CloseButton(),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isInitializing) return const _LoadingView();
    if (_initError != null) return _ErrorView(message: _initError!, onRetry: _initCamera);

    // Show preview or captured image
    if (_capturedBase64 != null) {
      return _ConfirmView(
        base64Image: _capturedBase64!,
        direction: widget.direction,
        isSubmitting: _isSubmitting,
        locationLoading: _locationLoading,
        locationError: _locationError,
        lat: _lat,
        lng: _lng,
        address: _address,
        onRetake: _retake,
        onConfirm: _submit,
        onRetryLocation: _fetchLocation,
      );
    }

    return _CameraView(
      controller: _cameraService.controller!,
      onCapture: _capture,
    );
  }

  String _dirLabel(String dir) => switch (dir) {
        'In' => 'Punch In',
        'Out' => 'Punch Out',
        _ => dir,
      };
}

// ── Camera preview ────────────────────────────────────────────────────────────

class _CameraView extends StatelessWidget {
  final CameraController controller;
  final VoidCallback onCapture;

  const _CameraView({required this.controller, required this.onCapture});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview fills screen
        CameraPreview(controller),

        // Face oval guide overlay
        CustomPaint(painter: _OvalGuidePainter()),

        // Controls at bottom
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
            color: Colors.black.withAlpha(140),
            child: Column(
              children: [
                const Text(
                  'Position your face in the oval',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: onCapture,
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                    child: Center(
                      child: Container(
                        width: 58,
                        height: 58,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ── Oval guide painter ────────────────────────────────────────────────────────

class _OvalGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.38;
    final rx = size.width * 0.36;
    final ry = size.height * 0.28;

    // Dim everything outside the oval
    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2))
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(path, Paint()..color = Colors.black.withAlpha(100));

    // Oval border
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2),
      Paint()
        ..color = Colors.white.withAlpha(200)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── Confirm view (after capture) ──────────────────────────────────────────────

class _ConfirmView extends StatelessWidget {
  final String base64Image;
  final String direction;
  final bool isSubmitting;
  final bool locationLoading;
  final String? locationError;
  final double? lat;
  final double? lng;
  final String? address;
  final VoidCallback onRetake;
  final VoidCallback onConfirm;
  final VoidCallback onRetryLocation;

  const _ConfirmView({
    required this.base64Image,
    required this.direction,
    required this.isSubmitting,
    required this.locationLoading,
    required this.locationError,
    required this.lat,
    required this.lng,
    required this.address,
    required this.onRetake,
    required this.onConfirm,
    required this.onRetryLocation,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Show captured image as background
        // (decode base64 → MemoryImage)
        Image.memory(
          Uri.parse('data:image/jpeg;base64,$base64Image')
              .data!
              .contentAsBytes(),
          fit: BoxFit.cover,
        ),

        // Dark overlay + buttons at bottom
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 48),
            color: Colors.black.withAlpha(160),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Location status badge ──
                _LocationBadge(
                  loading: locationLoading,
                  error: locationError,
                  lat: lat,
                  lng: lng,
                  address: address,
                  onRetry: onRetryLocation,
                ),
                const SizedBox(height: 14),
                // ── Action buttons ──
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: isSubmitting ? null : onRetake,
                        icon: const Icon(Icons.refresh, color: Colors.white),
                        label: const Text('Retake', style: TextStyle(color: Colors.white)),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.white54),
                          minimumSize: const Size(0, 48),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ElevatedButton.icon(
                        // Block confirm while location is loading or errored
                        onPressed: (isSubmitting || locationLoading || locationError != null)
                            ? null
                            : onConfirm,
                        icon: isSubmitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.check),
                        label: Text(isSubmitting ? 'Sending...' : _dirLabel(direction)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _dirColor(direction),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 48),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _dirLabel(String dir) => switch (dir) {
        'In' => 'Punch In',
        'Out' => 'Punch Out',
        _ => 'Confirm',
      };

  Color _dirColor(String dir) => switch (dir) {
        'In' => AppColors.success,
        'Out' => AppColors.error,
        _ => AppColors.info,
      };
}

// ── Location badge ────────────────────────────────────────────────────────────

class _LocationBadge extends StatelessWidget {
  final bool loading;
  final String? error;
  final double? lat;
  final double? lng;
  final String? address;
  final VoidCallback onRetry;

  const _LocationBadge({
    required this.loading,
    required this.error,
    required this.lat,
    required this.lng,
    required this.address,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          SizedBox(
            width: 12, height: 12,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
          ),
          SizedBox(width: 8),
          Text('Getting location…', style: TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      );
    }

    if (error != null) {
      return GestureDetector(
        onTap: onRetry,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_off, color: AppColors.error, size: 14),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'Location unavailable — tap to retry',
                style: TextStyle(color: AppColors.error, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    // Address on first line (if available), coordinates on second line
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_on, color: AppColors.success, size: 14),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                address ?? '${lat!.toStringAsFixed(5)}, ${lng!.toStringAsFixed(5)}',
                style: TextStyle(color: AppColors.success, fontSize: 12, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
              ),
            ),
          ],
        ),
        if (address != null) ...[
          const SizedBox(height: 2),
          Text(
            '${lat!.toStringAsFixed(5)}, ${lng!.toStringAsFixed(5)}',
            style: const TextStyle(color: Colors.white38, fontSize: 10),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
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
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 16),
          Text('Starting camera...', style: TextStyle(color: Colors.white70)),
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
            const Icon(Icons.camera_alt_outlined, size: 64, color: Colors.white38),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, color: Colors.white),
              label: const Text('Try Again', style: TextStyle(color: Colors.white)),
              style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.white38)),
            ),
          ],
        ),
      ),
    );
  }
}
