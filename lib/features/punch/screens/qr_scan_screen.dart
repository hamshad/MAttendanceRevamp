import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../../core/theme/app_colors.dart';

class QRScanScreen extends ConsumerStatefulWidget {
  final String direction;

  const QRScanScreen({super.key, required this.direction});

  @override
  ConsumerState<QRScanScreen> createState() => _QRScanScreenState();
}

class _QRScanScreenState extends ConsumerState<QRScanScreen> {
  final MobileScannerController _scanController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  bool _isProcessing = false;
  bool _scanSuccess = false;
  String? _errorMessage;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_isProcessing) return;

    final rawValue = capture.barcodes.firstOrNull?.rawValue;
    if (rawValue == null || rawValue.isEmpty) return;

    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    await _scanController.stop();

    final result = await ref.read(punchProvider.notifier).punch(
      'QRCode',
      extras: {
        'qrCodeToken': rawValue,
        'direction': widget.direction,
      },
    );

    if (!mounted) return;

    if (result.success) {
      HapticFeedback.mediumImpact();
      setState(() => _scanSuccess = true);
      await Future.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;
      Navigator.pop(context);
    } else {
      // Show error inline and resume scanning
      setState(() {
        _isProcessing = false;
        _errorMessage = result.message ?? 'QR code invalid or expired. Try again.';
      });
      await _scanController.start();
    }
  }

  @override
  void dispose() {
    _scanController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('QR Punch ${_dirLabel(widget.direction)}'),
        leading: const CloseButton(),
        actions: [
          // Torch toggle
          IconButton(
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _scanController.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Scanner
          MobileScanner(
            controller: _scanController,
            onDetect: _onDetect,
          ),

          // Overlay with scan window
          _ScanOverlay(),

          // Status panel at top
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _StatusBanner(
              isProcessing: _isProcessing,
              errorMessage: _errorMessage,
              direction: widget.direction,
            ),
          ),

          // Success flash overlay
          if (_scanSuccess)
            AnimatedOpacity(
              opacity: _scanSuccess ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Container(
                color: AppColors.success.withAlpha(180),
                child: const Center(
                  child: Icon(Icons.check_circle_rounded,
                      color: Colors.white, size: 96),
                ),
              ),
            ),

          // Hint at bottom
          if (!_isProcessing && !_scanSuccess)
            Positioned(
              bottom: 48,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  const Icon(Icons.qr_code_scanner, color: Colors.white54, size: 28),
                  const SizedBox(height: 8),
                  Text(
                    'Point camera at the office QR code',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'QR codes expire after 5 minutes',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white.withAlpha(100), fontSize: 11),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String _dirLabel(String dir) => switch (dir) {
        'In' => 'Punch In',
        'Out' => 'Punch Out',
        _ => dir,
      };
}

// ── Scanner overlay with corner brackets ──────────────────────────────────────

class _ScanOverlay extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _OverlayPainter());
  }
}

class _OverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2 - 40;
    const halfBox = 140.0;
    const cornerLen = 24.0;
    const cornerRadius = 4.0;

    final boxRect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: halfBox * 2,
      height: halfBox * 2,
    );

    // Dim area outside the scan box
    final dimPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRect(boxRect)
      ..fillType = PathFillType.evenOdd;

    canvas.drawPath(dimPath, Paint()..color = Colors.black.withAlpha(160));

    // Corner brackets
    final cornerPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    final l = boxRect.left;
    final t = boxRect.top;
    final r = boxRect.right;
    final b = boxRect.bottom;

    // Top-left
    canvas.drawPath(
      Path()
        ..moveTo(l + cornerLen, t + cornerRadius)
        ..arcToPoint(Offset(l + cornerRadius, t + cornerLen),
            radius: const Radius.circular(cornerRadius))
        ..moveTo(l + cornerLen, t + cornerRadius)
        ..lineTo(l + cornerLen, t + cornerRadius),
      cornerPaint,
    );
    _drawCorner(canvas, cornerPaint, l, t, cornerLen, cornerRadius, 1, 1);
    _drawCorner(canvas, cornerPaint, r, t, cornerLen, cornerRadius, -1, 1);
    _drawCorner(canvas, cornerPaint, l, b, cornerLen, cornerRadius, 1, -1);
    _drawCorner(canvas, cornerPaint, r, b, cornerLen, cornerRadius, -1, -1);
  }

  void _drawCorner(
    Canvas canvas,
    Paint paint,
    double x,
    double y,
    double len,
    double r,
    double dx,
    double dy,
  ) {
    final path = Path()
      ..moveTo(x + dx * len, y)
      ..lineTo(x + dx * r, y)
      ..arcToPoint(
        Offset(x, y + dy * r),
        radius: Radius.circular(r),
        clockwise: dx * dy < 0,
      )
      ..lineTo(x, y + dy * len);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ── Status banner ─────────────────────────────────────────────────────────────

class _StatusBanner extends StatelessWidget {
  final bool isProcessing;
  final String? errorMessage;
  final String direction;

  const _StatusBanner({
    required this.isProcessing,
    required this.errorMessage,
    required this.direction,
  });

  @override
  Widget build(BuildContext context) {
    if (isProcessing) {
      return Container(
        color: Colors.black.withAlpha(180),
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(width: 12),
            Text('Processing QR code...', style: TextStyle(color: Colors.white)),
          ],
        ),
      );
    }

    if (errorMessage != null) {
      return Container(
        color: AppColors.error.withAlpha(220),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                errorMessage!,
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }
}
