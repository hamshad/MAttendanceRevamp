import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../dashboard/widgets/punch_button.dart';
import '../../../core/theme/app_colors.dart';
import '../../../models/attendance.dart';
import '../widgets/gps_verification_view.dart';
import '../widgets/wifi_verification_view.dart';
import '../widgets/qr_verification_view.dart';
import '../widgets/selfie_verification_view.dart';
import '../widgets/client_site_verification_view.dart';
import '../services/camera_service.dart';
import '../services/face_service.dart';

class PunchFlowScreen extends ConsumerStatefulWidget {
  const PunchFlowScreen({super.key});

  @override
  ConsumerState<PunchFlowScreen> createState() => _PunchFlowScreenState();
}

class _PunchFlowScreenState extends ConsumerState<PunchFlowScreen> {
  // Store verification data from views
  dynamic _verificationData;
  String? _qrErrorMessage;
  bool _isProcessing = false;

  @override
  Widget build(BuildContext context) {
    final selectedMethod = ref.watch(selectedMethodProvider);
    final statusAsync = ref.watch(attendanceStatusProvider);
    final permissionsAsync = ref.watch(accessPermissionsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Punch Verification'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: statusAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (status) => Column(
          children: [
            // Top Area: Dynamic Verification View
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: _buildVerificationView(selectedMethod),
              ),
            ),

            // Bottom Area: Persistent Controls
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(20),
                    blurRadius: 10,
                    offset: const Offset(0, -5),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Method Selector
                  permissionsAsync.maybeWhen(
                    data: (perms) => MethodSelector(permissions: perms),
                    orElse: () => const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 24),

                  // Punch Button
                  PunchButton(
                    status: status,
                    isFlowMode: true,
                    onPunchPressed: () => _handlePunch(selectedMethod, status),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerificationView(String method) {
    switch (method) {
      case 'GPS':
      case 'GeofenceAuto':
        return const GPSVerificationView();
      case 'ClientSite':
        return ClientSiteVerificationView(
          onDataChanged: (data) => _verificationData = data,
        );
      case 'WiFi':
        return const WiFiVerificationView();
      case 'QRCode':
        return QRVerificationView(
          onScan: (token) {
            _verificationData = token;
            _handlePunch('QRCode', ref.read(attendanceStatusProvider).value);
          },
          isProcessing: _isProcessing,
          errorMessage: _qrErrorMessage,
        );
      case 'Selfie':
        return SelfieVerificationView(
          onCaptured: (base64, lat, lng, addr) {
            _verificationData = {
              'selfieBase64': base64,
              'latitude': lat,
              'longitude': lng,
              'address': addr,
            };
          },
          isSubmitting: _isProcessing,
        );
      case 'FaceRecog':
        return FaceVerificationView(
          onFaceEmbeddingExtracted: (embedding) {
            _verificationData = {'faceEmbedding': embedding};
          },
          isSubmitting: _isProcessing,
        );
      default:
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.touch_app_outlined,
                size: 64,
                color: AppColors.gray,
              ),
              const SizedBox(height: 16),
              Text(
                'Verify via $method',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Ready to punch',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        );
    }
  }

  Future<void> _handlePunch(String method, EmployeeStatus? status) async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);
    _qrErrorMessage = null;

    final direction = _resolveDirection(status);
    final extras = <String, dynamic>{'direction': direction};

    // Gather data based on method
    if (method == 'GPS' || method == 'GeofenceAuto') {
      final loc = ref.read(gpsLocationProvider).valueOrNull;
      if (loc != null) {
        extras['latitude'] = loc.latitude;
        extras['longitude'] = loc.longitude;
      }
    } else if (method == 'WiFi') {
      final wifi = ref.read(wifiInfoProvider).valueOrNull;
      if (wifi != null) {
        extras['wifiSSID'] = wifi.ssid;
        extras['wifiMAC'] = wifi.bssid;
      }
    } else if (method == 'QRCode') {
      extras['qrCodeToken'] = _verificationData;
    } else if (method == 'Selfie') {
      if (_verificationData != null) {
        extras.addAll(_verificationData as Map<String, dynamic>);
      }
    } else if (method == 'FaceRecog') {
      if (_verificationData != null) {
        // FaceRecog sends face embedding (base64 encoded) for backend matching
        final data = _verificationData as Map<String, dynamic>;
        if (data.containsKey('faceEmbedding')) {
          extras['faceEmbedding'] = data['faceEmbedding'];
        }
      }
    } else if (method == 'ClientSite') {
      if (_verificationData != null) {
        final data = _verificationData as Map<String, dynamic>;
        final cameraService = data['cameraService'] as CameraService?;
        if (cameraService != null) {
          try {
            final base64 = await cameraService.captureAndEncode();
            extras['selfieBase64'] = base64;
          } catch (_) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Selfie capture failed'),
                backgroundColor: AppColors.error,
              ),
            );
            setState(() => _isProcessing = false);
            return;
          }
        }
        extras['clientSiteId'] = data['clientSiteId'];
        extras['latitude'] = data['latitude'];
        extras['longitude'] = data['longitude'];
      }
    }

    final result = await ref
        .read(punchProvider.notifier)
        .punch(method, extras: extras);

    if (!mounted) return;
    setState(() => _isProcessing = false);

    if (result.success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.message ?? 'Punch Success'),
          backgroundColor: AppColors.success,
        ),
      );
      Navigator.pop(context);
    } else {
      if (method == 'QRCode') {
        setState(() => _qrErrorMessage = result.message);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result.message ?? 'Punch Failed'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  String _resolveDirection(EmployeeStatus? status) {
    if (status?.isOnBreak ?? false) return 'BreakEnd';
    if (status?.isPunchedIn ?? false) return 'Out';
    return 'In';
  }
}

// ── Face Verification View ────────────────────────────────────────────────────

class FaceVerificationView extends ConsumerStatefulWidget {
  final Function(String) onFaceEmbeddingExtracted;
  final bool isSubmitting;

  const FaceVerificationView({
    required this.onFaceEmbeddingExtracted,
    required this.isSubmitting,
  });

  @override
  ConsumerState<FaceVerificationView> createState() =>
      _FaceVerificationViewState();
}

class _FaceVerificationViewState extends ConsumerState<FaceVerificationView> {
  final _cameraService = CameraService();
  final _faceService = FaceService();

  String? _errorMessage;
  bool _isDetecting = false;
  bool _isCameraInitialized = false;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  @override
  void dispose() {
    _cameraService.dispose();
    _faceService.close();
    super.dispose();
  }

  Future<void> _initCamera() async {
    try {
      await _cameraService.initialize();
      if (mounted) setState(() => _isCameraInitialized = true);
    } catch (e) {
      if (mounted) {
        setState(() => _initError = 'Camera error: $e');
      }
    }
  }

  Future<void> _captureAndExtractFace() async {
    if (_isDetecting || widget.isSubmitting || !_isCameraInitialized) return;

    setState(() {
      _isDetecting = true;
      _errorMessage = null;
    });

    try {
      final xFile = await _cameraService.controller!.takePicture();
      final result = await _faceService.detectAndExtract(xFile.path);

      if (mounted) {
        // Convert embedding to base64 and pass to parent
        final embeddingBase64 = base64Encode(result.embedding);
        widget.onFaceEmbeddingExtracted(embeddingBase64);
      }
    } on NoFaceException catch (e) {
      _setError(e.toString());
    } on MultipleFacesException catch (e) {
      _setError(e.toString());
    } on FaceAngleException catch (e) {
      _setError(e.toString());
    } catch (e) {
      _setError('Face detection failed: $e');
    }

    if (mounted) setState(() => _isDetecting = false);
  }

  void _setError(String msg) {
    if (!mounted) return;
    setState(() => _errorMessage = msg);
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.camera_alt_outlined,
                size: 64,
                color: Colors.grey,
              ),
              const SizedBox(height: 16),
              Text(
                _initError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _initCamera,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (!_isCameraInitialized) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Starting camera…', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    final isBusy = _isDetecting || widget.isSubmitting;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview
        CameraPreview(_cameraService.controller!),

        // Oval guide + dim overlay
        CustomPaint(
          painter: _OvalGuidePainter(hasError: _errorMessage != null),
        ),

        // Status badge
        Positioned(
          top: MediaQuery.of(context).size.height * 0.07,
          left: 0,
          right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(140),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _errorMessage != null ? Icons.warning : Icons.face_outlined,
                    color: _errorMessage != null
                        ? Colors.orange
                        : Colors.white70,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _errorMessage ?? 'Position face in oval',
                    style: TextStyle(
                      color: _errorMessage != null
                          ? Colors.orange
                          : Colors.white70,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Bottom controls
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            color: Colors.black.withAlpha(160),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _errorMessage ?? 'Position your face in the oval',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: isBusy ? null : _captureAndExtractFace,
                  icon: isBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.camera_alt),
                  label: Text(isBusy ? 'Detecting…' : 'Capture Face'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 52),
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
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

// ── Oval guide painter (same as FaceRecogScreen) ────────────────────────────

class _OvalGuidePainter extends CustomPainter {
  final bool hasError;

  const _OvalGuidePainter({this.hasError = false});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.38;
    final rx = size.width * 0.36;
    final ry = size.height * 0.28;
    final ovalRect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: rx * 2,
      height: ry * 2,
    );

    // Dim everything outside the oval
    final cutout = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(ovalRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(cutout, Paint()..color = Colors.black.withAlpha(110));

    // Oval border
    final borderColor = hasError
        ? AppColors.error.withAlpha(200)
        : Colors.white.withAlpha(200);
    canvas.drawOval(
      ovalRect,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_OvalGuidePainter old) => old.hasError != hasError;
}
