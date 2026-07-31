import 'package:dio/dio.dart';
import '../api/api_endpoints.dart';
import '../api/dio_client.dart';
import '../../models/offline_punch.dart';
import 'offline_queue.dart';

class SyncResult {
  final int synced;
  final int failed;

  const SyncResult({required this.synced, required this.failed});

  bool get hasActivity => synced > 0 || failed > 0;
}

class SyncService {
  final DioClient _dioClient;
  final OfflineQueueService _queue;
  bool _isSyncing = false;

  SyncService(this._dioClient, this._queue);

  Future<SyncResult> syncPendingPunches() async {
    if (_isSyncing) return const SyncResult(synced: 0, failed: 0);
    _isSyncing = true;
    try {
      // getPending() returns punches sorted oldest-first — the backend
      // must receive them in chronological order for In/Out alternation.
      final pending = _queue.getPending();
      if (pending.isEmpty) return const SyncResult(synced: 0, failed: 0);

      int synced = 0;
      int failed = 0;

      for (final punch in pending) {
        final validationError = _validate(punch);
        if (validationError != null) {
          punch.retryCount = 99;
          punch.errorMessage = validationError;
          await punch.save();
          failed++;
          continue;
        }

        try {
          await _dioClient.dio.post(
            ApiEndpoints.punch,
            data: _buildBody(punch),
          );
          await punch.delete();
          synced++;
        } on DioException catch (e) {
          if (e.type == DioExceptionType.badResponse) {
            punch.retryCount = 99;
            punch.errorMessage =
                (e.response?.data as Map?)?['message']?.toString() ??
                    'Rejected by server';
          } else {
            punch.retryCount++;
            punch.errorMessage = 'Network error — will retry';
          }
          await punch.save();
          failed++;
        } catch (e) {
          punch.retryCount++;
          punch.errorMessage = e.toString();
          await punch.save();
          failed++;
        }
      }

      return SyncResult(synced: synced, failed: failed);
    } finally {
      _isSyncing = false;
    }
  }

  /// Client-side validation before hitting the server.
  /// Returns null if valid, or an error message string if the punch can't be
  /// accepted by the server in its current state.
  String? _validate(OfflinePunch punch) {
    if (punch.method == 'GPS' && punch.latitude == null) {
      return 'GPS punch needs location — enable GPS and retry';
    }
    return null;
  }

  Map<String, dynamic> _buildBody(OfflinePunch punch) {
    final body = <String, dynamic>{
      'Method': punch.method,
      'offlineTimestamp': punch.createdAt.toIso8601String(),
      'Direction': punch.direction ?? 'In',
      'IPAddress': '0.0.0.0',
    };
    if (punch.latitude != null) body['Latitude'] = punch.latitude.toString();
    if (punch.longitude != null) body['Longitude'] = punch.longitude.toString();
    if (punch.selfieBase64 != null) body['SelfieBase64'] = punch.selfieBase64;
    if (punch.qrToken != null) body['QrCodeToken'] = punch.qrToken;
    if (punch.wifiMAC != null) body['WifiMAC'] = punch.wifiMAC;
    if (punch.wifiSSID != null) body['WifiSSID'] = punch.wifiSSID;
    if (punch.deviceId != null) body['DeviceId'] = punch.deviceId;
    if (punch.beaconUUID != null) body['BeaconUUID'] = punch.beaconUUID;
    if (punch.beaconMajor != null) body['BeaconMajor'] = punch.beaconMajor.toString();
    if (punch.beaconMinor != null) body['BeaconMinor'] = punch.beaconMinor.toString();
    if (punch.nfcTagId != null) body['NfcTagId'] = punch.nfcTagId;
    if (punch.faceEmbedding != null) body['FaceEmbedding'] = punch.faceEmbedding;
    return body;
  }
}
