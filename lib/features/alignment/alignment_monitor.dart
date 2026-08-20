import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/notifications/local_notifications.dart';
import 'alignment_models.dart';
import 'widgets/alignment_dialog.dart';

/// Global navigator key — lets the monitor (a non-widget) show the in-app
/// alignment dialog on top of whatever screen is open.
final appNavigatorKey = GlobalKey<NavigatorState>();

/// Main-isolate watchdog for employee behaviours that quietly break auto
/// punch (GPS off, background-location permission revoked, airplane mode,
/// WiFi network name hidden by the OS).
///
/// **Punch-state gate:** alerts only matter while the user is on an active
/// shift.  Punched in → broken settings surface immediately.  Punched out
/// (e.g. at home) → every alert clears and stays quiet, including the
/// background isolate's popups (996/997/998).  Re-evaluated every minute
/// and on every punch (see `reEvaluate()`).
///
/// Surfaces alerts three ways:
///  - **In-app dialog** (critical alerts, app foreground) — pops over the
///    current screen with a "Fix it" button.
///  - **Heads-up notification** (permission alert, app backgrounded) — the
///    popup the employee sees even when the app is closed.  GPS-off,
///    airplane-mode and hidden-WiFi notifications are fired by the
///    background isolate instead (it keeps running when the app is killed).
///  - **Dashboard banner** — active alerts persist on the home screen so the
///    problem is visible every time the app opens.
///
/// Notification IDs are SHARED with the background isolate (996 GPS,
/// 997 wifi-hidden, 998 no-connectivity, 999 permission) so both sides
/// replace rather than duplicate each other's popups.
class AlignmentMonitor extends ChangeNotifier {
  AlignmentMonitor._();
  static final AlignmentMonitor instance = AlignmentMonitor._();

  static const int _permissionNotifId = 999;

  final Map<String, AlignmentAlert> _active = {};
  final Set<String> _dialogShown = {};
  final Set<String> _dismissed = {};
  bool _started = false;
  bool _foreground = true;

  StreamSubscription<ServiceStatus>? _gpsSub;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _permTimer;
  _LifecycleObserver? _observer;

  /// Active, non-dismissed alerts in insertion order.
  List<AlignmentAlert> get activeAlerts =>
      _active.values.where((a) => !_dismissed.contains(a.id)).toList();

  bool get hasAlerts => activeAlerts.isNotEmpty;

  /// Dismisses a WARNING banner for this session (critical alerts stay).
  void dismissAlert(String id) {
    final alert = _active[id];
    if (alert == null || alert.severity != AlignmentSeverity.warning) return;
    _dismissed.add(id);
    notifyListeners();
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;
    debugPrint('[ALIGN] start() — subscribing');

    _observer = _LifecycleObserver(this);
    WidgetsBinding.instance.addObserver(_observer!);

    _gpsSub = Geolocator.getServiceStatusStream().listen(_onGpsStatus);
    _connSub = Connectivity().onConnectivityChanged.listen(_onConnectivityChanged);

    await _evaluateAll();
    debugPrint('[ALIGN] start() — initial evaluation complete');
    // Full re-evaluation each minute: catches punch-state transitions made
    // by background isolates (geofence / wifi) that this isolate can't see
    // as events.
    _permTimer = Timer.periodic(const Duration(minutes: 1), (_) => _evaluateAll());
  }

