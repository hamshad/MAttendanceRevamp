import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/auth_provider.dart';
import '../../core/config/dev_flags.dart';
import '../../core/utils/aggressive_oem.dart';
import '../../core/utils/constants.dart';
import '../../core/notifications/fcm_service.dart';
import '../../core/notifications/local_notifications.dart';
import '../../core/offline/offline_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_provider.dart';
import '../alignment/alignment_providers.dart';
import '../settings/screens/debug_log_screen.dart';
import '../dashboard/providers/dashboard_providers.dart';
import '../dashboard/screens/home_screen.dart';
import '../dashboard/widgets/punch_button.dart';
import '../history/screens/history_hub_screen.dart';
import '../history/screens/payslip_screen.dart';
import '../history/screens/regularization_screen.dart';
import '../leave/screens/leave_screen.dart';
import '../notifications/providers/notifications_provider.dart';
import '../notifications/screens/notifications_screen.dart';
import '../punch/services/geofence_monitor.dart';
import '../punch/services/geofence_scheduler.dart';
import '../punch/services/oem_keep_alive_service.dart';
import '../punch/services/shift_service.dart';
import '../punch/services/wifi_auto_punch_service.dart';
import '../settings/screens/geofence_settings_screen.dart';
import '../settings/screens/wifi_settings_screen.dart';
import '../settings/screens/face_enrollment_screen.dart';
import '../../models/attendance.dart';
import '../offline/screens/offline_screen.dart';
import '../../models/shift.dart';
import '../tracking/screens/my_field_tracking_screen.dart';
import '../tracking/services/field_tracking_service.dart';
import '../tracking/widgets/accuracy_debug_overlay.dart';
import '../punch/screens/punch_flow_screen.dart';
import '../punch/screens/geofence_places_screen.dart';
import '../punch/screens/client_site_screen.dart';

// ── Shell ─────────────────────────────────────────────────────────────────────

