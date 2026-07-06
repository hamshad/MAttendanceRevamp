import 'wifi_router.dart';

class Office {
  final int id;
  final String name;
  final double? latitude;
  final double? longitude;
  final int? geofenceRadius; // meters

  final String? wifiSSID;
  final String? wifiMAC;
  final List<WifiRouter>? wifiRouters;

  const Office({
    required this.id,
    required this.name,
    this.latitude,
    this.longitude,
    this.geofenceRadius,
    this.wifiSSID,
    this.wifiMAC,
    this.wifiRouters,
  });

  factory Office.fromJson(Map<String, dynamic> j) {
    List<WifiRouter>? routers;
    final raw = j['wifiRouters'] ?? j['wifi_routers'] ?? j['routers'];
    if (raw is List) {
      routers = raw
          .map((e) => WifiRouter.fromJson(e as Map<String, dynamic>))
          .toList();
    }

    return Office(
      id: j['id'] as int,
      name: j['name'] as String? ?? '',
      latitude: (j['latitude'] as num?)?.toDouble(),
      longitude: (j['longitude'] as num?)?.toDouble(),
      geofenceRadius:
          j['geofenceRadius'] as int? ?? j['geofence_radius'] as int?,
      wifiSSID: j['wifiSSID'] as String? ??
          j['wifi_ssid'] as String? ??
          j['ssid'] as String? ??
          j['wifissid'] as String?,
      wifiMAC: j['wifiMAC'] as String? ??
          j['wifi_mac'] as String? ??
          j['mac'] as String? ??
          j['macid'] as String? ??
          j['mac_id'] as String?,
      wifiRouters: routers,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'latitude': latitude,
        'longitude': longitude,
        'geofenceRadius': geofenceRadius,
        'wifiSSID': wifiSSID,
        'wifiMAC': wifiMAC,
        'wifiRouters': wifiRouters?.map((r) => r.toJson()).toList(),
      };

  bool get hasCoordinates => latitude != null && longitude != null;
}
