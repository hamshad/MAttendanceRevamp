import 'package:network_info_plus/network_info_plus.dart';
import 'package:geolocator/geolocator.dart';

class WifiInfo {
  final String ssid;
  final String bssid; // MAC address of the access point

  const WifiInfo({required this.ssid, required this.bssid});
}

class WifiNotConnectedException implements Exception {
  final String message;
  const WifiNotConnectedException(this.message);
}

class WifiPermissionException implements Exception {
  final String message;
  const WifiPermissionException(this.message);
}

class WifiService {
  final _networkInfo = NetworkInfo();

  Future<WifiInfo> getCurrentWifi() async {
    // Android 8+ requires location permission to read SSID/BSSID
    final permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      final requested = await Geolocator.requestPermission();
      if (requested == LocationPermission.denied ||
          requested == LocationPermission.deniedForever) {
        throw const WifiPermissionException(
          'Location permission is required to read WiFi network name on Android.',
        );
      }
    }

    final ssid = await _networkInfo.getWifiName();
    final bssid = await _networkInfo.getWifiBSSID();

    if (ssid == null || ssid.isEmpty || ssid == '<unknown ssid>') {
      throw const WifiNotConnectedException(
        'Not connected to any WiFi network. Please connect to the office WiFi and try again.',
      );
    }

    if (bssid == null || bssid.isEmpty) {
      throw const WifiNotConnectedException(
        'Could not read WiFi details. Please ensure WiFi is connected and try again.',
      );
    }

    // Android wraps SSID in quotes — strip them
    final cleanSsid = ssid.replaceAll('"', '');

    return WifiInfo(ssid: cleanSsid, bssid: bssid.toUpperCase());
  }

  Future<String?> getWifiIP() async {
    return await _networkInfo.getWifiIP();
  }
}
