import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/api/api_endpoints.dart';

import '../services/camera_service.dart';
import '../services/face_service.dart';
import '../../dashboard/providers/dashboard_providers.dart';

// ── State machine ─────────────────────────────────────────────────────────────

enum _FaceState { idle, detecting, submitting, error, notEnrolled }

// ── Screen ────────────────────────────────────────────────────────────────────

class FaceRecogScreen extends ConsumerStatefulWidget {
  final String direction;

  const FaceRecogScreen({super.key, required this.direction});

  @override
  ConsumerState<FaceRecogScreen> createState() => _FaceRecogScreenState();
}

class _FaceRecogScreenState extends ConsumerState<FaceRecogScreen> {
  final _cameraService = CameraService();
  final _faceService = FaceService();

  _FaceState _state = _FaceState.idle;
  String? _errorMessage;
  bool _isInitializing = true;
  String? _initError;
  bool _isFaceEnrolled = false;

  @override
  void initState() {
    super.initState();
    _checkEnrollmentAndInit();
  }

  @override
  void dispose() {
    _cameraService.dispose();
    _faceService.close();
    super.dispose();
  }

  /// Check if user has enrolled their face, then initialize camera
  Future<void> _checkEnrollmentAndInit() async {
    try {
      final dio = ref.read(dioClientProvider).dio;
      final response = await dio.get(ApiEndpoints.myFaceData);

      // Response: { data: [ { id, employeeId, algorithm, isActive, createdAt } ] }
      final wrapper = response.data as Map<String, dynamic>?;
      final list = (wrapper?['data'] as List?) ?? [];
      final active = list.where((e) => (e as Map)['isActive'] == true).toList();

      _isFaceEnrolled = active.isNotEmpty;

      if (_isFaceEnrolled) {
        // Face is enrolled — proceed with camera initialization
        await _initCamera();
      } else {
        // Face is NOT enrolled — show enrollment prompt
        if (mounted) {
          setState(() {
            _state = _FaceState.notEnrolled;
            _isInitializing = false;
          });
        }
      }
    } catch (e) {
      // Network error on enrollment check — assume not enrolled to be safe
      if (mounted) {
        setState(() {
          _state = _FaceState.notEnrolled;
          _isInitializing = false;
        });
      }
    }
  }

  Future<void> _initCamera() async {
    try {
      await _cameraService.initialize();
      if (mounted) setState(() => _isInitializing = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _initError = 'Camera error: $e';
        });
      }
    }
  }

  Future<void> _verifyAndPunch() async {
    if (_state != _FaceState.idle) return;

    setState(() {
      _state = _FaceState.detecting;
      _errorMessage = null;
    });

    String? embeddingBase64;
    try {
      final xFile = await _cameraService.controller!.takePicture();
      final result = await _faceService.detectAndExtract(xFile.path);
      embeddingBase64 = base64Encode(result.embedding);
    } on NoFaceException catch (e) {
      _setError(e.toString());
      return;
    } on MultipleFacesException catch (e) {
      _setError(e.toString());
      return;
    } on FaceAngleException catch (e) {
      _setError(e.toString());
      return;
    } catch (e) {
      _setError('Face detection failed: $e');
      return;
    }

    setState(() => _state = _FaceState.submitting);

    final result = await ref
        .read(punchProvider.notifier)
        .punch(
          'FaceRecog',
          extras: {
            'faceEmbedding': embeddingBase64,
            'direction': widget.direction,
          },
        );

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.message ??
              (result.success ? 'Punch recorded!' : 'Punch failed'),
        ),
        backgroundColor: result.success ? AppColors.success : AppColors.error,
      ),
    );

    if (result.success) {
      Navigator.pop(context);
    } else {
      _setError(result.message ?? 'Face match rejected by server.');
    }
  }

  void _setError(String msg) {
    if (!mounted) return;
    setState(() {
      _state = _FaceState.error;
      _errorMessage = msg;
    });
  }

  void _retry() => setState(() {
    _state = _FaceState.idle;
    _errorMessage = null;
  });

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('Face Recognition ${_dirLabel(widget.direction)}'),
        leading: const CloseButton(),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isInitializing)
      return const _LoadingView(message: 'Checking face enrollment…');
    if (_state == _FaceState.notEnrolled) {
      return _NotEnrolledView(
        direction: widget.direction,
        onNavigateToEnrollment: () async {
          Navigator.pop(context);
          // Optionally navigate to face enrollment after closing
        },
      );
    }
    if (_initError != null) {
      return _ErrorView(message: _initError!, onRetry: _initCamera);
    }
    return _CameraView(
      controller: _cameraService.controller!,
      state: _state,
      errorMessage: _errorMessage,
      direction: widget.direction,
      onVerify: _verifyAndPunch,
      onRetry: _retry,
    );
  }

  String _dirLabel(String dir) => switch (dir) {
    'In' => 'Punch In',
    'Out' => 'Punch Out',
    'BreakStart' => 'Break Start',
    'BreakEnd' => 'Break End',
    _ => dir,
  };
}

