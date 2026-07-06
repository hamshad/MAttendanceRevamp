import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../core/theme/app_colors.dart';

class QRVerificationView extends ConsumerStatefulWidget {
  final Function(String token) onScan;
  final bool isProcessing;
  final String? errorMessage;

  const QRVerificationView({
    super.key,
    required this.onScan,
    required this.isProcessing,
    this.errorMessage,
  });

  @override
  ConsumerState<QRVerificationView> createState() => _QRVerificationViewState();
}

class _QRVerificationViewState extends ConsumerState<QRVerificationView> {
  final MobileScannerController _scanController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  @override
  void dispose() {
    _scanController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          controller: _scanController,
          onDetect: (capture) {
            final rawValue = capture.barcodes.firstOrNull?.rawValue;
            if (rawValue != null && rawValue.isNotEmpty) {
              widget.onScan(rawValue);
            }
          },
        ),
        _ScanOverlay(),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _StatusBanner(
            isProcessing: widget.isProcessing,
            errorMessage: widget.errorMessage,
          ),
        ),
        Positioned(
          bottom: 40,
          left: 0,
          right: 0,
          child: Column(
            children: [
              const Icon(Icons.qr_code_scanner, color: Colors.white54, size: 28),
              const SizedBox(height: 8),
              Text(
                'Point camera at the office QR code',
                style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 13),
              ),
            ],
          ),
        ),
        Positioned(
          top: 10,
          right: 10,
          child: IconButton(
            icon: const Icon(Icons.flashlight_on, color: Colors.white),
            onPressed: () => _scanController.toggleTorch(),
          ),
        ),
      ],
    );
  }
}

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
    final cy = size.height / 2 - 20;
    const halfBox = 120.0;
    final boxRect = Rect.fromCenter(center: Offset(cx, cy), width: halfBox * 2, height: halfBox * 2);
    final dimPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height))..addRect(boxRect)..fillType = PathFillType.evenOdd;
    canvas.drawPath(dimPath, Paint()..color = Colors.black.withAlpha(150));
    final paint = Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 3..strokeCap = StrokeCap.round;
    const len = 20.0;
    canvas.drawPath(Path()..moveTo(boxRect.left, boxRect.top + len)..lineTo(boxRect.left, boxRect.top)..lineTo(boxRect.left + len, boxRect.top), paint);
    canvas.drawPath(Path()..moveTo(boxRect.right - len, boxRect.top)..lineTo(boxRect.right, boxRect.top)..lineTo(boxRect.right, boxRect.top + len), paint);
    canvas.drawPath(Path()..moveTo(boxRect.left, boxRect.bottom - len)..lineTo(boxRect.left, boxRect.bottom)..lineTo(boxRect.left + len, boxRect.bottom), paint);
    canvas.drawPath(Path()..moveTo(boxRect.right - len, boxRect.bottom)..lineTo(boxRect.right, boxRect.bottom)..lineTo(boxRect.right, boxRect.bottom - len), paint);
  }
  @override
  bool shouldRepaint(CustomPainter old) => false;
}

class _StatusBanner extends StatelessWidget {
  final bool isProcessing;
  final String? errorMessage;
  const _StatusBanner({required this.isProcessing, this.errorMessage});

  @override
  Widget build(BuildContext context) {
    if (isProcessing) {
      return Container(
        color: Colors.black.withAlpha(150),
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
            SizedBox(width: 12),
            Text('Processing...', style: TextStyle(color: Colors.white)),
          ],
        ),
      );
    }
    if (errorMessage != null) {
      return Container(
        color: AppColors.error.withAlpha(200),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        child: Text(errorMessage!, style: const TextStyle(color: Colors.white, fontSize: 13), textAlign: TextAlign.center),
      );
    }
    return const SizedBox.shrink();
  }
}