  /// True while the user is on an active shift.  Alignment alerts only make
  /// sense then — GPS off / airplane mode at home (punched out) is normal.
  Future<bool> _isPunchedIn() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('gf_last_punch_type') == 'In';
  }

  /// Re-evaluate every alert right now.  Called by the punch flow so a
  /// punch-in immediately surfaces an existing broken setting and a
  /// punch-out immediately silences everything.
  Future<void> reEvaluate() => _evaluateAll();

  @override
  void dispose() {
    _gpsSub?.cancel();
    _connSub?.cancel();
    _permTimer?.cancel();
    if (_observer != null) WidgetsBinding.instance.removeObserver(_observer!);
    super.dispose();
  }

  // ── Stream handlers ──────────────────────────────────────────────────────

  Future<void> _onGpsStatus(ServiceStatus status) async {
    if (!await _isPunchedIn()) return; // no shift → no alert
    final gpsOn = status == ServiceStatus.enabled;
    final anyAuto = await _anyAutoFeatureEnabled();
    _setOrClear(
      AlignmentAlerts.gpsOff,
      active: !gpsOn && anyAuto,
    );
  }

  Future<void> _onConnectivityChanged(List<ConnectivityResult> results) async {
    if (!await _isPunchedIn()) return; // no shift → no alert
    final wifiEnabled = await _wifiAutoEnabled();
    final none = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    _setOrClear(
      AlignmentAlerts.noConnectivity,
      active: none && wifiEnabled,
    );
    if (none && wifiEnabled) {
      await _evaluateWifiHidden();
    } else {
      _setOrClear(AlignmentAlerts.wifiHidden, active: false);
    }
  }

  Future<void> _evaluateAll() async {
    // No active shift → all alignment alerts are irrelevant (GPS off /
    // airplane mode at home, punched out, is normal).  Clear every alert
    // and every popup — including the background isolate's — so a
    // punched-out user stays quiet.
    if (!await _isPunchedIn()) {
      _active.clear();
      notifyListeners();
      for (final id in const [996, 997, 998, _permissionNotifId]) {
        try {
          await localNotifications.cancel(id);
        } catch (_) {}
      }
      return;
    }
    debugPrint('[ALIGN] _evaluateAll: gps');
    await _onGpsStatus(
      await Geolocator.isLocationServiceEnabled()
          ? ServiceStatus.enabled
          : ServiceStatus.disabled,
    );
    debugPrint('[ALIGN] _evaluateAll: permission');
    await _evaluatePermission();
    debugPrint('[ALIGN] _evaluateAll: connectivity');
    final results = await Connectivity().checkConnectivity();
    await _onConnectivityChanged(results);
    await _evaluateWifiHidden();
  }

  /// GPS is on + wifi auto enabled → BSSID should be readable.  If it isn't,
  /// Android is hiding the network name (location off is the usual cause).
  Future<void> _evaluateWifiHidden() async {
    final wifiEnabled = await _wifiAutoEnabled();
    if (!wifiEnabled) {
      _setOrClear(AlignmentAlerts.wifiHidden, active: false);
      return;
    }
    final results = await Connectivity().checkConnectivity();
    if (!results.contains(ConnectivityResult.wifi)) {
      _setOrClear(AlignmentAlerts.wifiHidden, active: false);
      return;
    }
    String? bssid;
    try {
      bssid = await NetworkInfo().getWifiBSSID();
    } catch (_) {
      bssid = null;
    }
    final hidden = bssid == null || bssid.isEmpty || bssid == '02:00:00:00:00:00';
    _setOrClear(AlignmentAlerts.wifiHidden, active: hidden);
  }

  /// Background location permission: geo/field auto need "Allow all the time".
  /// Fired once per minute + on app resume.  Also posts a heads-up popup when
  /// the app is backgrounded (background workers can't detect permission
  /// changes — this is the only alert the monitor owns as a notification).
  Future<void> _evaluatePermission() async {
    final prefs = await SharedPreferences.getInstance();
    final gf = prefs.getBool('geofence_auto_enabled') ?? false;
    final ft = prefs.getBool('field_tracking_enabled') ?? false;
    if (!gf && !ft) {
      _setOrClear(AlignmentAlerts.permissionNotAlways, active: false);
      return;
    }
    final permission = await Geolocator.checkPermission();
    debugPrint('[ALIGN] permission check: $permission (gf=$gf ft=$ft)');
    final degraded = permission == LocationPermission.whileInUse ||
        permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever;
    if (degraded) {
      final alert = AlignmentAlerts.permissionNotAlways;
      final alreadyActive = _active.containsKey(alert.id);
      _setOrClear(alert, active: true);
      // Heads-up popup when the app is closed/backgrounded.
      if (!_foreground && !alreadyActive) {
        await _postHeadsUp(
          _permissionNotifId,
          alert.title,
          alert.message,
        );
      }
    } else {
      _setOrClear(AlignmentAlerts.permissionNotAlways, active: false);
      try {
        await localNotifications.cancel(_permissionNotifId);
      } catch (_) {}
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  void _setOrClear(AlignmentAlert alert, {required bool active}) {
    if (active) {
      final wasActive = _active.containsKey(alert.id);
      _active[alert.id] = alert;
      if (!wasActive) {
        debugPrint('[ALIGN] alert active: ${alert.id} (fg=$_foreground)');
        notifyListeners();
        // Critical alerts pop a dialog immediately when the app is open.
        if (_foreground &&
            alert.severity == AlignmentSeverity.critical &&
            !_dialogShown.contains(alert.id)) {
          _dialogShown.add(alert.id);
          _showDialog(alert);
        }
      }
    } else if (_active.remove(alert.id) != null) {
      debugPrint('[ALIGN] alert resolved: ${alert.id}');
      // Resolved — allow the alert to show again if the user breaks the
      // setting a second time (don't keep it dismissed forever).
      _dismissed.remove(alert.id);
      notifyListeners();
    }
  }

  void _showDialog(AlignmentAlert alert) {
    debugPrint('[ALIGN] showing dialog: ${alert.id}');
    final context = appNavigatorKey.currentContext;
    if (context == null) {
      debugPrint('[ALIGN] dialog skipped — no navigator context');
      return;
    }
    showAlignmentDialog(context, alert);
  }

  Future<bool> _anyAutoFeatureEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool('geofence_auto_enabled') ?? false) ||
        (prefs.getBool('field_tracking_enabled') ?? false) ||
        await _wifiAutoEnabled();
  }

  Future<bool> _wifiAutoEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getBool('wifi_auto_punch_enabled_bg') ?? false) ||
        (prefs.getBool('wifi_auto_punch_enabled') ?? false);
  }

  Future<void> _postHeadsUp(int id, String title, String body) async {
    debugPrint('[ALIGN] heads-up notification: $id ($title)');
    try {
      await localNotifications.show(
        id,
        title,
        body,
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
      debugPrint('[ALIGN] Heads-up notification failed: $e');
    }
  }
}

class _LifecycleObserver extends WidgetsBindingObserver {
  final AlignmentMonitor monitor;
  _LifecycleObserver(this.monitor);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final nowForeground = state == AppLifecycleState.resumed;
    if (nowForeground != monitor._foreground) {
      monitor._foreground = nowForeground;
      if (nowForeground) {
        // Re-evaluate on resume — settings may have been changed while away.
        monitor._evaluateAll();
      }
    }
  }
}