// ── Camera view ───────────────────────────────────────────────────────────────

class _CameraView extends StatelessWidget {
  final CameraController controller;
  final _FaceState state;
  final String? errorMessage;
  final String direction;
  final VoidCallback onVerify;
  final VoidCallback onRetry;

  const _CameraView({
    required this.controller,
    required this.state,
    required this.errorMessage,
    required this.direction,
    required this.onVerify,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final isBusy =
        state == _FaceState.detecting || state == _FaceState.submitting;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview fills screen
        CameraPreview(controller),

        // Oval guide + dim overlay
        CustomPaint(
          painter: _OvalGuidePainter(hasError: state == _FaceState.error),
        ),

        // Status badge (top-center, inside oval area)
        Positioned(
          top: MediaQuery.of(context).size.height * 0.07,
          left: 0,
          right: 0,
          child: _StatusBadge(state: state, errorMessage: errorMessage),
        ),

        // Bottom control area
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
                  _guideText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 20),
                if (state == _FaceState.error)
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Try Again'),
                          style: ElevatedButton.styleFrom(
                            minimumSize: const Size(0, 48),
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  ElevatedButton.icon(
                    onPressed: isBusy ? null : onVerify,
                    icon: isBusy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.face_retouching_natural),
                    label: Text(isBusy ? _busyLabel : _actionLabel),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _buttonColor,
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

  String get _guideText => state == _FaceState.error
      ? errorMessage ?? 'Verification failed.'
      : 'Position your face in the oval';

  String get _actionLabel => switch (direction) {
    'In' => 'VERIFY & PUNCH IN',
    'Out' => 'VERIFY & PUNCH OUT',
    'BreakStart' => 'VERIFY & START BREAK',
    'BreakEnd' => 'VERIFY & END BREAK',
    _ => 'VERIFY & PUNCH',
  };

  String get _busyLabel =>
      state == _FaceState.detecting ? 'Detecting face…' : 'Verifying…';

  Color get _buttonColor => switch (direction) {
    'Out' => AppColors.error,
    'BreakStart' => AppColors.warning,
    'BreakEnd' => AppColors.warning,
    _ => AppColors.success,
  };
}

// ── Status badge ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final _FaceState state;
  final String? errorMessage;

  const _StatusBadge({required this.state, required this.errorMessage});

  @override
  Widget build(BuildContext context) {
    final (icon, label, color) = switch (state) {
      _FaceState.idle => (
        Icons.face_outlined,
        'Position face in oval',
        Colors.white70,
      ),
      _FaceState.detecting => (Icons.search, 'Detecting face…', AppColors.info),
      _FaceState.submitting => (
        Icons.check_circle_outline,
        'Face detected — matching…',
        AppColors.success,
      ),
      _FaceState.error => (
        Icons.warning_amber_rounded,
        'Try again',
        AppColors.error,
      ),
      _FaceState.notEnrolled => (
        Icons.face_unlock_outlined,
        'Enroll face first',
        AppColors.warning,
      ),
    };

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha(140),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(color: color, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

// ── Oval guide painter ────────────────────────────────────────────────────────

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

    // Oval border — green when matching, red on error, white otherwise
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

// ── Loading / Error ───────────────────────────────────────────────────────────

class _LoadingView extends StatelessWidget {
  final String message;

  const _LoadingView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Colors.white),
          const SizedBox(height: 16),
          Text(message, style: const TextStyle(color: Colors.white70)),
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
            const Icon(
              Icons.camera_alt_outlined,
              size: 64,
              color: Colors.white38,
            ),
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
              label: const Text(
                'Try Again',
                style: TextStyle(color: Colors.white),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white38),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Not Enrolled View ─────────────────────────────────────────────────────────

class _NotEnrolledView extends StatelessWidget {
  final String direction;
  final VoidCallback onNavigateToEnrollment;

  const _NotEnrolledView({
    required this.direction,
    required this.onNavigateToEnrollment,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.warning.withAlpha(30),
              ),
              child: Icon(
                Icons.face_outlined,
                size: 48,
                color: AppColors.warning,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Face Not Enrolled',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'You need to enroll your face first before using face recognition punch.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                // Close this screen and let user navigate to settings to enroll
              },
              icon: const Icon(Icons.person_add),
              label: const Text('Go Back & Enroll Face'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.warning,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 52),
                textStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                Navigator.pop(context);
              },
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white38),
                minimumSize: const Size(double.infinity, 48),
              ),
              child: const Text(
                'Cancel',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
