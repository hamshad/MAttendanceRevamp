import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';

class DeviceInfoService {
  final _plugin = DeviceInfoPlugin();

  Future<String> getDeviceId() async {
    if (Platform.isAndroid) {
      final info = await _plugin.androidInfo;
      return info.id; // Android hardware serial / build fingerprint
    } else if (Platform.isIOS) {
      final info = await _plugin.iosInfo;
      return info.identifierForVendor ?? 'unknown-ios';
    }
    return 'unknown-platform';
  }

  Future<String> getDeviceName() async {
    if (Platform.isAndroid) {
      final info = await _plugin.androidInfo;
      return '${info.manufacturer} ${info.model}';
    } else if (Platform.isIOS) {
      final info = await _plugin.iosInfo;
      return info.name;
    }
    return 'Unknown Device';
  }
}
