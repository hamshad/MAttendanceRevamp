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

  SyncService(this._dioClient, this._queue);

  Future<SyncResult> syncPendingPunches() async {
    final pending = _queue.getPending();
    if (pending.isEmpty) return const SyncResult(synced: 0, failed: 0);

    int synced = 0;
    int failed = 0;

    for (final punch in pending) {
      try {
        await _dioClient.dio.post(
          ApiEndpoints.punch,
          data: _buildBody(punch),
        );
        await punch.delete();
        synced++;
      } on DioException catch (e) {
        // Server rejections (4xx/5xx) are permanent — mark as exhausted so
        // they won't be retried again after the next reconnect.
        if (e.type == DioExceptionType.badResponse) {
          punch.retryCount = 99;
          punch.errorMessage =
              (e.response?.data as Map?)?['message']?.toString() ??
                  'Rejected by server';
        } else {
          // Transient network failure — increment retry counter
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
  }

  Map<String, dynamic> _buildBody(OfflinePunch punch) {
    final body = <String, dynamic>{
      'Method': punch.method,
      'offlineTimestamp': punch.createdAt.toIso8601String(), // This is usually internal
      'Direction': punch.direction ?? 'In',
      'IPAddress': '0.0.0.0', // Standard for offline sync fallback
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
