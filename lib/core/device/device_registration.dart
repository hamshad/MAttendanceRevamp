import 'dart:io';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../api/api_endpoints.dart';
import '../../features/punch/services/device_info_service.dart';

class DeviceRegistrationService {
  final Dio _dio;
  final _deviceInfo = DeviceInfoService();

  DeviceRegistrationService(this._dio);

  /// Registers (or updates) this device with the backend.
  /// Pass [fcmToken] when Firebase is available to enable push notifications.
  Future<void> register({String? fcmToken}) async {
    try {
      final deviceId = await _deviceInfo.getDeviceId();
      final deviceName = await _deviceInfo.getDeviceName();
      final packageInfo = await PackageInfo.fromPlatform();

      await _dio.post(
        ApiEndpoints.registerDevice,
        data: {
          'deviceId': deviceId,
          'deviceName': deviceName,
          'platform': Platform.isAndroid ? 'Android' : 'iOS',
          if (fcmToken case final t?) 'fcmToken': t,
          'appVersion': packageInfo.version,
        },
      );
    } catch (_) {
      // Best-effort — device registration failure is non-blocking.
    }
  }
}
