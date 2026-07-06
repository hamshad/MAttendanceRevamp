import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

// ── Exceptions ────────────────────────────────────────────────────────────────

class NoFaceException implements Exception {
  @override
  String toString() => 'No face detected. Position your face in the oval.';
}

class MultipleFacesException implements Exception {
  @override
  String toString() => 'Multiple faces detected. Ensure only one face is visible.';
}

class FaceAngleException implements Exception {
  @override
  String toString() => 'Please look straight at the camera.';
}

// ── Result ────────────────────────────────────────────────────────────────────

class FaceResult {
  /// Float32 embedding serialized as raw bytes (128 floats × 4 bytes = 512 bytes).
  /// Matches the format expected by the backend's FaceMatchService (BytesToFloats).
  final Uint8List embedding;
  final Rect boundingBox;

  const FaceResult({required this.embedding, required this.boundingBox});
}

// ── Service ───────────────────────────────────────────────────────────────────

class FaceService {
  /// Max head yaw (degrees) before we reject the frame as "not facing forward".
  static const _maxAngleY = 20.0;

  /// FaceNet expects 160×160 RGB input.
  static const _inputSize = 160;

  /// FaceNet outputs a 128-dimensional embedding.
  static const _outputDim = 128;

  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableClassification: false,
      enableLandmarks: false,
      performanceMode: FaceDetectorMode.accurate,
    ),
  );

  Interpreter? _interpreter;

  /// Lazily loads the TFLite interpreter on first call.
  Future<void> _initInterpreter() async {
    if (_interpreter != null) return;
    _interpreter = await Interpreter.fromAsset('assets/models/facenet.tflite');
  }

  /// Detects a face in [imagePath] and extracts a 128-float embedding using
  /// MobileFaceNet (TFLite).
  ///
  /// Throws [NoFaceException], [MultipleFacesException], or [FaceAngleException]
  /// for user-correctable validation failures.
  Future<FaceResult> detectAndExtract(String imagePath) async {
    // Step 1: ML Kit detects face bounding box + head angle.
    final inputImage = InputImage.fromFilePath(imagePath);
    final faces = await _detector.processImage(inputImage);

    if (faces.isEmpty) throw NoFaceException();
    if (faces.length > 1) throw MultipleFacesException();

    final face = faces.first;
    if ((face.headEulerAngleY ?? 0.0).abs() > _maxAngleY) throw FaceAngleException();

    final bb = face.boundingBox;

    // Step 2: Load TFLite model (first call only).
    await _initInterpreter();

    // Step 3: Decode image and crop face region with a small context padding.
    final bytes = await File(imagePath).readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw Exception('Could not decode image');

    final padX = (bb.width * 0.1).toInt();
    final padY = (bb.height * 0.1).toInt();
    final x = (bb.left.toInt() - padX).clamp(0, decoded.width - 1);
    final y = (bb.top.toInt() - padY).clamp(0, decoded.height - 1);
    final w = (bb.width.toInt() + padX * 2).clamp(1, decoded.width - x);
    final h = (bb.height.toInt() + padY * 2).clamp(1, decoded.height - y);

    final cropped = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
    final resized = img.copyResize(
      cropped,
      width: _inputSize,
      height: _inputSize,
      interpolation: img.Interpolation.linear,
    );

    // Step 4: Build input tensor [1, 112, 112, 3].
    // MobileNet-style normalization: pixel / 127.5 - 1.0  →  range [-1, 1].
    final input = List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (py) => List.generate(
          _inputSize,
          (px) {
            final p = resized.getPixel(px, py);
            return [
              p.r / 127.5 - 1.0,
              p.g / 127.5 - 1.0,
              p.b / 127.5 - 1.0,
            ];
          },
        ),
      ),
    );

    // Step 5: Run inference. Output shape: [1, 128].
    final output = [List<double>.filled(_outputDim, 0.0)];
    _interpreter!.run(input, output);

    // Step 6: L2-normalize and pack as raw Float32 bytes for the backend.
    return FaceResult(
      embedding: _l2Normalize(output[0]),
      boundingBox: bb,
    );
  }

  Uint8List _l2Normalize(List<double> vec) {
    double norm = 0;
    for (final v in vec) { norm += v * v; }
    norm = sqrt(norm);

    final floats = Float32List(vec.length);
    for (int i = 0; i < vec.length; i++) {
      floats[i] = norm > 0 ? vec[i] / norm : 0.0;
    }
    return floats.buffer.asUint8List();
  }

  Future<void> close() async {
    await _detector.close();
    _interpreter?.close();
    _interpreter = null;
  }
}
