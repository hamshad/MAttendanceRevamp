import 'dart:convert';
import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';

class CameraService {
  CameraController? _controller;
  bool _isInitialized = false;

  bool get isInitialized => _isInitialized;
  CameraController? get controller => _controller;

  /// Initialize the front-facing camera
  Future<void> initialize() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) throw Exception('No cameras available on this device.');

    // Prefer front camera; fall back to first available
    final camera = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cameras.first,
    );

    _controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    await _controller!.initialize();
    _isInitialized = true;
  }

  /// Capture photo, compress, and return base64-encoded string
  Future<String> captureAndEncode() async {
    if (_controller == null || !_isInitialized) {
      throw Exception('Camera not initialized. Call initialize() first.');
    }

    // Take picture to temp file
    final xFile = await _controller!.takePicture();

    // Compress
    final tempDir = await getTemporaryDirectory();
    final compressedPath = '${tempDir.path}/selfie_compressed.jpg';

    final compressedFile = await FlutterImageCompress.compressAndGetFile(
      xFile.path,
      compressedPath,
      quality: 70,
      minWidth: 800,
      minHeight: 800,
      format: CompressFormat.jpeg,
    );

    final file = compressedFile != null ? File(compressedFile.path) : File(xFile.path);
    final bytes = await file.readAsBytes();

    // Clean up temp files
    try {
      await File(xFile.path).delete();
      if (compressedFile != null) await File(compressedFile.path).delete();
    } catch (_) {}

    return base64Encode(bytes);
  }

  Future<void> dispose() async {
    await _controller?.dispose();
    _controller = null;
    _isInitialized = false;
  }
}
