class ClientSite {
  final int id;
  final String siteName;
  final String? address;
  final double latitude;
  final double longitude;
  final int radiusMeters;

  const ClientSite({
    required this.id,
    required this.siteName,
    this.address,
    required this.latitude,
    required this.longitude,
    required this.radiusMeters,
  });

  factory ClientSite.fromJson(Map<String, dynamic> j) => ClientSite(
        id: j['id'] as int,
        siteName: j['siteName'] as String,
        address: j['address'] as String?,
        latitude: (j['latitude'] as num).toDouble(),
        longitude: (j['longitude'] as num).toDouble(),
        radiusMeters: j['radiusMeters'] as int,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'siteName': siteName,
        'address': address,
        'latitude': latitude,
        'longitude': longitude,
        'radiusMeters': radiusMeters,
      };

  /// Human-readable label for the dropdown.
  String get displayName =>
      address != null ? '$siteName — $address' : siteName;
}
