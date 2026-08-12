import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:mattendance_mobile/features/punch/services/geofence_monitor.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Headless alignment warnings — Phase 5.
///
/// The GPS-off (996), wifi-hidden (997) and no-connectivity (998) nags used
/// to be posted by the background-service isolate.  Geofence-only users no
/// longer run a service (native-first, Phase 2), so those popups died with
/// it.  This worker runs inside a periodic WorkManager task (~30 min,
/// system-scheduled, battery-cheap) with the app killed and re-posts the
/// same nags from the headless isolate.
///
/// Contract with the other monitors (single source of truth):
///  - Notification IDs 996/997/998 + channel `user_alignment` — shared with
///    the foreground AlignmentMonitor and the (service) wifi worker, so all
///    sides REPLACE, never duplicate, each other's popups.
///  - SharedPreferences keys — same flags/rate-limits the service isolate
///    used (`wifi_bg_no_connectivity_warned`, `wifi_bg_bssid_warned_ts`).
///  - Punch-state gate — punched out (at home) → every alert cancels and
///    stays quiet, exactly like the monitors.
class HeadlessAlignmentWorker {
  HeadlessAlignmentWorker._();

  static const String taskName = 'alignment_warnings';

  static const int gpsOffNotifId = 996;
  static const int wifiHiddenNotifId = 997;
  static const int noConnectivityNotifId = 998;

  static const Duration _bssidCooldown = Duration(minutes: 10);

  // Shared prefs keys (same as WifiBackgroundWorker's warning logic).
  static const _kNoConnectivityWarned = 'wifi_bg_no_connectivity_warned';
  static const _kBssidWarnedTs = 'wifi_bg_bssid_warned_ts';

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  /// Workmanager entry — must return quickly and never throw.
  static Future<bool> run() async {
    try {
      await _runInner();
    } catch (e) {
      debugPrint('[ALIGN_HEADLESS] run failed: $e');
    }
    return true;
  }

  static Future<void> _runInner() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // Logged out → nothing to warn about, clear stale popups.
    final token = prefs.getString('bg_access_token');
    if (token == null || token.isEmpty) {
      await _cancelAll();
      return;
    }

    // Punch-state gate: at home, punched out, everything is normal.
    if (prefs.getString('gf_last_punch_type') != 'In') {
      await _cancelAll();
      return;
    }

    final anyAuto = (prefs.getBool('geofence_auto_enabled') ?? false) ||
        (prefs.getBool('wifi_auto_punch_enabled_bg') ?? false) ||
        (prefs.getBool('field_tracking_enabled') ?? false);
    if (!anyAuto) {
      await _cancelAll();
      return;
    }

    await _checkGps(prefs, anyAuto: anyAuto);
    await _checkConnectivity(prefs);
    await _checkWifiHidden(prefs);

    // Missed-EXIT recovery (geofence-only mode has no service poller): the
    // OS can fail to deliver the exit transition while backgrounded, which
    // leaves the user stuck punched in.  Re-check containment headlessly —
    // two back-to-back fixes outside every office radius punch OUT.
    // Battery: at most two 10s GPS fixes per 30-min run, only while
    // punched in.  reconcileContainment self-gates on
    // enable/permission/token/location-service, and its OUT path verifies
    // against the server before punching.
    // Self-heal OS geofences first (initialTriggers: {} — no enter catch-up;
    // containment reconcile handles catch-up) so the native EXIT fires at
    // the boundary.
    await GeofenceMonitor.registerZones(initialTriggers: const {});
    await GeofencePunchHandler.instance.reconcileContainment(confirmOut: true);
  }

  /// GPS off → geofences can't fire; warn (996) while any auto feature is on.
  static Future<void> _checkGps(SharedPreferences prefs,
      {required bool anyAuto}) async {
    try {
      final gpsOn = await geo.Geolocator.isLocationServiceEnabled();
      if (!gpsOn && anyAuto) {
        await _notifications.show(
          gpsOffNotifId,
          'GPS is off',
          'Auto punch won\u2019t work and you could be marked absent even at '
              'the office. Turn Location back on.',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'user_alignment',
              'Attendance Alerts',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
        );
      } else {
        await _notifications.cancel(gpsOffNotifId);
      }
    } catch (e) {
      debugPrint('[ALIGN_HEADLESS] GPS check failed: $e');
    }
  }

  /// Airplane mode / no network — warn once (998), clear when back online.
  static Future<void> _checkConnectivity(SharedPreferences prefs) async {
    try {
      final results = await Connectivity().checkConnectivity();
      final none = results.isEmpty ||
          results.every((r) => r == ConnectivityResult.none);
      if (none) {
        if (prefs.getBool(_kNoConnectivityWarned) ?? false) return;
        await prefs.setBool(_kNoConnectivityWarned, true);
        await _notifications.show(
          noConnectivityNotifId,
          'No network (airplane mode?)',
          'Attendance can\u2019t send or receive right now. WiFi punches will '
              'be saved and sent when you\u2019re back online. Swipe down from '
              'the top of your screen and turn off airplane mode.',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'user_alignment',
              'Attendance Alerts',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
        );
      } else {
        if (prefs.getBool(_kNoConnectivityWarned) ?? false) {
          await prefs.setBool(_kNoConnectivityWarned, false);
        }
        await _notifications.cancel(noConnectivityNotifId);
      }
    } catch (e) {
      debugPrint('[ALIGN_HEADLESS] Connectivity check failed: $e');
    }
  }

  /// Connected to WiFi but Android hides the network name (location off) —
  /// warn (997) rate-limited to 10 min, clear when readable again.
  static Future<void> _checkWifiHidden(SharedPreferences prefs) async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (!results.contains(ConnectivityResult.wifi)) {
        await _notifications.cancel(wifiHiddenNotifId);
        return;
      }
      String? bssid;
      try {
        bssid = await NetworkInfo().getWifiBSSID();
      } catch (_) {
        bssid = null;
      }
      final hidden =
          bssid == null || bssid.isEmpty || bssid == '02:00:00:00:00:00';
      if (!hidden) {
        await _notifications.cancel(wifiHiddenNotifId);
        return;
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      final lastWarned = prefs.getInt(_kBssidWarnedTs) ?? 0;
      if (now - lastWarned < _bssidCooldown.inMilliseconds) return;

      await prefs.setInt(_kBssidWarnedTs, now);
      await _notifications.show(
        wifiHiddenNotifId,
        'Connected to WiFi, but the app can\u2019t read it',
        'This happens when Location is off. Turn it on so auto punch can '
            'confirm you\u2019re on the office network. Phone Settings \u2192 Location.',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'user_alignment',
            'Attendance Alerts',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[ALIGN_HEADLESS] WiFi-hidden check failed: $e');
    }
  }

  static Future<void> _cancelAll() async {
    try {
      await _notifications.cancel(gpsOffNotifId);
      await _notifications.cancel(wifiHiddenNotifId);
      await _notifications.cancel(noConnectivityNotifId);
    } catch (e) {
      debugPrint('[ALIGN_HEADLESS] cancel failed: $e');
    }
  }
}
