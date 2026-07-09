import 'package:network_info_plus/network_info_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

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
  final _connectivity = Connectivity();

  /// Returns current WiFi info.
  ///
  /// Some Android 12+ phones return null SSID even when WiFi is connected
  /// (location toggle off at system level). In that case we fall back to
  /// checking [Connectivity] to confirm WiFi is active and return BSSID
  /// with a placeholder SSID so users can still punch.
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

    final rawSsid = await _networkInfo.getWifiName();
    final rawBssid = await _networkInfo.getWifiBSSID();

    // Some phones return null/unknown SSID even when WiFi is connected.
    // Fall back: verify WiFi via Connectivity, and allow BSSID-only flow.
    final ssidUnavailable = rawSsid == null || rawSsid.isEmpty || rawSsid == '<unknown ssid>';
    final bssidUnavailable = rawBssid == null || rawBssid.isEmpty;

    if (ssidUnavailable && bssidUnavailable) {
      throw const WifiNotConnectedException(
        'Not connected to any WiFi network. Please connect to the office WiFi and try again.',
      );
    }

    if (bssidUnavailable) {
      // SSID is available but no BSSID
      throw const WifiNotConnectedException(
        'Could not read WiFi details. Please ensure WiFi is connected and try again.',
      );
    }

    final bssid = rawBssid.toUpperCase();

    // If SSID is null/unknown, confirm WiFi is actually active via connectivity_plus
    if (ssidUnavailable) {
      final result = await _connectivity.checkConnectivity();
      final onWifi = result.contains(ConnectivityResult.wifi);
      if (!onWifi) {
        throw const WifiNotConnectedException(
          'Not connected to any WiFi network. Please connect to the office WiFi and try again.',
        );
      }
      // Return BSSID with placeholder SSID — backend can match by MAC alone
      return WifiInfo(ssid: 'Unknown Network', bssid: bssid);
    }

    // Android wraps SSID in quotes — strip them
    final cleanSsid = rawSsid.replaceAll('"', '');

    return WifiInfo(ssid: cleanSsid, bssid: bssid);
  }

  Future<String?> getWifiIP() async {
    return await _networkInfo.getWifiIP();
  }
}
