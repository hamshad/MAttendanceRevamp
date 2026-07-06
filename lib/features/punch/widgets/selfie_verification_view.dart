import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import '../services/camera_service.dart';
import '../services/location_service.dart';
import '../../../core/theme/app_colors.dart';

class SelfieVerificationView extends StatefulWidget {
  final Function(String base64, double? lat, double? lng, String? address) onCaptured;
  final bool isSubmitting;

  const SelfieVerificationView({
    super.key,
    required this.onCaptured,
    required this.isSubmitting,
  });

  @override
  State<SelfieVerificationView> createState() => _SelfieVerificationViewState();
}

class _SelfieVerificationViewState extends State<SelfieVerificationView> {
  final _cameraService = CameraService();
  final _locationService = LocationService();

  bool _isInitializing = true;
  String? _initError;
  String? _capturedBase64;

  double? _lat;
  double? _lng;
  String? _address;
  bool _locationLoading = true;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _fetchLocation();
  }

  Future<void> _initCamera() async {
    try {
      await _cameraService.initialize();
      if (mounted) setState(() => _isInitializing = false);
    } catch (e) {
      if (mounted) setState(() { _isInitializing = false; _initError = e.toString(); });
    }
  }

  Future<void> _fetchLocation() async {
    try {
      final pos = await _locationService.getCurrentPosition().timeout(const Duration(seconds: 10));
      final address = await _locationService.getAddressFromCoordinates(pos.latitude, pos.longitude);
      if (mounted) setState(() { _lat = pos.latitude; _lng = pos.longitude; _address = address; _locationLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _locationLoading = false);
    }
  }

  Future<void> _capture() async {
    try {
      final base64 = await _cameraService.captureAndEncode();
      if (mounted) {
        setState(() => _capturedBase64 = base64);
        widget.onCaptured(base64, _lat, _lng, _address);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _cameraService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) return const Center(child: CircularProgressIndicator());
    if (_initError != null) return Center(child: Text(_initError!, style: const TextStyle(color: Colors.white)));

    if (_capturedBase64 != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          Image.memory(Uri.parse('data:image/jpeg;base64,$_capturedBase64').data!.contentAsBytes(), fit: BoxFit.cover),
          Positioned(
            bottom: 20,
            left: 20,
            child: IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white, size: 32),
              onPressed: () => setState(() => _capturedBase64 = null),
            ),
          ),
        ],
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_cameraService.controller!),
        CustomPaint(painter: _OvalGuidePainter()),
        Positioned(
          bottom: 40,
          left: 0,
          right: 0,
          child: Center(
            child: GestureDetector(
              onTap: _capture,
              child: Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 4)),
                child: Center(child: Container(width: 54, height: 54, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle))),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _OvalGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.4;
    final rx = size.width * 0.35;
    final ry = size.height * 0.25;
    final path = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height))..addOval(Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2))..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = Colors.black.withAlpha(120));
    canvas.drawOval(Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2), Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2);
  }
  @override
  bool shouldRepaint(CustomPainter old) => false;
}
