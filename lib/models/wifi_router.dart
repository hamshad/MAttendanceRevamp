class WifiRouter {
  final String macId;
  final String ssid;
  final String name;

  const WifiRouter({
    required this.macId,
    required this.ssid,
    required this.name,
  });

  factory WifiRouter.fromJson(Map<String, dynamic> j) => WifiRouter(
        macId: j['macId'] as String? ?? j['mac_id'] as String? ?? j['mac'] as String? ?? '',
        ssid: j['ssid'] as String? ?? '',
        name: j['name'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'macId': macId,
        'ssid': ssid,
        'name': name,
      };
}