final _shellIndexProvider = StateProvider<int>((ref) => 0);

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with WidgetsBindingObserver {
  WifiAutoPunchService? _wifiAutoService;
  StreamSubscription<bool>? _trackingRunSub;
  StreamSubscription<Map<String, dynamic>>? _punchSub;
  StreamSubscription<Map<String, dynamic>>? _wifiPunchSub;
  bool _offlineScreenPushed = false;

  // Guards against stacking the battery-exemption dialog when several paths
  // trigger it near-simultaneously (geofence toggle + field-tracking start).
  static bool _batteryDialogVisible = false;

  // Set when the user taps "Not Now" — don't nag again this session.  The
  // prompt only returns on a later app launch + explicit user action.
  static bool _batteryPromptDismissed = false;

  static const _tabs = [
    HomeScreen(),
    HistoryHubScreen(),
    LeaveScreen(),
    _ProfileTab(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _trackingRunSub = FieldTrackingService.runningStream.listen((running) {
      if (mounted) {
        ref.read(fieldTrackingRunningProvider.notifier).state = running;
      }
    });
    _punchSub = FieldTrackingService.punchStream.listen((_) {
      if (mounted) {
        ref.invalidate(attendanceStatusProvider);
      }
    });
    _wifiPunchSub = FieldTrackingService.wifiPunchStream.listen((_) {
      if (mounted) {
        ref.invalidate(attendanceStatusProvider);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(alignmentMonitorProvider); // starts the user-alignment watchdog
      _initGeofence();
      _initWifiAuto();
      _initFieldTracking();
      _initGeofenceScheduler();
      fetchUnreadCount(ref);
      _initFCM();
      _syncOfflinePunches();
      _checkOfflineOnStart();
      _initLocalNotificationTap();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Geofence is NOT stopped on dispose — it should stay alive indefinitely
    // (process keep-alive via WillStartForegroundTask). Only a manual punch-out
    // from the UI stops it.
    _wifiAutoService?.stop();
    _trackingRunSub?.cancel();
    _punchSub?.cancel();
    _wifiPunchSub?.cancel();
    super.dispose();
  }

  /// Re-syncs the tracking running state immediately when the user brings the
  /// app to the foreground.  Without this, [fieldTrackingRunningProvider] can
  /// show the wrong value because the background isolate only emits a
  /// 'running' event once at startup (and every 5 minutes via the timer
  /// heartbeat) — the UI would lag by up to 5 minutes on resume.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('SHELL_Lifecycle: $state');
    if (state == AppLifecycleState.resumed) {
      // 1. Refresh field tracking state
      FieldTrackingService.isRunning.then((running) {
        if (mounted) {
          debugPrint('SHELL_Lifecycle: FieldTrackingService.isRunning=$running');
          ref.read(fieldTrackingRunningProvider.notifier).state = running;
        }
      });

      // 2. Trigger WiFi auto-punch check
      _wifiAutoService?.checkAndPunchIfEnabled();

      // 3. Sync geofence enabled flag for the background isolate.
      //    The combined service is started by _initGeofenceScheduler() below
      //    if within the shift window.
      SharedPreferences.getInstance().then((prefs) {
        final isEnabled = GeofenceMonitor.isEnabled;
        debugPrint('SHELL_Lifecycle: syncing geofence_auto_enabled=$isEnabled');
        prefs.setBool('geofence_auto_enabled', isEnabled);
      });

      // 4. Ensure the combined service is running if within shift window
      _initGeofenceScheduler();

      // 4b. Recover a missed geofence IN/OUT: GPS may have been off while
      //     the app was backgrounded (no trustworthy OS transitions fired —
      //     a re-entry INTO the office radius, or an EXIT while walking
      //     away, was never punched).  Only punches when the user is
      //     verified inside an office radius (IN) or outside every office
      //     radius on two consecutive fixes (OUT).  confirmOut: the OS
      //     exit is easily missed while backgrounded and geofence-only mode
      //     has no background poller — confirm the exit with a second fix
      //     right here instead of waiting for a poll that never comes.
      GeofencePunchHandler.instance.reconcileContainment(confirmOut: true);

      // 4c. Re-register OS geofences on every resume (self-healing).  The
      //     system drops geofence registrations on force-stop and some OEM
      //     memory cleanups; re-arming also refreshes the plugin's Dart
      //     callback handle so the headless punch path keeps working with
      //     the app killed even when registration was lost while
      //     backgrounded.  Idempotent: registerZones wipes and recreates,
      //     and self-gates on enable/permission/token.
      //
      //     NOTE: initialTriggers: {} — do NOT re-arm the enter catch-up
      //     here.  With the default {enter}, every background→foreground
      //     re-registration re-fires ENTER for every zone the user is
      //     inside → a duplicate "already punched" notification while the
      //     user sits still at the office.  Containment catch-up on resume
      //     is 4b's reconcileContainment.
      if (GeofenceMonitor.isEnabled) {
        GeofenceMonitor.registerZones(
          providedDio: ref.read(dioClientProvider).dio,
          initialTriggers: const {},
        );
      }

      // 5. Try syncing offline punches on resume
      _syncOfflinePunches();

      // 6. Refresh dashboard data so it's never stale on resume
      ref.invalidate(attendanceStatusProvider);
    }
  }

  // ── Geofence lifecycle ─────────────────────────────────────────────────────

  Future<void> _initGeofence() async {
    if (!mounted) return;
    debugPrint('SHELL: _initGeofence() triggered — GeofenceMonitor.isEnabled=${GeofenceMonitor.isEnabled}');

    final perms = ref.read(accessPermissionsProvider).value;
    if (perms == null) {
      // Perms still loading / fetch failed — do nothing (never revoke on
      // transient failure).
      debugPrint('SHELL: Geofence perms unknown (loading) — skipping init');
      return;
    }
    if (!perms.allowGeofenceAuto) {
      debugPrint('SHELL: Geofence not permitted by backend — stopping geofence service/alarms');
      // Definitive denial → revoke the background path: cancel shift alarms,
      // unregister OS geofences, and tell the running service geofence is off.
      // The combined service stays alive if field tracking needs it.
      await GeofenceMonitor.unregisterAll();
      await GeofenceScheduler.cancel();
      FieldTrackingService.notifyGeofenceToggle();
      final prefs = await SharedPreferences.getInstance();
      final ftEnabled = prefs.getBool('field_tracking_enabled') ?? false;
      if (!ftEnabled) {
        await GeofenceScheduler.stopGeofenceService();
      }
      return;
    }

    bool isEnabled = GeofenceMonitor.isEnabled;

    if (!GeofenceMonitor.hasUserToggled) {
      debugPrint('SHELL: First launch — auto-enabling geofence');
      await GeofenceMonitor.setEnabled(true);
      ref.read(geofenceEnabledProvider.notifier).state = true;
      isEnabled = true;
    }

    // Sync enabled state to SharedPreferences for background isolate
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('geofence_auto_enabled', isEnabled);
    final readback = prefs.getBool('geofence_auto_enabled');
    debugPrint('SHELL: Geofence enabled in settings: $isEnabled, readback from prefs: $readback');

    if (isEnabled) {
      if (!mounted) return;
      // Phase 2: geofence-only users need no service process — native
      // geofences + WorkManager headless punch handle everything.  The
      // combined service starts here only when wifi auto / field tracking
      // actually need a live isolate.
      if (await GeofenceScheduler.serviceRequired()) {
        if (!await FieldTrackingService.isRunning) {
          debugPrint('SHELL: Starting combined service (wifi/tracking enabled)');
          await OemKeepAliveService.stop(); // keep-alive holds the process — stop it first
          await FieldTrackingService.start();
        } else {
          debugPrint('SHELL: Combined service already running');
        }
      } else {
        debugPrint('SHELL: Geofence-only — no service (native headless path)');
      }
      // Register OS geofences (native_geofence). The plugin's
      // initialTriggers:{enter} re-arms catch-up punches for zones the user
      // is already inside, so this is safe to run on every resume.
      await GeofenceMonitor.registerZones(providedDio: ref.read(dioClientProvider).dio);
    } else {
      await GeofenceMonitor.unregisterAll();
    }
  }

  void _onGeofenceToggle(bool? prev, bool next) async {
    debugPrint('SHELL_Toggle: geofence $prev -> $next');
    if (next) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('geofence_auto_enabled', true);

      if (Platform.isAndroid) {
        await _ensureBatteryOptimizationExempt();
      }

      final alreadyRunning = await FieldTrackingService.isRunning;
      debugPrint('SHELL_Toggle: geofence ON, service already running=$alreadyRunning');
      if (!alreadyRunning) {
        // Phase 2: geofence-only → no service (native headless path handles
        // everything).  Service only when wifi/tracking need a live isolate.
        if (await GeofenceScheduler.serviceRequired()) {
          debugPrint('SHELL_Toggle: starting combined service');
          await OemKeepAliveService.stop(); // keep-alive holds the process — stop it first
          await FieldTrackingService.start();
        } else {
          debugPrint('SHELL_Toggle: geofence-only — service not started (native headless)');
        }
      }
      await GeofenceMonitor.registerZones(providedDio: ref.read(dioClientProvider).dio);
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('geofence_auto_enabled', false);

      await GeofenceMonitor.unregisterAll();

      final ftEnabled = prefs.getBool('field_tracking_enabled') ?? false;
      debugPrint('SHELL_Toggle: geofence OFF, field_tracking_enabled=$ftEnabled');
      FieldTrackingService.notifyGeofenceToggle();
      if (!ftEnabled) {
        debugPrint('SHELL_Toggle: stopping combined service (no field tracking either)');
        GeofenceScheduler.stopGeofenceService();
      } else {
        debugPrint('SHELL_Toggle: keeping combined service (field tracking active)');
      }
    }
  }

  // ── Geofence Scheduler lifecycle (independent of GeofenceMonitor) ──

  /// Fetch shifts, cache them, and start the combined background service if
  /// within the current shift window.  Runs on every app start so that the
  /// service starts even when geofence auto-punch is disabled in settings.
  Future<void> _initGeofenceScheduler() async {
    if (!mounted) {
      debugPrint('SHELL: _initGeofenceScheduler() — not mounted');
      return;
    }
    debugPrint('SHELL: _initGeofenceScheduler() triggered');

    // Aggressive-OEM detection (MIUI & friends) — cached for headless reads.
    await AggressiveOem.refreshFromNative();

    // Guaranteed background punch-out: arm the 15-min containment alarm
    // (main isolate can reach the MethodChannel).  Once armed, the native
    // receiver self-perpetuates and only the prefs flag (flipped by
    // headless punches) matters — the app never needs opening again.
    // On aggressive OEMs also starts the keep-alive foreground service.
    GeofenceScheduler.armContainmentAlarmIfNeeded().catchError((_) {});

    // Try cached shifts first (fast path — no API call)
    final cached = ShiftService.loadCachedShifts();
    debugPrint('SHELL: Cached shifts count: ${cached.length}');
    if (cached.isNotEmpty) {
      GeofenceScheduler.startIfWithinShiftWindow(cached).catchError((_) {});
      return;
    }

    // No cached shifts yet (first launch) — fetch via API
    try {
      debugPrint('SHELL: No cached shifts — fetching via API');
      final dio = ref.read(dioClientProvider).dio;
      final shiftService = ShiftService(dio);
      final shifts = await shiftService.fetchShifts();
      debugPrint('SHELL: Fetched ${shifts.length} shifts from API');
      if (shifts.isNotEmpty && mounted) {
        await ShiftService.cacheShifts(shifts);
        // cacheShifts already calls startIfWithinShiftWindow via _scheduleAlarm
      }
    } catch (e) {
      debugPrint('SHELL: _initGeofenceScheduler error: $e');
    }
  }

  // ── WiFi Auto lifecycle ────────────────────────────────────────────────────

  Future<void> _initWifiAuto() async {
    debugPrint('SHELL: _initWifiAuto() triggered');
    if (!mounted) return;

    // Sync enabled state to SharedPreferences for background worker
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('wifi_auto_punch_enabled_bg', WifiAutoPunchService.isEnabled);

    if (!WifiAutoPunchService.isEnabled) {
      debugPrint('SHELL: WiFi Auto-Punch is disabled in Hive');
      return;
    }

    final perms = ref.read(accessPermissionsProvider).value;
    debugPrint('SHELL: WiFi Auto permissions: ${perms?.allowWiFi}');
    if (perms?.allowWiFi != true) {
      debugPrint('SHELL: WiFi Auto-Punch not allowed by permissions');
      return;
    }

    // Request notification permission (required for foreground service on Android 13+)
    if (Platform.isAndroid) {
      final notifStatus = await Permission.notification.request();
      debugPrint('SHELL: POST_NOTIFICATIONS permission: ${notifStatus.isGranted}');
    }

    _startWifiAutoService();
  }

  Future<void> _startWifiAutoService() async {
    debugPrint('SHELL: Starting WiFi Auto-Punch service...');
    _wifiAutoService = WifiAutoPunchService(
      dio: ref.read(dioClientProvider).dio,
      notifications: localNotifications,
      onPunch: () {
        debugPrint('WIFI_AUTO: UI Refresh triggered by auto-punch callback');
        if (mounted) {
          ref.invalidate(attendanceStatusProvider);
        }
      },
    );
    _wifiAutoService!.start();

    // Start the combined background service so WifiBackgroundWorker runs
    // even when the app is killed. Must be after POST_NOTIFICATIONS grant.
    if (!await FieldTrackingService.isRunning) {
      debugPrint('SHELL: Starting background service for WiFi auto-punch');
      try {
        await FieldTrackingService.start();
      } catch (e) {
        debugPrint('SHELL: Failed to start background service for WiFi: $e');
      }
    }
  }

  Future<void> _onWifiAutoToggle(bool? prev, bool next) async {
    debugPrint('SHELL: WiFi Auto-Punch toggled -> $next');
    if (next) {
      await _startWifiAutoService();
    } else {
      debugPrint('SHELL: Stopping WiFi Auto-Punch service');
      _wifiAutoService?.stop();
      _wifiAutoService = null;
    }
  }

  // ── Field tracking lifecycle ───────────────────────────────────────────────

  Future<void> _initFieldTracking() async {
    if (!mounted) return;
    debugPrint('SHELL_FT: _initFieldTracking()');

    final alreadyRunning = await FieldTrackingService.isRunning;
    debugPrint('SHELL_FT: alreadyRunning=$alreadyRunning');
    if (mounted) {
      ref.read(fieldTrackingRunningProvider.notifier).state = alreadyRunning;
    }
    if (alreadyRunning) return;

    // Request permission once here — never inside the service, as that would
    // block the Riverpod punch-flow listener.
    var permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
    }
    if (permission == geo.LocationPermission.denied ||
        permission == geo.LocationPermission.deniedForever) {
      return;
    }

    final perms = ref.read(accessPermissionsProvider).value;
    if (perms?.allowFieldTracking != true) return;

    final status = ref.read(attendanceStatusProvider).value;
    if (status?.isPunchedIn == true) {
      await _startFieldTracking();
    }
  }

  Future<void> _startFieldTracking() async {
    final perms = ref.read(accessPermissionsProvider).value;
    if (perms?.allowFieldTracking != true) return;

    // On Android, request battery-optimization exemption before starting the
    // foreground service.  Without it Doze mode can pause the Dart timer and
    // GPS stream on most OEM ROMs (Xiaomi, Samsung, OPPO, Realme, Vivo).
    // iOS has no equivalent concept so we skip this entirely on that platform.
    if (Platform.isAndroid) {
      await _ensureBatteryOptimizationExempt();
    }

    // Signal the combined entrypoint that field tracking pings are active
    (await SharedPreferences.getInstance()).setBool('field_tracking_enabled', true);
    await FieldTrackingService.start();
  }

  /// Checks whether the app is excluded from battery optimisation.
  ///
  /// Only called on EXPLICIT user intent (geofence toggled ON, field tracking
  /// started) — never on silent first-launch auto-enable.  Scenarios:
  /// 1. Already exempt → returns immediately, no UI shown.
  /// 2. Dialog already visible → returns immediately (no stacking).
  /// 3. User dismissed "Not Now" this session → returns immediately.
  /// 4. Not exempt + user taps "Allow" → opens system dialog, then returns
  ///    (tracking starts regardless of what the user chose there).
  /// 5. Not exempt + user taps "Not Now" → returns without the system dialog.
  Future<void> _ensureBatteryOptimizationExempt() async {
    if (_batteryDialogVisible || _batteryPromptDismissed) return;
    final alreadyExempt =
        await Permission.ignoreBatteryOptimizations.isGranted;
    if (alreadyExempt) return;

    if (!mounted) return;

    _batteryDialogVisible = true;
    try {
      final proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _BatteryExemptionDialog(),
      );
      if (!mounted) return;

      if (proceed == true) {
        // Opens the system "Ignore battery optimizations" dialog.  Tracking
        // starts regardless of what the user chooses there.
        await Permission.ignoreBatteryOptimizations.request();
      } else {
        _batteryPromptDismissed = true;
      }
    } finally {
      _batteryDialogVisible = false;
    }
  }

  void _stopFieldTracking() {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool('field_tracking_enabled', false);

      // Stop the combined service only if geofence is also off
      final gfEnabled = prefs.getBool('geofence_auto_enabled') ?? false;
      if (!gfEnabled) {
        GeofenceScheduler.stopGeofenceService();
      }
    });
  }

  void _onAttendanceStatusChanged(
    AsyncValue<EmployeeStatus?>? previous,
    AsyncValue<EmployeeStatus?> next,
  ) {
    final prevPunched = previous?.value?.isPunchedIn ?? false;
    final nextPunched = next.value?.isPunchedIn ?? false;
    debugPrint('SHELL_Punch: prevIn=$prevPunched nextIn=$nextPunched');

    // Sync WiFi Auto-Punch internal state with real server data
    if (next.hasValue) {
      final statusStr = nextPunched ? 'In' : 'Out';
      _wifiAutoService?.syncState(
        status: statusStr,
        officeName: next.value?.officeName,
      );
      debugPrint('UI: Attendance status updated. Punched In: $nextPunched');

      // Persist punch state for the background service notification
      SharedPreferences.getInstance().then((prefs) async {
        await prefs.setString('gf_last_punch_type', statusStr);
        await prefs.setString('gf_last_punch_time', DateTime.now().toIso8601String());
        if (nextPunched && next.value?.officeName != null) {
          prefs.setString('gf_last_punch_office', next.value!.officeName!);
        }
        // Keep-alive FGS is punch-state lifecycle: manual OUT (or any
        // server-side state change) must close the FGS, manual IN must
        // start the walk-out monitor.  No-op on no transition.
        await OemKeepAliveService.syncToPunchState();
      });
    }

    if (!prevPunched && nextPunched) {
      debugPrint('SHELL_Punch: punched IN -> starting field tracking');
      SharedPreferences.getInstance().then((sp) => sp.remove('gf_shift_ended'));
      _startFieldTracking();

      if (ref.read(manualPunchInProvider)) {
        debugPrint('SHELL_Punch: manual punch IN -> setting manualIn guard');
        WifiAutoPunchService.setManualIn();
        WifiAutoPunchService.markLastInManual();
        ref.read(manualPunchInProvider.notifier).state = false;
      }
    } else if (prevPunched && !nextPunched) {
      if (ref.read(manualPunchOutProvider)) {
        debugPrint('SHELL_Punch: manual punch OUT -> stopping geofence for the day');
        WifiAutoPunchService.setManualOutOnWifi();
        WifiAutoPunchService.clearLastInMethod();
        _stopFieldTracking();
        ref.read(manualPunchOutProvider.notifier).state = false;
      } else {
        SharedPreferences.getInstance().then((sp) async {
          await sp.reload();
          if (sp.getBool('gf_shift_ended') == true) {
            debugPrint('SHELL_Punch: auto punch OUT after shift end -> stopping geofence');
            await sp.remove('gf_shift_ended');
            _stopFieldTracking();
          } else {
            debugPrint('SHELL_Punch: auto punch OUT -> keeping geofence running for re-entry');
          }
        });
      }
    }
  }

  // ── FCM lifecycle ──────────────────────────────────────────────────────────

  Future<void> _initFCM() async {
    try {
      // Firebase init is deferred in main() (non-blocking).  Wait until it
      // is ready so token registration does not race it (max 8s).
      if (Firebase.apps.isEmpty) {
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (Firebase.apps.isEmpty && DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
      }
      await FCMService(ref, onDeepLink: _handleDeepLink).initialize();
    } catch (_) {
      // Firebase not configured or permission denied — fail silently.
    }
  }

  void _handleDeepLink(String route, Map<String, dynamic> data) {
    if (!mounted) return;
    switch (route) {
      case '/leaves':
        Navigator.push(
            context, MaterialPageRoute(builder: (_) => const LeaveScreen()));
      case '/regularization':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const RegularizationScreen()));
      case '/payslip':
        Navigator.push(
            context, MaterialPageRoute(builder: (_) => const PayslipScreen()));
      case '/attendance':
        Navigator.push(context,
            MaterialPageRoute(builder: (_) => const HistoryHubScreen()));
    }
  }

  // ── Local notification tap routing ────────────────────────────────────────

  /// Register the local-notification tap handler and replay any notification
  /// tap that launched the app from a cold start.
  Future<void> _initLocalNotificationTap() async {
    localNotificationTapHandler = _handleLocalNotificationPayload;
    try {
      final launch = await localNotifications.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        _handleLocalNotificationPayload(launch?.notificationResponse?.payload);
      }
    } catch (_) {
      // getNotificationAppLaunchDetails can throw on some platforms — ignore.
    }
  }

  /// Route a local notification tap to the right screen. Currently handles the
  /// client-site punch prompt (fired by the background geofence worker when the
  /// user enters a client-site zone — selfie is mandatory, so we open the
  /// selfie screen with the site preselected + live location shown).
  void _handleLocalNotificationPayload(String? payload) {
    if (!mounted || payload == null) return;
    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) data = decoded;
    } catch (_) {
      return;
    }
    if (data == null || data['type'] != 'client_site_punch') return;

    final direction = data['direction'] as String? ?? 'In';
    final clientSiteId = (data['clientSiteId'] as num?)?.toInt();
    debugPrint('SHELL_LocalNotif: client_site_punch direction=$direction site=$clientSiteId');

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ClientSiteScreen(
          direction: direction,
          initialSiteId: clientSiteId,
        ),
      ),
    );
  }

  // ── Punch sheet ────────────────────────────────────────────────────────────

  void _showPunchSheet() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const PunchFlowScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final index = ref.watch(_shellIndexProvider);
    final unreadCount = ref.watch(unreadNotificationsCountProvider);
    final wifiAutoEnabled = ref.watch(wifiAutoEnabledProvider);
    debugPrint('SHELL: build() - index: $index, wifiAutoEnabled: $wifiAutoEnabled');

    ref.listen<bool>(geofenceEnabledProvider, _onGeofenceToggle);
    ref.listen<bool>(wifiAutoEnabledProvider, _onWifiAutoToggle);
    ref.listen<AsyncValue<EmployeeStatus?>>(
        attendanceStatusProvider, _onAttendanceStatusChanged);
    // Start field tracking if permissions arrive after _initFieldTracking ran.
    ref.listen(accessPermissionsProvider, (_, next) {
      if (next.hasValue) {
        debugPrint('SHELL: Permissions updated, re-checking WiFi/Tracking/Geofence init');
        _initWifiAuto(); // Ensure WiFi service starts when permissions arrive
        _initGeofence(); // Ensure Geofence service starts when permissions arrive
        
        if (next.value?.allowFieldTracking == true &&
            !ref.read(fieldTrackingRunningProvider)) {
          final status = ref.read(attendanceStatusProvider).value;
          if (status?.isPunchedIn == true) _startFieldTracking();
        }
      }
    });
    ref.listen<AsyncValue<bool>>(isOnlineProvider, (previous, next) {
      final wasOffline = previous?.value == false;
      final isNowOnline = next.value == true;
      final isNowOffline = next.value == false;
      if (wasOffline && isNowOnline) {
        _popOfflineScreen();
        _syncOfflinePunches();
      } else if (isNowOffline && !_offlineScreenPushed) {
        _pushOfflineScreen();
      }
    });

    void onTab(int i) => ref.read(_shellIndexProvider.notifier).state = i;

    Widget navItem(IconData idle, IconData active, String label, int idx) {
      final sel = index == idx;
      return InkWell(
        onTap: () => onTab(idx),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(sel ? active : idle,
                  size: 22,
                  color: sel ? AppColors.primary : AppColors.gray),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: sel ? AppColors.primary : AppColors.gray,
                  fontWeight: sel ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return WillStartForegroundTask(
      onWillStart: () async {
        return GeofenceMonitor.isEnabled;
      },
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'geofence_service_channel',
        channelName: 'Geofence Monitor',
        channelDescription: 'Keeps the geofence auto-punch service running in the background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        isSticky: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        isOnceEvent: false,
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
      notificationTitle: 'Geofence Monitor Active',
      notificationText: 'MAttendance is monitoring your office zones',
      child: Scaffold(
        body: Stack(
          children: [
            IndexedStack(index: index, children: _tabs),
            const AccuracyDebugOverlay(),
          ],
        ),

        floatingActionButton: Consumer(
          builder: (_, ref, _) {
            final status = ref.watch(attendanceStatusProvider).value;
            final color = status?.isOnBreak == true
                ? AppColors.warning
                : status?.isPunchedIn == true
                    ? AppColors.error
                    : AppColors.success;
            return SizedBox(
              width: 56,
              height: 56,
              child: FloatingActionButton(
                onPressed: _showPunchSheet,
                backgroundColor: color,
                elevation: 4,
                shape: const CircleBorder(),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      status?.isOnBreak == true
                          ? Icons.coffee_outlined
                          : status?.isPunchedIn == true
                              ? Icons.logout
                              : Icons.fingerprint,
                      color: Colors.white,
                      size: 16,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      status?.isOnBreak == true
                          ? 'BREAK\nEND'
                          : status?.isPunchedIn == true
                              ? 'PUNCH\nOUT'
                              : 'PUNCH\nIN',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,

        bottomNavigationBar: BottomAppBar(
          shape: const CircularNotchedRectangle(),
          notchMargin: 6,
          padding: EdgeInsets.zero,
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: SafeArea(
            child: SizedBox(
              height: 56,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  navItem(Icons.home_outlined, Icons.home, 'Home', 0),
                  navItem(Icons.calendar_today_outlined, Icons.calendar_today,
                      'History', 1),
                  const SizedBox(width: 56), // FAB gap
                  navItem(Icons.flight_takeoff_outlined, Icons.flight_takeoff,
                      'Leave', 2),
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      navItem(Icons.person_outline, Icons.person, 'Profile', 3),
                      if (unreadCount > 0)
                        Positioned(
                          top: 2,
                          right: 12,
                          child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: AppColors.getError(Theme.of(context).brightness == Brightness.dark),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _checkOfflineOnStart() async {
    if (!mounted) return;
    final isOnline = await ref.read(connectivityMonitorProvider).isOnline;
    if (!isOnline && !_offlineScreenPushed) {
      _pushOfflineScreen();
    }
  }

  Future<void> _pushOfflineScreen() {
    _offlineScreenPushed = true;
    return Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => const OfflineScreen(),
        settings: const RouteSettings(name: 'offline_screen'),
      ),
    ).then((_) {
      _offlineScreenPushed = false;
    });
  }

  void _popOfflineScreen() {
    if (!_offlineScreenPushed) return;
    _offlineScreenPushed = false;
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _syncOfflinePunches() async {
    if (ref.read(offlineQueueServiceProvider).pendingCount == 0) return;

    final result =
        await ref.read(syncServiceProvider).syncPendingPunches();
    if (!mounted) return;

    ref.read(pendingOfflineCountProvider.notifier).state =
        ref.read(offlineQueueServiceProvider).pendingCount;

    if (result.synced > 0) {
      ref.invalidate(attendanceStatusProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.failed == 0
                ? '${result.synced} offline punch${result.synced == 1 ? '' : 'es'} synced!'
                : '${result.synced} synced, ${result.failed} failed',
          ),
          backgroundColor:
              result.failed == 0 
                  ? AppColors.getSuccess(Theme.of(context).brightness == Brightness.dark) 
                  : AppColors.getWarning(Theme.of(context).brightness == Brightness.dark),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
}

// ── Punch sheet ───────────────────────────────────────────────────────────────

class _PunchSheet extends ConsumerWidget {
  const _PunchSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(attendanceStatusProvider);
    final permissionsAsync = ref.watch(accessPermissionsProvider);

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        top: 16,
        left: 24,
        right: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.border,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 20),

          // Method selector chips
          permissionsAsync.maybeWhen(
            data: (perms) => MethodSelector(permissions: perms),
            orElse: () => const SizedBox.shrink(),
          ),
          const SizedBox(height: 24),

          // Punch button
          Center(
            child: statusAsync.when(
              loading: () => const CircularProgressIndicator(),
              error: (_, _) => const SizedBox.shrink(),
              data: (status) => PunchButton(status: status),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ── Profile tab ───────────────────────────────────────────────────────────────

class _ProfileTab extends ConsumerStatefulWidget {
  const _ProfileTab();

  @override
  ConsumerState<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends ConsumerState<_ProfileTab> {
  bool _uploading = false;

  Future<void> _pickAndUpload(ImageSource source) async {
    Navigator.pop(context); // close bottom sheet
    setState(() => _uploading = true);
    try {
      await ref.read(authNotifierProvider.notifier).uploadProfilePhoto(source);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile photo updated')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _showPhotoOptions() {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take Photo'),
              onTap: () => _pickAndUpload(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from Gallery'),
              onTap: () => _pickAndUpload(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
  }

  String _initials(String name) {
    if (name.trim().isEmpty) return '';
    final parts = name.trim().split(' ');
    if (parts.isEmpty || parts.first.isEmpty) return '';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = ref.watch(authNotifierProvider).value;
    final geofenceEnabled = ref.watch(geofenceEnabledProvider);
    final allowFieldTracking =
        ref.watch(accessPermissionsProvider).value?.allowFieldTracking ?? false;
    final allowGeofenceAuto =
        ref.watch(accessPermissionsProvider).value?.allowGeofenceAuto ?? false;
    final allowWiFi =
        ref.watch(accessPermissionsProvider).value?.allowWiFi ?? false;
    final fieldTrackingRunning = ref.watch(fieldTrackingRunningProvider);
    final unreadCount = ref.watch(unreadNotificationsCountProvider);
    final themeMode = ref.watch(themeModeProvider);
    final isDark = themeMode == ThemeMode.dark;

    final photoUrl = user?.profilePhoto != null
        ? '${AppConstants.apiBaseUrl}/uploads/${user!.profilePhoto}'
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: ListView(
        children: [
          // ── User header ─────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _uploading ? null : _showPhotoOptions,
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: theme.colorScheme.primary.withAlpha(30),
                        child: photoUrl != null
                            ? ClipOval(
                                child: CachedNetworkImage(
                                  imageUrl: photoUrl,
                                  width: 60,
                                  height: 60,
                                  fit: BoxFit.cover,
                                  placeholder: (ctx, url) => Text(
                                    _initials(user?.fullName ?? ''),
                                    style: TextStyle(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                    ),
                                  ),
                                  errorWidget: (ctx, url, err) => Text(
                                    _initials(user?.fullName ?? ''),
                                    style: TextStyle(
                                      color: theme.colorScheme.primary,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                    ),
                                  ),
                                ),
                              )
                            : Text(
                                _initials(user?.fullName ?? ''),
                                style: TextStyle(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 18,
                                ),
                              ),
                      ),
                      // Camera badge
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.scaffoldBackgroundColor,
                              width: 1.5,
                            ),
                          ),
                          child: _uploading
                              ? Padding(
                                  padding: const EdgeInsets.all(3),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                    color: theme.colorScheme.onPrimary,
                                  ),
                                )
                              : Icon(
                                  Icons.camera_alt,
                                  size: 11,
                                  color: theme.colorScheme.onPrimary,
                                ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user?.fullName ?? '',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      if (user?.email != null)
                        Text(
                          user!.email,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: AppColors.textSecondary),
                        ),
                      const SizedBox(height: 2),
                      Text(
                        'Tap photo to update',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.textSecondary,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // ── Notifications ────────────────────────────────────────────────
          ListTile(
            leading: Badge(
              label: Text('$unreadCount'),
              isLabelVisible: unreadCount > 0,
              child: const Icon(Icons.notifications_outlined),
            ),
            title: const Text('Notifications'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const NotificationsScreen()),
            ),
          ),

          const Divider(height: 1),

          // ── Geofence ─────────────────────────────────────────────────────
          if (allowGeofenceAuto)
            SwitchListTile(
              secondary: Icon(
                Icons.radar,
                color: geofenceEnabled
                    ? theme.colorScheme.primary
                    : AppColors.gray,
              ),
              title: const Text('Geofence Auto-Punch'),
              subtitle: Text(
                geofenceEnabled
                    ? 'Active — monitoring office zones'
                    : 'Off — tap to enable automatic attendance',
                style: TextStyle(
                  color: geofenceEnabled ? AppColors.success : AppColors.gray,
                  fontSize: 12,
                ),
              ),
              value: geofenceEnabled,
              onChanged: (value) async {
                if (value) {
                  // Background permission is mandatory for geofencing to work when closed
                  final status = await geo.Geolocator.checkPermission();
                  if (status != geo.LocationPermission.always) {
                    if (mounted) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const GeofenceSettingsScreen()),
                      );
                    }
                    return;
                  }
                  // Mandatory MIUI battery-restrictions gate (user decision
                  // 2026-08-17) — same gate as the settings screen toggle.
                  if (await AggressiveOem.isAggressive() &&
                      !(await AggressiveOem.restrictionsConfirmed())) {
                    final confirmed = await ensureMiRestrictionsOff(context);
                    if (!confirmed) return;
                  }
                }
                await GeofenceMonitor.setEnabled(value);
                (await SharedPreferences.getInstance()).setBool('geofence_auto_enabled', value);
                ref.read(geofenceEnabledProvider.notifier).state = value;
              },
            ),
          if (allowGeofenceAuto)
            ListTile(
              leading: Icon(
                Icons.place_outlined,
                color: AppColors.gray,
              ),
              title: const Text('Geofence Places'),
              subtitle: const Text(
                'Offices & client sites used for auto-punch',
                style: TextStyle(fontSize: 12),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GeofencePlacesScreen()),
              ),
            ),
          if (allowGeofenceAuto) const Divider(height: 1),

          // ── WiFi Auto-Punch ──────────────────────────────────────────────
          if (allowWiFi)
            ListTile(
              leading: Consumer(builder: (context, ref, _) {
                final wifiEnabled = ref.watch(wifiAutoEnabledProvider);
                return Icon(
                  Icons.wifi_sharp,
                  color: wifiEnabled
                      ? theme.colorScheme.primary
                      : AppColors.gray,
                );
              }),
              title: const Text('WiFi Auto-Punch'),
              subtitle: Consumer(builder: (context, ref, _) {
                final wifiEnabled = ref.watch(wifiAutoEnabledProvider);
                return Text(
                  wifiEnabled ? 'On' : 'Off',
                  style: TextStyle(
                    color: wifiEnabled ? AppColors.success : AppColors.gray,
                    fontSize: 12,
                  ),
                );
              }),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const WifiSettingsScreen()),
              ),
            ),

          const Divider(height: 1),

          // ── Dark mode ────────────────────────────────────────────────────
          SwitchListTile(
            secondary: Icon(
              isDark ? Icons.dark_mode : Icons.light_mode,
              color: isDark ? theme.colorScheme.primary : AppColors.gray,
            ),
            title: const Text('Dark Mode'),
            subtitle: Text(
              isDark ? 'On' : 'Off',
              style: TextStyle(
                color: isDark ? AppColors.success : AppColors.gray,
                fontSize: 12,
              ),
            ),
            value: isDark,
            onChanged: (_) =>
                ref.read(themeModeProvider.notifier).toggle(),
          ),

          const Divider(height: 1),

          // ── Face Recognition ─────────────────────────────────────────────
          ListTile(
            leading: Icon(
              Icons.face_retouching_natural,
              color: AppColors.gray,
            ),
            title: const Text('Face Recognition'),
            subtitle: const Text(
              'Enroll your face for Face Recognition punch',
              style: TextStyle(fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => const FaceEnrollmentScreen()),
            ),
          ),

          const Divider(height: 1),

          // ── Field Tracking ───────────────────────────────────────────────
          if (allowFieldTracking)
            ListTile(
              leading: Icon(
                Icons.location_on_outlined,
                color: fieldTrackingRunning
                    ? AppColors.success
                    : AppColors.gray,
              ),
              title: const Text('Field Tracking'),
              subtitle: Text(
                fieldTrackingRunning ? 'Active' : 'Off',
                style: TextStyle(
                  color: fieldTrackingRunning
                      ? AppColors.success
                      : AppColors.gray,
                  fontSize: 12,
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => MyFieldTrackingScreen()),
              ),
            ),

          if (allowFieldTracking) const Divider(height: 1),

          // ── Debug Log ─────────────────────────────────────────────────────
          if (DevFlags.kDevMode) ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined, color: AppColors.gray),
              title: const Text('Debug Log'),
              subtitle: const Text('View geofence & service logs', style: TextStyle(fontSize: 12)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DebugLogScreen()),
              ),
            ),
          ],

          // ── Sign out ────────────────────────────────────────────────────
          ListTile(
            leading: const Icon(Icons.logout, color: AppColors.error),
            title: const Text('Sign Out',
                style: TextStyle(color: AppColors.error)),
            onTap: () =>
                ref.read(authNotifierProvider.notifier).logout(),
          ),
        ],
      ),
    );
  }
}

// ── Battery-exemption dialog ─────────────────────────────────────────────────

/// Benefit-first explanation dialog shown before the system "Ignore battery
/// optimizations" prompt.  Sells the outcome ("auto punch keeps working"),
/// not the permission ("we need background access").  The full technical
/// explanation is collapsed behind "Why this is needed?" so it never blocks
/// the primary message.
class _BatteryExemptionDialog extends StatefulWidget {
  const _BatteryExemptionDialog();

  @override
  State<_BatteryExemptionDialog> createState() => _BatteryExemptionDialogState();
}

class _BatteryExemptionDialogState extends State<_BatteryExemptionDialog> {
  bool _showDetails = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.bolt, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          const Expanded(child: Text('Never Miss a Punch')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Primary pitch — benefit only, two short lines.
            const Text(
              'Your attendance records itself — automatically.',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Auto punch-in and punch-out keep working even when your phone '
              'is locked or the app is closed.',
              style: TextStyle(
                fontSize: 14,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: 12),
            if (_showDetails) ...[
              const Divider(height: 1),
              const SizedBox(height: 12),
              // Full explanation — hidden unless the user asks.
              Text(
                'MAttendance continuously checks your location to detect when '
                'you arrive at or leave your office. Some phones pause such '
                'background apps to save battery, which can delay or skip a '
                'punch.\n\n'
                'Allowing background running (choose "Don\'t optimize" on the '
                'next screen) keeps this monitoring active so every punch is '
                'recorded on time.',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
            const SizedBox(height: 4),
            // Expandable rationale — small, out of the way.
            TextButton.icon(
              onPressed: () =>
                  setState(() => _showDetails = !_showDetails),
              icon: Icon(
                _showDetails ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
              label: Text(_showDetails ? 'Hide details' : 'Why this is needed'),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 36),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Not Now'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, true),
          icon: const Icon(Icons.verified_user_outlined, size: 18),
          label: const Text('Keep It Working'),
        ),
      ],
    );
  }
}
