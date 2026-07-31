import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/auth/auth_provider.dart';
import '../../core/config/dev_flags.dart';
import '../../core/utils/constants.dart';
import '../../core/notifications/fcm_service.dart';
import '../../core/notifications/local_notifications.dart';
import '../../core/offline/offline_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/theme_provider.dart';
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
import '../punch/services/geofence_auto_punch_service.dart';
import '../punch/services/geofence_scheduler.dart';
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

// ── Shell ─────────────────────────────────────────────────────────────────────

final _shellIndexProvider = StateProvider<int>((ref) => 0);

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with WidgetsBindingObserver {
  GeofenceAutoPunchService? _geofenceService;
  WifiAutoPunchService? _wifiAutoService;
  StreamSubscription<bool>? _trackingRunSub;
  StreamSubscription<Map<String, dynamic>>? _punchSub;
  StreamSubscription<Map<String, dynamic>>? _wifiPunchSub;
  bool _offlineScreenPushed = false;

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
      _initGeofence();
      _initWifiAuto();
      _initFieldTracking();
      _initGeofenceScheduler();
      fetchUnreadCount(ref);
      _initFCM();
      _syncOfflinePunches();
      _checkOfflineOnStart();
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
        final isEnabled = GeofenceAutoPunchService.isEnabled;
        debugPrint('SHELL_Lifecycle: syncing geofence_auto_enabled=$isEnabled');
        prefs.setBool('geofence_auto_enabled', isEnabled);
      });

      // 4. Ensure the combined service is running if within shift window
      _initGeofenceScheduler();

      // 5. Try syncing offline punches on resume
      _syncOfflinePunches();

      // 6. Refresh dashboard data so it's never stale on resume
      ref.invalidate(attendanceStatusProvider);
    }
  }

  // ── Geofence lifecycle ─────────────────────────────────────────────────────

  Future<void> _initGeofence() async {
    if (!mounted) return;
    debugPrint('SHELL: _initGeofence() triggered — GeofenceAutoPunchService.isEnabled=${GeofenceAutoPunchService.isEnabled}');

    final perms = ref.read(accessPermissionsProvider).value;
    if (perms == null) {
      // Perms still loading / fetch failed — do nothing (never revoke on
      // transient failure).
      debugPrint('SHELL: Geofence perms unknown (loading) — skipping init');
      return;
    }
    if (!perms.allowGeofenceAuto) {
      debugPrint('SHELL: Geofence not permitted by backend — stopping geofence service/alarms');
      // Definitive denial → revoke the background path: cancel shift alarms
      // and tell the running service geofence is off.  The combined service
      // stays alive if field tracking needs it.
      await GeofenceScheduler.cancel();
      FieldTrackingService.notifyGeofenceToggle();
      final prefs = await SharedPreferences.getInstance();
      final ftEnabled = prefs.getBool('field_tracking_enabled') ?? false;
      if (!ftEnabled) {
        await GeofenceScheduler.stopGeofenceService();
      }
      return;
    }

    bool isEnabled = GeofenceAutoPunchService.isEnabled;

    if (!GeofenceAutoPunchService.hasUserToggled) {
      debugPrint('SHELL: First launch — auto-enabling geofence');
      await GeofenceAutoPunchService.setEnabled(true);
      ref.read(geofenceEnabledProvider.notifier).state = true;
      isEnabled = true;
    }

    // Sync enabled state to SharedPreferences for background isolate
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('geofence_auto_enabled', isEnabled);
    final readback = prefs.getBool('geofence_auto_enabled');
    debugPrint('SHELL: Geofence enabled in settings: $isEnabled, readback from prefs: $readback');

    // Stop the legacy GeofenceAutoPunchService if it was started by a previous version
    _geofenceService?.stop();
    _geofenceService = null;

    if (isEnabled) {
      if (Platform.isAndroid) {
        await _ensureBatteryOptimizationExempt();
      }
      if (!mounted) return;
      if (!await FieldTrackingService.isRunning) {
        debugPrint('SHELL: Starting combined service (geofence enabled)');
        await FieldTrackingService.start();
      } else {
        debugPrint('SHELL: Combined service already running');
      }
    }
  }

  Future<void> _startGeofenceService() async {
    if (!mounted) return;
    if (Platform.isAndroid) {
      await _ensureBatteryOptimizationExempt();
    }
    if (!mounted) return;

    _geofenceService = GeofenceAutoPunchService(
      dio: ref.read(dioClientProvider).dio,
      notifications: localNotifications,
      onPunch: () {
        if (mounted) {
          ref.invalidate(attendanceStatusProvider);
        }
      },
    );
    final started = await _geofenceService!.start();
    if (!started) _geofenceService = null;
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
        debugPrint('SHELL_Toggle: starting combined service');
        await FieldTrackingService.start();
      }
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('geofence_auto_enabled', false);

      _geofenceService?.stop();
      _geofenceService = null;

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

  // ── Geofence Scheduler lifecycle (independent of GeofenceAutoPunchService) ──

  /// Fetch shifts, cache them, and start the combined background service if
  /// within the current shift window.  Runs on every app start so that the
  /// service starts even when geofence auto-punch is disabled in settings.
  Future<void> _initGeofenceScheduler() async {
    if (!mounted) {
      debugPrint('SHELL: _initGeofenceScheduler() — not mounted');
      return;
    }
    debugPrint('SHELL: _initGeofenceScheduler() triggered');

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
  /// Scenarios handled:
  /// 1. Already excluded  → returns immediately, no UI shown.
  /// 2. Not excluded + user taps "Allow"  → opens system dialog, waits, then
  ///    returns (tracking starts regardless of what the user chose there).
  /// 3. Not excluded + user taps "Not Now" → returns without opening the
  ///    system dialog (tracking still starts but may be unreliable).
  /// 4. Widget unmounted during any await  → returns early, no dialog shown.
  Future<void> _ensureBatteryOptimizationExempt() async {
    // Scenario 1: already exempt — nothing to do.
    final alreadyExempt =
        await Permission.ignoreBatteryOptimizations.isGranted;
    if (alreadyExempt) return;

    if (!mounted) return; // Scenario 4

    // Scenarios 2 & 3: show an explanation dialog first so the user
    // understands *why* this system prompt is appearing.
    final proceed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Allow Background Tracking'),
        content: const Text(
          'To keep tracking your location when the app is minimized or the '
          'screen is off, please disable battery optimization for this app.\n\n'
          'On the next screen choose "Don\'t optimize" to ensure uninterrupted '
          'field tracking.',
        ),
        actions: [
          TextButton(
            // Scenario 3: user declines — tracking still starts.
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not Now'),
          ),
          FilledButton(
            // Scenario 2: user agrees — open system dialog.
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );

    if (!mounted) return; // Scenario 4 — widget disposed while dialog was open

    if (proceed == true) {
      // Scenario 2: request opens the system "Ignore battery optimizations"
      // dialog.  We await it but don't gate tracking on the result — the
      // user may deny it and tracking should still start.
      await Permission.ignoreBatteryOptimizations.request();
    }
    // Scenario 3: proceed == false → fall through, tracking starts normally.
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
      SharedPreferences.getInstance().then((prefs) {
        prefs.setString('gf_last_punch_type', statusStr);
        prefs.setString('gf_last_punch_time', DateTime.now().toIso8601String());
        if (nextPunched && next.value?.officeName != null) {
          prefs.setString('gf_last_punch_office', next.value!.officeName!);
        }
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
        _geofenceService?.stop();
        ref.read(manualPunchOutProvider.notifier).state = false;
      } else {
        SharedPreferences.getInstance().then((sp) async {
          await sp.reload();
          if (sp.getBool('gf_shift_ended') == true) {
            debugPrint('SHELL_Punch: auto punch OUT after shift end -> stopping geofence');
            await sp.remove('gf_shift_ended');
            _stopFieldTracking();
            _geofenceService?.stop();
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
        return GeofenceAutoPunchService.isEnabled;
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
                }
                await GeofenceAutoPunchService.setEnabled(value);
                (await SharedPreferences.getInstance()).setBool('geofence_auto_enabled', value);
                ref.read(geofenceEnabledProvider.notifier).state = value;
              },
            ),
          if (allowGeofenceAuto) const Divider(height: 1),

          // ── WiFi Auto-Punch ──────────────────────────────────────────────
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
