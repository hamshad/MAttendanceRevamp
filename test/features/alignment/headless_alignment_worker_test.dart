import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:connectivity_plus_platform_interface/connectivity_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:mattendance_mobile/features/alignment/headless_alignment_worker.dart';
import 'package:network_info_plus_platform_interface/network_info_plus_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ── Fakes (platform-interface pattern, mirrors geofence_monitor_test) ────

class _FakeNotifications extends AndroidFlutterLocalNotificationsPlugin
    with MockPlatformInterfaceMixin {
  final List<int> shown = [];
  final List<int> cancelled = [];

  @override
  Future<void> show(
    int id,
    String? title,
    String? body, {
    AndroidNotificationDetails? notificationDetails,
    String? payload,
  }) async {
    shown.add(id);
  }

  @override
  Future<void> cancel(int id, {String? tag}) async {
    cancelled.add(id);
  }
}

class _FakeGeo extends GeolocatorPlatform with MockPlatformInterfaceMixin {
  bool gpsOn = true;
  @override
  Future<bool> isLocationServiceEnabled() async => gpsOn;
}

class _FakeConnectivity extends ConnectivityPlatform
    with MockPlatformInterfaceMixin {
  List<ConnectivityResult> results = [ConnectivityResult.wifi];
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => results;
}

class _FakeNetworkInfo extends NetworkInfoPlatform
    with MockPlatformInterfaceMixin {
  String? bssid = 'AA:BB:CC:DD:EE:FF';
  @override
  Future<String?> getWifiBSSID() async => bssid;
}

// ── Harness ───────────────────────────────────────────────────────────────

Map<String, Object> _basePrefs() => {
      'bg_access_token': 'tok',
      'gf_last_punch_type': 'In',
      'geofence_auto_enabled': true,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeNotifications notifications;
  late _FakeGeo geo;
  late _FakeConnectivity conn;
  late _FakeNetworkInfo net;

  setUp(() {
    notifications = _FakeNotifications();
    FlutterLocalNotificationsPlatform.instance = notifications;
    geo = _FakeGeo();
    GeolocatorPlatform.instance = geo;
    conn = _FakeConnectivity();
    ConnectivityPlatform.instance = conn;
    net = _FakeNetworkInfo();
    NetworkInfoPlatform.instance = net;
  });

  Future<void> runWorker() => HeadlessAlignmentWorker.run();

  group('Punch-state gate', () {
    test('punched out → cancels everything, posts nothing', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(),
        'gf_last_punch_type': 'Out',
      });
      await runWorker();
      expect(notifications.shown, isEmpty);
      expect(notifications.cancelled, containsAll([996, 997, 998]));
    });

    test('logged out (no token) → cancels everything', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(),
      }..remove('bg_access_token'));
      await runWorker();
      expect(notifications.shown, isEmpty);
      expect(notifications.cancelled, containsAll([996, 997, 998]));
    });

    test('no auto feature enabled → cancels everything', () async {
      SharedPreferences.setMockInitialValues({
        ..._basePrefs(),
        'geofence_auto_enabled': false,
      });
      await runWorker();
      expect(notifications.shown, isEmpty);
      expect(notifications.cancelled, containsAll([996, 997, 998]));
    });
  });

  group('GPS off (996)', () {
    test('GPS off + geofence enabled → 996 posted', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      geo.gpsOn = false;
      await runWorker();
      expect(notifications.shown, contains(996));
    });

    test('GPS back on → 996 cancelled', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      geo.gpsOn = false;
      await runWorker();
      notifications.shown.clear();
      notifications.cancelled.clear();

      geo.gpsOn = true;
      await runWorker();
      expect(notifications.shown, isEmpty);
      expect(notifications.cancelled, contains(996));
    });
  });

  group('No connectivity (998)', () {
    test('airplane mode while punched in → 998 once', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      conn.results = [ConnectivityResult.none];

      await runWorker();
      await runWorker(); // second run — flag prevents spam

      expect(notifications.shown.where((id) => id == 998).length, 1);
    });

    test('network returns → 998 cancelled + flag cleared', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      conn.results = [ConnectivityResult.none];
      await runWorker();

      conn.results = [ConnectivityResult.wifi];
      await runWorker();

      expect(notifications.cancelled, contains(998));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('wifi_bg_no_connectivity_warned'), isFalse);
    });
  });

  group('Hidden WiFi (997)', () {
    test('on WiFi + BSSID hidden → 997 posted', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      net.bssid = null;
      await runWorker();
      expect(notifications.shown, contains(997));
    });

    test('10-min cooldown → no spam on consecutive runs', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      net.bssid = null;
      await runWorker();
      await runWorker();
      expect(notifications.shown.where((id) => id == 997).length, 1);
    });

    test('BSSID readable → 997 cancelled', () async {
      SharedPreferences.setMockInitialValues(_basePrefs());
      net.bssid = null;
      await runWorker();
      notifications.cancelled.clear();

      net.bssid = 'AA:BB:CC:DD:EE:FF';
      await runWorker();
      expect(notifications.cancelled, contains(997));
    });
  });
}
