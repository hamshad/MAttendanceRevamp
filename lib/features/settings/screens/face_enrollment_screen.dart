import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../punch/services/camera_service.dart';
import '../../punch/services/face_service.dart';

// ── State machine ─────────────────────────────────────────────────────────────

enum _State {
  checkingStatus,
  notEnrolled,
  enrolled,
  cameraInit,
  cameraReady,
  detecting,
  submitting,
  error,
}

// ── Screen ────────────────────────────────────────────────────────────────────

class FaceEnrollmentScreen extends ConsumerStatefulWidget {
  const FaceEnrollmentScreen({super.key});

  @override
  ConsumerState<FaceEnrollmentScreen> createState() =>
      _FaceEnrollmentScreenState();
}

class _FaceEnrollmentScreenState extends ConsumerState<FaceEnrollmentScreen> {
  final _cameraService = CameraService();
  final _faceService = FaceService();

  _State _state = _State.checkingStatus;
  DateTime? _enrolledAt;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _checkEnrollment();
  }

  @override
  void dispose() {
    _cameraService.dispose();
    _faceService.close();
    super.dispose();
  }

  // ── Status check ───────────────────────────────────────────────────────────

  Future<void> _checkEnrollment() async {
    setState(() {
      _state = _State.checkingStatus;
      _errorMessage = null;
    });

    try {
      final dio = ref.read(dioClientProvider).dio;
      final response = await dio.get(ApiEndpoints.myFaceData);

      // Response: { data: [ { id, employeeId, algorithm, isActive, createdAt } ] }
      final wrapper = response.data as Map<String, dynamic>?;
      final list = (wrapper?['data'] as List?) ?? [];
      final active = list.where((e) => (e as Map)['isActive'] == true).toList();

      if (active.isNotEmpty) {
        final createdAtStr = (active.first as Map)['createdAt'] as String?;
        setState(() {
          _state = _State.enrolled;
          _enrolledAt =
              createdAtStr != null ? DateTime.tryParse(createdAtStr) : null;
        });
      } else {
        setState(() => _state = _State.notEnrolled);
      }
    } catch (_) {
      // Network error → assume not enrolled so the user can proceed
      setState(() => _state = _State.notEnrolled);
    }
  }

  // ── Camera ─────────────────────────────────────────────────────────────────

  Future<void> _openCamera() async {
    setState(() => _state = _State.cameraInit);
    try {
      await _cameraService.initialize();
      if (mounted) setState(() => _state = _State.cameraReady);
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _State.error;
          _errorMessage = 'Camera error: $e';
        });
      }
    }
  }

  Future<void> _captureAndEnroll() async {
    if (_state != _State.cameraReady) return;

    // Capture messenger before any async gap.
    final messenger = ScaffoldMessenger.of(context);

    setState(() {
      _state = _State.detecting;
      _errorMessage = null;
    });

    String embeddingBase64;
    try {
      final xFile = await _cameraService.controller!.takePicture();
      final result = await _faceService.detectAndExtract(xFile.path);
      embeddingBase64 = base64Encode(result.embedding);
    } on NoFaceException catch (e) {
      if (mounted) setState(() { _state = _State.cameraReady; _errorMessage = e.toString(); });
      return;
    } on MultipleFacesException catch (e) {
      if (mounted) setState(() { _state = _State.cameraReady; _errorMessage = e.toString(); });
      return;
    } on FaceAngleException catch (e) {
      if (mounted) setState(() { _state = _State.cameraReady; _errorMessage = e.toString(); });
      return;
    } catch (e) {
      if (mounted) setState(() { _state = _State.error; _errorMessage = 'Detection failed: $e'; });
      return;
    }

    setState(() => _state = _State.submitting);

    try {
      final dio = ref.read(dioClientProvider).dio;
      await dio.post(ApiEndpoints.myFaceData, data: {
        'faceEmbedding': embeddingBase64,
        'algorithm': 'mobilefacenet_128',
        'embeddingDimension': 128,
      });

      if (!mounted) return;

      // Dispose camera — no longer needed
      await _cameraService.dispose();

      setState(() {
        _state = _State.enrolled;
        _enrolledAt = DateTime.now();
      });

      messenger.showSnackBar(
        SnackBar(
          content: const Text('Face enrolled successfully!'),
          backgroundColor: Colors.green.shade700,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _State.error;
          _errorMessage = 'Enrollment failed. Please try again.';
        });
      }
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isCameraPhase = _state == _State.cameraInit ||
        _state == _State.cameraReady ||
        _state == _State.detecting ||
        _state == _State.submitting;

    return Scaffold(
      backgroundColor: isCameraPhase ? Colors.black : null,
      appBar: AppBar(
        backgroundColor: isCameraPhase ? Colors.black : null,
        foregroundColor: isCameraPhase ? Colors.white : null,
        title: const Text('Face Enrollment'),
        leading: const CloseButton(),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    return switch (_state) {
      _State.checkingStatus => const Center(child: CircularProgressIndicator()),
      _State.notEnrolled => _StatusView(
          isEnrolled: false,
          enrolledAt: null,
          onEnroll: _openCamera,
        ),
      _State.enrolled => _StatusView(
          isEnrolled: true,
          enrolledAt: _enrolledAt,
          onEnroll: _openCamera,
        ),
      _State.cameraInit => const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text('Starting camera…',
                  style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      _State.cameraReady ||
      _State.detecting ||
      _State.submitting =>
        _CameraView(
          controller: _cameraService.controller!,
          state: _state,
          errorMessage: _errorMessage,
          onCapture: _captureAndEnroll,
        ),
      _State.error => _ErrorView(
          message: _errorMessage ?? 'An error occurred.',
          onRetry: _checkEnrollment,
        ),
    };
  }
}

// ── Status View ───────────────────────────────────────────────────────────────

class _StatusView extends StatelessWidget {
  final bool isEnrolled;
  final DateTime? enrolledAt;
  final VoidCallback onEnroll;

  const _StatusView({
    required this.isEnrolled,
    required this.enrolledAt,
    required this.onEnroll,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 24),

          // Status card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: isEnrolled
                  ? Colors.green.shade50
                  : Colors.orange.shade50,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isEnrolled
                    ? Colors.green.shade200
                    : Colors.orange.shade200,
              ),
            ),
            child: Column(
              children: [
                Icon(
                  isEnrolled
                      ? Icons.face_retouching_natural
                      : Icons.face_outlined,
                  size: 56,
                  color: isEnrolled
                      ? Colors.green.shade600
                      : Colors.orange.shade600,
                ),
                const SizedBox(height: 12),
                Text(
                  isEnrolled ? 'Face Enrolled' : 'Not Enrolled',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: isEnrolled
                        ? Colors.green.shade700
                        : Colors.orange.shade700,
                  ),
                ),
                if (isEnrolled && enrolledAt != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Enrolled on ${_formatDate(enrolledAt!)}',
                    style: TextStyle(
                      color: Colors.green.shade600,
                      fontSize: 13,
                    ),
                  ),
                ],
                if (!isEnrolled) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Enroll your face to use Face Recognition punch.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.orange.shade700,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 32),

          // Info section
          if (!isEnrolled) ...[
            _InfoRow(
              icon: Icons.camera_alt_outlined,
              text: 'Point your face at the camera in good lighting.',
            ),
            const SizedBox(height: 10),
            _InfoRow(
              icon: Icons.face_outlined,
              text: 'Look straight at the camera — no tilting.',
            ),
            const SizedBox(height: 10),
            _InfoRow(
              icon: Icons.check_circle_outline,
              text: 'Tap "Enroll Face" and hold still while it captures.',
            ),
            const SizedBox(height: 32),
          ],

          // Action button
          ElevatedButton.icon(
            onPressed: onEnroll,
            icon: Icon(
              isEnrolled ? Icons.refresh : Icons.face_retouching_natural,
            ),
            label: Text(isEnrolled ? 'Re-Enroll Face' : 'Enroll Face'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 52),
              backgroundColor: isEnrolled
                  ? theme.colorScheme.primary
                  : Colors.green.shade600,
              foregroundColor: Colors.white,
              textStyle: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),

          if (isEnrolled) ...[
            const SizedBox(height: 12),
            Text(
              'Re-enrolling will replace your current face data.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _InfoRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Colors.grey.shade500),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

// ── Camera View ───────────────────────────────────────────────────────────────

class _CameraView extends StatelessWidget {
  final CameraController controller;
  final _State state;
  final String? errorMessage;
  final VoidCallback onCapture;

  const _CameraView({
    required this.controller,
    required this.state,
    required this.errorMessage,
    required this.onCapture,
  });

  @override
  Widget build(BuildContext context) {
    final isBusy = state == _State.detecting || state == _State.submitting;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview
        CameraPreview(controller),

        // Oval guide overlay
        CustomPaint(painter: _OvalGuidePainter()),

        // Error message above button
        if (errorMessage != null)
          Positioned(
            top: MediaQuery.of(context).size.height * 0.07,
            left: 16,
            right: 16,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.red.shade800.withAlpha(220),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      color: Colors.white, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      errorMessage!,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // Bottom controls
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
                Text(
                  isBusy
                      ? (state == _State.detecting
                          ? 'Detecting face…'
                          : 'Saving enrollment…')
                      : 'Position your face in the oval and tap Enroll',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: isBusy ? null : onCapture,
                  icon: isBusy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.face_retouching_natural),
                  label: Text(isBusy ? 'Processing…' : 'Enroll Face'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade600,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 52),
                    textStyle: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600),
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

// ── Oval guide painter (same as FaceRecogScreen) ──────────────────────────────

class _OvalGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.38;
    final rx = size.width * 0.36;
    final ry = size.height * 0.28;
    final ovalRect =
        Rect.fromCenter(center: Offset(cx, cy), width: rx * 2, height: ry * 2);

    // Dim area outside oval
    final cutout = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addOval(ovalRect)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(cutout, Paint()..color = Colors.black.withAlpha(110));

    // Oval border
    canvas.drawOval(
      ovalRect,
      Paint()
        ..color = Colors.white.withAlpha(200)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── Error view ────────────────────────────────────────────────────────────────

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
            Icon(Icons.error_outline, size: 56, color: Colors.red.shade300),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14),
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
