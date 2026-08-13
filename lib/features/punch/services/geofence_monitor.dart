import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:hive_flutter/hive_flutter.dart';
import 'package:native_geofence/native_geofence.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/api/punch_state_interceptor.dart';
import '../../../core/offline/offline_queue.dart';
import '../../../core/offline/offline_sync_manager.dart';
import '../../../core/punch/punch_coordinator.dart';
import '../../../core/utils/constants.dart';
import '../../../models/client_site.dart';
import '../../../models/office.dart';
import '../../../models/offline_punch.dart';
import 'geofence_debug_bus.dart';
import 'oem_keep_alive_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// OS-native geofence auto-punch (native_geofence ^1.3.1)
//
// Replaces the discontinued geofence_service poller + the manual GPS-fix
// decision engine (confidence scoring, trend analyzer, Kalman filter).
// The OS (CLLocationManager / GeofencingClient) owns region monitoring and
// delivers enter/exit events — foreground, background, or terminated.
//
// Event flow (Android): OS GeofencingClient → NativeGeofenceBroadcastReceiver
// → WorkManager task → fresh Flutter engine running callbackDispatcher() →
// geofenceTriggered() below, in its OWN isolate.  Fully independent of
// flutter_background_service.
//
// Punch accuracy guarantees:
//   1. The OS only fires at the real zone boundary (no radius inflation).
//   2. Hybrid verification: every event re-checks a fresh high-accuracy fix
//      against the zone radius + accuracy margin before punching (guards
//      against false positives IN; the OS trigger location is the fallback).
//      OUT punches AT the OS exit crossing point (triggeringLocation) —
//      never at a later, far-away processing-time fix, which would skew the
//      punch-out distance way beyond the real boundary.
//   3. Server status + local punch state gates (proven behavior from the
//      old worker) prevent duplicate / toggle-misinterpreted punches.
//   4. Office-first hierarchy: a client-site prompt is suppressed while the
//      user is verified inside an office radius — office and a client site
//      may share coordinates, and office always wins.
// ─────────────────────────────────────────────────────────────────────────────

/// One punchable region, normalized from an [Office] or [ClientSite].
class GeofenceZone {
  final String id; // 'office_{id}' | 'site_{id}'
  final String name;
  final double latitude;
  final double longitude;
  final double radius; // meters (real backend radius)
  final bool isClientSite;
  final int? officeId;
  final int? clientSiteId;

  const GeofenceZone({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.radius,
    required this.isClientSite,
    this.officeId,
    this.clientSiteId,
  });

  factory GeofenceZone.fromOffice(Office o) => GeofenceZone(
        id: 'office_${o.id}',
        name: o.name,
        latitude: o.latitude!,
        longitude: o.longitude!,
        radius: o.geofenceRadius!.toDouble(),
        isClientSite: false,
        officeId: o.id,
      );

  factory GeofenceZone.fromClientSite(ClientSite s) => GeofenceZone(
        id: 'site_${s.id}',
        name: s.siteName,
        latitude: s.latitude,
        longitude: s.longitude,
        radius: s.radiusMeters.toDouble(),
        isClientSite: true,
        clientSiteId: s.id,
      );

  Map<String, dynamic> toJson() => {
        'name': name,
        'lat': latitude,
        'lng': longitude,
        'radius': radius,
        'isClientSite': isClientSite,
        'officeId': officeId,
        'clientSiteId': clientSiteId,
      };

  static GeofenceZone? fromJson(String id, Map<String, dynamic> json) {
    try {
      return GeofenceZone(
        id: id,
        name: json['name'] as String,
        latitude: (json['lat'] as num).toDouble(),
        longitude: (json['lng'] as num).toDouble(),
        radius: (json['radius'] as num).toDouble(),
        isClientSite: json['isClientSite'] as bool,
        officeId: json['officeId'] as int?,
        clientSiteId: json['clientSiteId'] as int?,
      );
    } catch (_) {
      return null;
    }
  }
}

// ── Zone registration + enabled flag (runs in the MAIN isolate) ─────────────

class GeofenceMonitor {
  GeofenceMonitor._();

  static const String _enabledKey = 'auto_punch_enabled';
  static const String _zoneMetaPrefix = 'gf_zone_';
  static const String _zoneIdsKey = 'gf_zone_ids';

  static Box get _box => Hive.box(AppConstants.geofenceSettingsBox);

  // ── Enabled flag (Hive — source of truth, mirrored to SharedPreferences) ──

  static bool get isEnabled =>
      _box.get(_enabledKey, defaultValue: true) as bool;

  static Future<void> setEnabled(bool value) async {
    await _box.put(_enabledKey, value);
  }

  static bool get hasUserToggled => _box.containsKey(_enabledKey);

  /// Register every punchable zone with the OS and persist zone metadata so
  /// the event-handler isolate can resolve names/radii without network.
  ///
  /// Call from the main isolate whenever zones may have changed or on every
  /// app start / geofence enable — registration is cheap and the plugin's
  /// `initialTriggers: {enter}` re-arms "already inside" catch-up punches.
  ///
  /// Guards: backend permission (`bg_allow_geofence_auto == false` blocks),
  /// enabled flag, auth token.
  ///
  /// [initialTriggers] controls whether re-creating a zone re-fires ENTER
  /// for the user being inside it.  Default `{enter}` re-arms catch-up
  /// punches (init / settings toggle / boot-heartbeat).  Pass an empty set
  /// when refreshing registered zones purely for self-healing (resume) —
  /// otherwise every background→foreground re-registers and re-fires ENTER,
  /// which surfaces as a duplicate "already punched" notification.  Containment
  /// catch-up for that path is handled by [reconcileContainment] instead.
  static Future<void> registerZones({
    Dio? providedDio,
    Set<GeofenceEvent> initialTriggers = const {GeofenceEvent.enter},
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    // Permission gate (same semantics as the old worker's _isEnabled).
    if (prefs.getBool('bg_allow_geofence_auto') == false) {
      debugPrint('[GF_MON] Backend denied geofence auto — unregistering');
      await unregisterAll();
      return;
    }
    if (!isEnabled) {
      debugPrint('[GF_MON] Geofence disabled in settings — unregistering');
      await unregisterAll();
      return;
    }
    final token = prefs.getString('bg_access_token');
    if (token == null || token.isEmpty) {
      debugPrint('[GF_MON] No auth token — unregistering');
      await unregisterAll();
      return;
    }

    final dio = providedDio ?? await _buildMainDio(prefs);
    if (dio == null) {
      debugPrint('[GF_MON] No dio — skipping registration');
      return;
    }

    // Client-site zones only join when BOTH geofence-auto AND client-site
    // are permitted (mirrors old worker _clientSitesAllowed).
    final sitesAllowed = prefs.getBool('bg_allow_client_site') == true;

    List<GeofenceZone> zones = [];
    try {
      final offices = await _fetchOffices(dio);
      zones.addAll(
        offices
            .where((o) => o.hasCoordinates && o.geofenceRadius != null)
            .map(GeofenceZone.fromOffice),
      );
      if (sitesAllowed) {
        final sites = await _fetchClientSites(dio);
        zones.addAll(sites.map(GeofenceZone.fromClientSite));
      }
    } catch (e) {
      debugPrint('[GF_MON] Zone fetch failed: $e');
      return;
    }

    if (zones.isEmpty) {
      debugPrint('[GF_MON] No zones — unregistering');
      await unregisterAll();
      return;
    }

    await _ensureInitialized();
    // Wipe + recreate: self-healing, and initial-enter re-arms catch-up
    // punches for zones the user is already inside.
    try {
      await NativeGeofenceManager.instance.removeAllGeofences();
    } catch (e) {
      debugPrint('[GF_MON] removeAll failed (continuing): $e');
    }
    await _persistZoneMetadata(zones);

    for (final z in zones) {
      final gf = Geofence(
        id: z.id,
        location: Location(latitude: z.latitude, longitude: z.longitude),
        radiusMeters: z.radius,
        triggers: {GeofenceEvent.enter, GeofenceEvent.exit},
        iosSettings: IosGeofenceSettings(initialTrigger: true),
        androidSettings: AndroidGeofenceSettings(
          initialTriggers: initialTriggers,
          notificationResponsiveness: const Duration(seconds: 30),
        ),
      );
      try {
        await NativeGeofenceManager.instance.createGeofence(gf, geofenceTriggered);
        debugPrint('[GF_MON] Registered ${z.id} (${z.name}, r=${z.radius}m)');
      } on NativeGeofenceException catch (e) {
        debugPrint('[GF_MON] createGeofence ${z.id} failed: ${e.code} ${e.message}');
      }
    }
  }

  /// Remove every geofence (geofence disabled / permission revoked / logout).
  static Future<void> unregisterAll() async {
    try {
      await _ensureInitialized();
      await NativeGeofenceManager.instance.removeAllGeofences();
      debugPrint('[GF_MON] All geofences unregistered');
    } catch (e) {
      debugPrint('[GF_MON] unregisterAll failed: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList(_zoneIdsKey) ?? const <String>[];
      for (final id in ids) {
        await prefs.remove('$_zoneMetaPrefix$id');
      }
      await prefs.remove(_zoneIdsKey);
    } catch (_) {}
  }

  /// Headless re-registration entry — runs inside the WorkManager shift-start
  /// callback isolate (no riverpod, no UI engine).  The shift-start alarm is
  /// the reboot-safe heartbeat: after a device reboot it is re-armed by the
  /// native BootReceiver, and when it fires this re-registers every OS
  /// geofence (idempotent wipe+recreate, self-guarding on
  /// permission/enabled/token) so the native auto-punch path self-heals
  /// without the app ever being opened.  Registration only needs prefs +
  /// plugin channels — both available headless.
  static Future<void> reRegisterFromHeadless() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if (!(prefs.getBool('geofence_auto_enabled') ?? false)) {
      debugPrint('[GF_MON] headless re-register: geofence disabled — skip');
      return;
    }
    debugPrint('[GF_MON] headless re-register: arming OS geofences');
    await registerZones(); // providedDio null → builds prefs-only dio internally
  }

  static Future<void> _ensureInitialized() async {
    try {
      await NativeGeofenceManager.instance.initialize();
    } catch (e) {
      debugPrint('[GF_MON] initialize failed: $e');
    }
  }

  static Future<void> _persistZoneMetadata(List<GeofenceZone> zones) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = <String>[];
    for (final z in zones) {
      ids.add(z.id);
      await prefs.setString('$_zoneMetaPrefix${z.id}', jsonEncode(z.toJson()));
    }
    await prefs.setStringList(_zoneIdsKey, ids);
  }

  static Future<List<Office>> _fetchOffices(Dio dio) async {
    final resp = await dio.get(ApiEndpoints.employeeOffices);
    final data = resp.data;
    final list = (data is List ? data : data['data'] ?? []) as List;
    return list.map((e) => Office.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<List<ClientSite>> _fetchClientSites(Dio dio) async {
    final resp = await dio.get(ApiEndpoints.clientSitesActive);
    final data = resp.data;
    final list = (data is List ? data : data['data'] ?? []) as List;
    return list.map((e) => ClientSite.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<Dio?> _buildMainDio(SharedPreferences prefs) async {
    final token = prefs.getString('bg_access_token');
    if (token == null || token.isEmpty) return null;
    return Dio(BaseOptions(
      baseUrl: AppConstants.apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Authorization': 'Bearer $token',
        'X-Client-Type': 'mobile',
        'X-Platform': Platform.isAndroid ? 'android' : 'ios',
      },
    ));
  }
}

// ── Event handler (runs in the plugin's OWN background isolate) ─────────────

/// Top-level entry-point required by native_geofence — resolves via callback
/// handle in any isolate.  Must remain a top-level function.
@pragma('vm:entry-point')
Future<void> geofenceTriggered(GeofenceCallbackParams params) async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[GF_MON] Event: ${params.event} zones=${params.geofences.map((g) => g.id).toList()}');
  try {
    await GeofencePunchHandler.instance.handleEvent(params);
  } catch (e) {
    debugPrint('[GF_MON] geofenceTriggered error: $e');
  }
}

class GeofencePunchHandler {
  GeofencePunchHandler._({
    Dio? testDio,
    Future<bool> Function(String direction, double lat, double lng)?
        queueOverride,
  })  : _testDio = testDio,
        _queueOverride = queueOverride;
  static GeofencePunchHandler? _instance;
  static GeofencePunchHandler get instance =>
      _instance ??= GeofencePunchHandler._();

  /// Test seam — builds a handler whose HTTP calls route through [dio].
  @visibleForTesting
  static GeofencePunchHandler forTest(
    Dio dio, {
    Future<bool> Function(String direction, double lat, double lng)?
        queueOverride,
  }) =>
      GeofencePunchHandler._(testDio: dio, queueOverride: queueOverride);

  /// Test seam — overrides the self-built background dio.
  final Dio? _testDio;

  /// Test seam — replaces the Hive-backed offline queue (Hive is unavailable
  /// in unit tests, so the queue decision needs injection to be testable).
  final Future<bool> Function(String direction, double lat, double lng)?
      _queueOverride;

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  bool _hiveReady = false;
  bool _notifInit = false;

  /// Dedupe window — the plugin fires duplicates after reboot (iOS) and
  /// Android may re-deliver a transition.  Same zone + direction within this
  /// window is ignored.
  static const Duration _dedupeWindow = Duration(seconds: 30);

  /// How far beyond a fence's radius an OS exit crossing point may lie and
  /// still count as THAT fence's genuine exit.  A real crossing sits at
  /// ~radius (GPS jitter adds a few tens of metres); a trigger point far
  /// beyond is a spurious batch exit (GPS toggle / provider drop) or an
  /// unrelated fence.
  static const double _outCrossingTolerance = 250.0;

  /// How far beyond a zone's radius a fix may sit and still confirm an IN
  /// punch — fixed slack, user spec "~20-25m close to a 20m-radius office →
  /// punch IN".  NEVER scales with radius: a 100m-radius office accepts at
  /// most 105m, not 150m (scaled margins were the 61m-IN bug).
  static const double _inSlackM = 5.0;

  /// How far beyond every office radius a fix must sit before the missed-
  /// EXIT path may punch OUT — fixed slack, user spec "out of radius +
  /// 25-30m → punch OUT".  Accuracy NEVER widens this band: the old
  /// 2x-accuracy margin delayed OUT until dist exceeded radius + up to
  /// 250m (the 149m miss).  Misleading-accuracy fixes are handled by the
  /// two-fix confirmation instead of band widening.
  static const double _outSlackM = 25.0;

  /// Reconcile GPS budget.  The background poll reconciles containment on
  /// every tick while the user is punched out; throttling fixes to one per
  /// window keeps the service's GPS-radio cost bounded (the dominant
  /// battery drain) while capping missed-IN recovery latency at
  /// budget + fix time.
  static const Duration _reconcileFixBudget = Duration(seconds: 90);

  /// How old a cached (last-known) position may be and still be trusted for
  /// containment.  A fix from yesterday at the office must NOT punch
  /// today's IN — stale data can fabricate an office visit.
  static const Duration _lastKnownMaxAge = Duration(minutes: 10);

  Future<void> handleEvent(GeofenceCallbackParams params) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    if (!_isEnabled(prefs)) {
      debugPrint('[GF_MON] Gate: geofence disabled / not permitted');
      return;
    }
    final token = prefs.getString('bg_access_token');
    if (token == null || token.isEmpty) {
      debugPrint('[GF_MON] Gate: no auth token');
      return;
    }

    for (final gf in params.geofences) {
      final zone = _loadZone(prefs, gf.id);
      if (zone == null) {
        debugPrint('[GF_MON] Unknown zone ${gf.id} — metadata missing');
        continue;
      }
      final direction = _directionFor(params.event);
      if (direction == null) {
        debugPrint('[GF_MON] ${gf.id}: ignoring ${params.event}');
        continue;
      }
      if (!_dedupe(prefs, zone, direction)) continue;
      await _handleZoneEvent(zone, direction, params.location, prefs);
    }
  }

  /// Background recovery for missed / deferred OS events.
  ///
  /// Some OEM ROMs (Doze / aggressive battery) defer geofence transition
  /// delivery while the app is backgrounded — a re-entry ENTER may never
  /// reach the app until foregrounded (no IN), or an EXIT may be dropped
  /// (stuck IN).  The combined service's 15s poll calls this to re-check
  /// containment:
  ///   - punched out + verified inside an office radius  → normal IN path
  ///   - punched in + verified OUTSIDE every office radius → OUT path, but
  ///     only after TWO consecutive polls both confirm (jump guard: a
  ///     single wifi-derived fix can sit 300-500m off).
  ///
  /// Returns true when a reconciliation punch was issued.
  ///
  /// [confirmOut] — resolve the missed-EXIT case in a SINGLE call: takes a
  /// second confirmatory fix back-to-back instead of waiting for the next
  /// poll (which may never come — geofence-only mode has no background
  /// poller, so the OS-missed exit would stay stuck until the user opens
  /// the app).  Same jump guard as the two-poll flow: both fixes must be
  /// outside and ≤800m apart.  Used by the app-resume path and the
  /// headless alignment worker; the service poll keeps the two-poll flow.
  Future<bool> reconcileContainment({bool confirmOut = false}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();

    if (!_isEnabled(prefs)) {
      debugPrint('[GF_MON] reconcile: geofence disabled / not permitted');
      return false;
    }
    final token = prefs.getString('bg_access_token');
    if (token == null || token.isEmpty) {
      debugPrint('[GF_MON] reconcile: no auth token');
      return false;
    }

    // GPS off → no dependable fix.  Wait for location to return; the next
    // poll (or app resume) will re-check and punch then.
    if (!await _locationServiceEnabled()) {
      debugPrint('[GF_MON] reconcile: location service disabled — deferring');
      return false;
    }

    final lastType = prefs.getString('gf_last_punch_type') ?? 'Out';

    // ── Punched IN → look for a missed EXIT ─────────────────────────────
    if (lastType == 'In') {
      return _reconcileOut(prefs, confirmOut: confirmOut);
    }

    // ── Punched OUT → look for a missed ENTER ───────────────────────────
    final ids = prefs.getStringList('gf_zone_ids') ?? const [];
    if (ids.isEmpty) return false;

    // WiFi owns this case: on a registered office AP the wifi worker
    // punches IN with zero GPS (BSSID match + confirm).  A GPS fix here
    // would be pure battery cost for a punch that is already coming.
    if ((prefs.getString('wifi_bg_matched_name') ?? '').isNotEmpty) {
      debugPrint('[GF_MON] reconcile: registered office WiFi — wifi worker owns IN');
      return false;
    }

    // One position reused for every office.  (The loop used to take one
    // high-accuracy fix per office — with N offices that is N full GPS
    // fixes every poll while punched out, the service's dominant battery
    // cost.)  Throttled to one attempt per budget window.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - (prefs.getInt('gf_reconcile_fix_ts') ?? 0) <
        _reconcileFixBudget.inMilliseconds) {
      debugPrint('[GF_MON] reconcile: fix budget window — skipping GPS');
      return false;
    }
    final fix = await _lastKnownOrFreshFix();
    await prefs.setInt(
        'gf_reconcile_fix_ts', DateTime.now().millisecondsSinceEpoch);
    if (fix == null) return false;

    for (final id in ids) {
      final zone = _loadZone(prefs, id);
      // Office containment only — client sites always prompt, never auto-punch.
      if (zone == null || zone.isClientSite) continue;

      final dist = geo.Geolocator.distanceBetween(
          fix.latitude, fix.longitude, zone.latitude, zone.longitude);
      // IN band: fixed 5m slack past the radius (user spec ~20-25m at a
      // 20m office).  Accuracy never widens — the old 2x-accuracy band
      // punched IN from 61m with a 20m radius.  This is the guarantee
      // path (no OS event): band check only.
      if (dist > zone.radius + _inSlackM) continue; // user not inside this office

      debugPrint('[GF_MON] reconcile: ${zone.id} contains user '
          '(${dist.toStringAsFixed(0)}m / r=${zone.radius}m) — punching IN');
      await _executePunch(zone, fix, prefs, 'In');
      return true;
    }
    debugPrint('[GF_MON] reconcile: no office contains user');
    return false;
  }

  /// Missed-EXIT recovery: user locally punched in but the OS exit event
  /// never arrived.  Requires two consecutive fixes outside EVERY office
  /// radius (hysteresis — a single wifi-provider fix can jump hundreds of
  /// metres and must not punch the user out), with implausible movement
  /// between the fixes treated as noise.
  ///
  /// With [confirmOut] the two fixes are taken back-to-back in this one
  /// call (app resume / headless worker — contexts with no next poll).
  /// Otherwise the first outside fix is stored and confirmed by the next
  /// poll (combined-service cadence).
  Future<bool> _reconcileOut(SharedPreferences prefs,
      {bool confirmOut = false}) async {
    final zones = (prefs.getStringList('gf_zone_ids') ?? const [])
        .map((id) => _loadZone(prefs, id))
        .whereType<GeofenceZone>()
        .where((z) => !z.isClientSite)
        .toList();
    if (zones.isEmpty) return false;

    // First fix: reuse the OS last-known position when fresh — a
    // stationary user inside the office (or at home) never turns on the
    // GPS radio.  Only when the cache says "outside" (or is stale) does
    // the confirm path below take fresh fixes.
    final fix = await _lastKnownOrFreshFix();
    if (fix == null) return false;

    bool insideAny = false;
    for (final zone in zones) {
      final dist = geo.Geolocator.distanceBetween(
          fix.latitude, fix.longitude, zone.latitude, zone.longitude);
      // OUT band: fixed 25m slack past the radius (user spec "out of
      // radius + 25-30m → punch OUT").  Accuracy never widens this check —
      // the old 2x-accuracy margin is what delayed OUT until 149m.
      if (dist <= zone.radius + _outSlackM) {
        insideAny = true;
        break;
      }
    }
    // User verified inside an office — nothing to reconcile (this poll may
    // be the missed IN's recovery instead).
    if (insideAny) {
      prefs.remove('gf_out_poll1_ts');
      return false;
    }

    // Inline confirmation: second fix now (must also be outside and close).
    if (confirmOut) {
      final fix2 = await _freshFix();
      if (fix2 == null) return false; // can't confirm → conservative: no punch
      for (final zone in zones) {
        final d = geo.Geolocator.distanceBetween(
            fix2.latitude, fix2.longitude, zone.latitude, zone.longitude);
        if (d <= zone.radius + _outSlackM) {
          debugPrint('[GF_MON] reconcile: confirm fix inside office — no OUT');
          return false;
        }
      }
      final moved = geo.Geolocator.distanceBetween(
          fix.latitude, fix.longitude, fix2.latitude, fix2.longitude);
      if (moved > 800) {
        debugPrint('[GF_MON] reconcile: ${moved.toStringAsFixed(0)}m jump between '
            'fixes — treating as noise, no OUT');
        return false;
      }
      return _punchOutConfirmed(prefs, zones, fix2);
    }

    // First outside poll — remember it, wait for confirmation next poll.
    const key = 'gf_out_poll1_ts';
    final lastTs = prefs.getString(key);
    if (lastTs == null) {
      await prefs.setString(key, DateTime.now().toIso8601String());
      await prefs.setString('gf_out_poll1_lat', fix.latitude.toString());
      await prefs.setString('gf_out_poll1_lng', fix.longitude.toString());
      debugPrint('[GF_MON] reconcile: outside all offices — poll #1 recorded, '
          'waiting for confirmation');
      return false;
    }

    // Movement sanity: fixes more than ~800m apart between polls are noise.
    final lat1 = double.tryParse(prefs.getString('gf_out_poll1_lat') ?? '');
    final lng1 = double.tryParse(prefs.getString('gf_out_poll1_lng') ?? '');
    final ts1 = DateTime.tryParse(lastTs);
    final stale = ts1 == null ||
        DateTime.now().difference(ts1) > const Duration(minutes: 2);
    if (stale || lat1 == null || lng1 == null) {
      // Marker is stale / corrupt — re-start the confirmation cycle.
      await prefs.setString(key, DateTime.now().toIso8601String());
      await prefs.setString('gf_out_poll1_lat', fix.latitude.toString());
      await prefs.setString('gf_out_poll1_lng', fix.longitude.toString());
      return false;
    }
    final moved = geo.Geolocator.distanceBetween(
        lat1, lng1, fix.latitude, fix.longitude);
    if (moved > 800) {
      debugPrint('[GF_MON] reconcile: ${moved.toStringAsFixed(0)}m jump between '
          'polls — treating as noise, re-starting confirmation');
      await prefs.setString(key, DateTime.now().toIso8601String());
      await prefs.setString('gf_out_poll1_lat', fix.latitude.toString());
      await prefs.setString('gf_out_poll1_lng', fix.longitude.toString());
      return false;
    }
    await prefs.remove(key);

    return _punchOutConfirmed(prefs, zones, fix);
  }

  /// Both confirmations passed — punch OUT in the zone the user is punched
  /// into (address attribution; fall back to the first office).
  Future<bool> _punchOutConfirmed(
      SharedPreferences prefs, List<GeofenceZone> zones, geo.Position fix) async {
    final inZoneId = prefs.getString('gf_last_punch_zone_id');
    final zone = zones.firstWhere((z) => z.id == inZoneId,
        orElse: () => zones.first);

    debugPrint('[GF_MON] reconcile: outside all offices confirmed — punching '
        'OUT (${zone.name})');
    await _executePunch(zone, fix, prefs, 'Out');
    return true;
  }

  Future<void> _handleZoneEvent(
    GeofenceZone zone,
    String direction,
    Location? triggerLoc,
    SharedPreferences prefs,
  ) async {
    // ── CLIENT SITE: selfie is mandatory — prompt, never auto-punch ──────
    if (zone.isClientSite) {
      // Office-first hierarchy: when the user is simultaneously inside an
      // office radius, office wins — never prompt a client-site punch.
      // An office and a client site may share coordinates (e.g. a site
      // inside the office compound); the office zone's own enter event
      // handles the punch instead. Mirrors the old worker's decision order.
      if (direction == 'In') {
        final office = await _officeContainingUser(prefs, triggerLoc);
        if (office != null) {
          debugPrint('[GF_MON] ${zone.id}: inside office ${office.name} — '
              'skipping client prompt (office-first)');
          return;
        }
      }
      await _promptClientSitePunch(direction, zone, prefs);
      return;
    }

    // ── Hybrid verification (fresh fix + OS trigger location) ────────────
    final verifiedFix = await _verifyTransition(zone, direction, triggerLoc);
    if (verifiedFix == null) {
      _emit('rejected', zone: zone, direction: direction,
          reason: 'Hybrid verification failed (fix contradicts OS event)');
      return;
    }

    // ── OUT zone-identity gate ───────────────────────────────────────────
    // GPS toggles / OEM ROMs can fire batch EXIT events for EVERY
    // registered fence at once when a location provider drops.  Only the
    // fence the user is actually punched into may punch OUT — otherwise a
    // user standing inside the India office gets "punched out of UAE
    // office" when the UAE fence fires a spurious exit.
    if (direction == 'Out') {
      final lastType = prefs.getString('gf_last_punch_type');
      final inZoneId = prefs.getString('gf_last_punch_zone_id');
      if (lastType == 'In' && inZoneId != null && inZoneId != zone.id) {
        debugPrint('[GF_MON] ${zone.id}: skip OUT — punched into $inZoneId, '
            'not this zone (spurious batch exit)');
        return;
      }
    }

    await _executePunch(zone, verifiedFix, prefs, direction);
  }

  /// Punch-execution path shared by OS transition events and background
  /// containment recovery: local-state gate, server-truth gate
  /// (PunchCoordinator), offline queueing, and local punch-state persistence.
  Future<void> _executePunch(
    GeofenceZone zone,
    geo.Position fix,
    SharedPreferences prefs,
    String direction,
  ) async {
    // ── Server-truth gate (PunchCoordinator) ─────────────────────────────
    // Runs FIRST: the local state may be stale across days (a leftover 'In'
    // from yesterday would otherwise skip today's IN punch — a missed
    // punch).  The server decides; the local gate below only applies when
    // the server is unreachable.
    final dio = await _buildDio(prefs);
    if (dio == null) {
      debugPrint('[GF_MON] ${zone.id}: no token — skipping $direction');
      return;
    }

    final now = DateTime.now();
    final verdict =
        await PunchCoordinator.check(dio: dio, direction: direction);

    if (verdict == PunchCheck.duplicate) {
      // Distinguish a REAL duplicate (biometric machine / website punched
      // for the user — worth telling them) from an echo of our own earlier
      // geofence/wifi punch (OS re-delivered ENTER after a re-registration,
      // or resume catch-up).  Echoes persist state silently: notifying
      // "already punched via another source" while the user sits still at
      // the office is pure noise.
      final method = await PunchCoordinator.lastMethod();
      final ownSource = method == null ||
          method == 'GeofenceAuto' ||
          method == 'WiFi';
      debugPrint('[GF_MON] ${zone.id}: skip $direction — duplicate (source: $method)');
      await _persistPunchState(prefs, direction, now, zone.name, zoneId: zone.id);
      if (direction == 'In') await _clearShiftEndedFlag(prefs);
      if (ownSource) {
        _emit('skipped', zone: zone, direction: direction,
            reason: 'Already $direction (own echo)');
        return;
      }
      await _emitSkipNotification(direction, zone,
          'Already punched $direction via $method');
      return;
    }
    if (verdict == PunchCheck.blocked) {
      debugPrint('[GF_MON] ${zone.id}: skip $direction — blocked by server state');
      await _emitSkipNotification(
          direction, zone, direction == 'Out' ? 'No IN punch today' : 'Break in progress');
      return;
    }
    if (verdict == PunchCheck.undecided) {
      // Server unreachable.  Local state is the only truth left — never send
      // the same direction twice (the server treats a second IN as an OUT
      // toggle).  IN → queue for a later verified sync (never silently
      // drop).  OUT → proceed: the punch POST itself will fail and fall back
      // to the offline queue with current coordinates.
      final lastType = prefs.getString('gf_last_punch_type');
      if (lastType == direction) {
        debugPrint('[GF_MON] ${zone.id}: skip $direction — already $direction (local, offline)');
        return;
      }
      if (direction == 'In') {
        debugPrint('[GF_MON] ${zone.id}: server unreachable — queuing IN offline');
        final queued = await _queueOfflinePunch(
            'In', fix.latitude, fix.longitude);
        if (!queued) {
          debugPrint('[GF_MON] ${zone.id}: queue unavailable — IN lost');
        }
        return;
      }
    }

    // ── Punch API ────────────────────────────────────────────────────────
    // fix is non-null here — acceptance returned a fresh fix or a
    // fallback Position built from the OS trigger location.
    final lat = fix.latitude;
    final lng = fix.longitude;
    final dist = geo.Geolocator.distanceBetween(
        lat, lng, zone.latitude, zone.longitude);

    _emit('punch_attempt', zone: zone, direction: direction,
        lat: lat, lng: lng, accuracy: fix.accuracy,
        distM: dist, thresholdM: zone.radius,
        reason: 'OS ${direction == 'In' ? 'enter' : 'exit'} event verified');

    bool punchAccepted = false;
    try {
      final punchResp = await dio.post(ApiEndpoints.punch, data: {
        'Method': 'GeofenceAuto',
        'Direction': direction,
        'Latitude': lat.toString(),
        'Longitude': lng.toString(),
        'Address': zone.name,
        'IPAddress': 'Background-Service',
      });
      if (punchResp.statusCode == 200 || punchResp.statusCode == 201) {
        punchAccepted = true;
      } else {
        debugPrint('[GF_MON] ${zone.id}: punch ${punchResp.statusCode} — ${punchResp.data}');
      }
    } on DioException catch (e) {
      debugPrint('[GF_MON] ${zone.id}: punch DioException: ${e.message}');
      final resp = e.response;
      if (resp != null &&
          resp.statusCode != null &&
          resp.statusCode! >= 400 &&
          resp.statusCode! < 500) {
        // Permanent rejection — do NOT queue (duplicate / invalid state).
        if (resp.data is Map && resp.data['message'] is String) {
          final msg = resp.data['message'] as String;
          debugPrint('[GF_MON] ${zone.id}: server rejected — $msg');
        }
      } else if (await _queueOfflinePunch(direction, lat, lng)) {
        punchAccepted = true;
      }
    } catch (e) {
      debugPrint('[GF_MON] ${zone.id}: punch error: $e');
      if (await _queueOfflinePunch(direction, lat, lng)) {
        punchAccepted = true;
      }
    }

    if (punchAccepted) {
      await _persistPunchState(prefs, direction, now, zone.name, zoneId: zone.id);
      debugPrint('[GF_MON] ${zone.id}: $direction SUCCESS');
      await _showPunchNotification(direction, zone.name);
      if (direction == 'In') {
        await _clearShiftEndedFlag(prefs);
      }
      _emit('punch_success', zone: zone, direction: direction,
          reason: '$direction via native geofence');
    }
  }

  /// Location services as the OS sees them.  Fails open (treated as enabled)
  /// when the platform/plugin can't answer — guards must never block
  /// legitimate punches on a probe failure.
  Future<bool> _locationServiceEnabled() async {
    try {
      return await geo.Geolocator.isLocationServiceEnabled();
    } catch (e) {
      debugPrint('[GF_MON] Location-service probe failed: $e');
      return true;
    }
  }

  /// Fresh high-accuracy fix with a short timeout.
  Future<geo.Position?> _freshFix() async {
    try {
      return await geo.Geolocator.getCurrentPosition(
        locationSettings: const geo.LocationSettings(
          accuracy: geo.LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
    } catch (e) {
      debugPrint('[GF_MON] Fresh fix unavailable: $e');
      return null;
    }
  }

  /// Cached position first — the OS already paid for it, so no GPS radio
  /// turns on (a stationary user at home or at the office typically never
  /// triggers a fresh fix).  Falls back to a fresh high-accuracy fix when
  /// the cache is missing or older than [_lastKnownMaxAge]: a stale cached
  /// fix can fabricate an office visit (yesterday's fix at the office must
  /// not punch today's IN).
  Future<geo.Position?> _lastKnownOrFreshFix() async {
    try {
      final last = await geo.Geolocator.getLastKnownPosition();
      if (last != null) {
        final age = DateTime.now().toUtc().difference(last.timestamp.toUtc());
        if (age <= _lastKnownMaxAge) {
          debugPrint('[GF_MON] Cached position reused (age ${age.inSeconds}s)');
          return last;
        }
        debugPrint('[GF_MON] Cached position stale (age ${age.inMinutes}m) — fresh fix');
      }
    } catch (e) {
      debugPrint('[GF_MON] Last-known probe failed: $e');
    }
    return _freshFix();
  }

  /// Accept the OS transition only when a fresh fix (or the OS trigger
  /// location) agrees the user is on the correct side of the boundary.
  /// Returns the verified fix on acceptance, null on rejection.
  ///
  /// OUT prefers the OS exit crossing point ([Location]) over any fresh fix:
  /// processing may run long after the boundary crossing (WorkManager can
  /// defer the task), so a fix taken here would already be far away and
  /// punch OUT far outside the radius.  Punching at the crossing keeps the
  /// punch-out distance conventional (~boundary).
  Future<geo.Position?> _verifyTransition(
    GeofenceZone zone,
    String direction,
    Location? triggerLoc,
  ) async {
    // GPS off → no transition is trustworthy.  Android can fire batch
    // EXIT events for every registered fence when the location provider
    // drops, and a trigger point taken at that moment is meaningless.
    // Defer entirely: when location returns, reconcileContainment()
    // re-evaluates and punches IN if the user is inside an office.
    if (!await _locationServiceEnabled()) {
      debugPrint('[GF_MON] ${zone.id}: location service disabled — '
          'rejecting $direction (no trustworthy transitions)');
      return null;
    }

    final trigDist = triggerLoc != null
        ? geo.Geolocator.distanceBetween(
            triggerLoc.latitude, triggerLoc.longitude, zone.latitude, zone.longitude)
        : null;

    // OUT: the OS exit transition IS the boundary-crossing signal — punch
    // immediately at its crossing location, no fix wait.  Only accepts
    // crossings genuinely AT this fence: the trigger point of a real exit
    // always sits at ~radius.  A trigger point far beyond the radius is a
    // spurious batch exit (GPS toggle) or an unrelated fence — reject so
    // the fresh-fix path below cannot punch "OUT of the wrong office".
    if (direction == 'Out' &&
        triggerLoc != null &&
        trigDist != null &&
        trigDist > zone.radius &&
        trigDist <= zone.radius + _outCrossingTolerance) {
      return _toPosition(triggerLoc!);
    }

    final fix = await _freshFix();
    final fixDist = fix != null
        ? geo.Geolocator.distanceBetween(
            fix.latitude, fix.longitude, zone.latitude, zone.longitude)
        : null;

    if (direction == 'In') {
      // IN band: fixed 5m slack past the radius (user spec ~20-25m at a
      // 20m office).  Accuracy never widens the band — the old 2x-accuracy
      // margin punched IN from 61m with a 20m radius.  Trust floor: a fix
      // whose stated accuracy exceeds the whole radius cannot corroborate
      // the 5m slack, so it must defer to the OS crossing point — the REAL
      // boundary detection (honest crossing location, not a far fix).
      if (fixDist != null &&
          fixDist <= zone.radius + _inSlackM &&
          fix!.accuracy <= zone.radius) {
        return fix;
      }
      // No usable fix / untrusted / contradictory fix → trust the OS
      // trigger location only when it confirms crossing into the
      // boundary area.
      if (trigDist != null && trigDist <= zone.radius + 50) {
        return _toPosition(triggerLoc!);
      }
      return null;
    } else {
      // OUT (no usable crossing location): require the fresh fix strictly
      // beyond the OUT band (radius + fixed 25m — user spec "out of
      // radius + 25-30m → punch OUT"; accuracy never widens, the old
      // 2x-accuracy margin delayed OUT until dist > radius + up to 250m)
      // — AND a second confirmatory fix (jump guard: wifi-derived fixes
      // can sit 300-500m off, a single outside fix must never punch the
      // user out while they are still inside the office).
      if (fixDist == null || fixDist <= zone.radius + _outSlackM) return null;
      final f = fix!;

      final fix2 = await _freshFix();
      if (fix2 == null) return null; // can't confirm → conservative: no punch
      final fix2Dist = geo.Geolocator.distanceBetween(
          fix2.latitude, fix2.longitude, zone.latitude, zone.longitude);
      if (fix2Dist <= zone.radius + _outSlackM) return null;

      // Implausible displacement between the two fixes = noise, not movement.
      final moved = geo.Geolocator.distanceBetween(
          f.latitude, f.longitude, fix2.latitude, fix2.longitude);
      if (moved > 800) return null;

      return fix2;
    }
  }

  /// Adapt an OS trigger [Location] into a [geo.Position] for fallback use
  /// when no fresh fix could be obtained.
  geo.Position _toPosition(Location l) => geo.Position(
        latitude: l.latitude,
        longitude: l.longitude,
        timestamp: DateTime.now(),
        accuracy: 0,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );

  /// iOS fires the first event twice after reboot; Android may re-deliver.
  bool _dedupe(SharedPreferences prefs, GeofenceZone zone, String direction) {
    final key = 'gf_last_event_${zone.id}_$direction';
    final last = prefs.getString(key);
    final now = DateTime.now();
    if (last != null) {
      final lastTime = DateTime.tryParse(last);
      if (lastTime != null &&
          now.difference(lastTime).inMilliseconds < _dedupeWindow.inMilliseconds) {
        debugPrint('[GF_MON] ${zone.id}: dedupe — $direction fired ${now.difference(lastTime).inSeconds}s ago');
        return false;
      }
    }
    prefs.setString(key, now.toIso8601String());
    return true;
  }

  String? _directionFor(GeofenceEvent event) {
    switch (event) {
      case GeofenceEvent.enter:
        return 'In';
      case GeofenceEvent.exit:
        return 'Out';
      case GeofenceEvent.dwell:
        return null; // not registered
    }
  }

  GeofenceZone? _loadZone(SharedPreferences prefs, String id) {
    final raw = prefs.getString('gf_zone_$id');
    if (raw == null) return null;
    try {
      return GeofenceZone.fromJson(id, jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('[GF_MON] Corrupt zone metadata for $id: $e');
      return null;
    }
  }

  /// Office-first guard: returns the first office zone whose radius the user
  /// is verified inside (same acceptance rules as the office IN path).
  /// Office beats client sites, so an office and a client site at the same
  /// coordinates never conflict. Only office zones that were actually
  /// registered (persisted under `gf_zone_ids`) are considered.
  Future<GeofenceZone?> _officeContainingUser(
    SharedPreferences prefs,
    Location? triggerLoc,
  ) async {
    final ids =
        prefs.getStringList(GeofenceMonitor._zoneIdsKey) ?? const <String>[];
    for (final id in ids) {
      final office = _loadZone(prefs, id);
      if (office == null || office.isClientSite) continue;
      if (await _verifyTransition(office, 'In', triggerLoc) != null) {
        return office;
      }
    }
    return null;
  }

  Future<void> _persistPunchState(
    SharedPreferences prefs,
    String type,
    DateTime time,
    String officeName, {
    String? zoneId,
  }) async {
    await prefs.setString('gf_last_punch_type', type);
    await prefs.setString('gf_last_punch_time', time.toIso8601String());
    await prefs.setString('gf_last_punch_office', officeName);
    // Zone identity for the OUT gate: only the fence the user is punched
    // into may punch them out (spurious batch exits must be ignored).
    if (zoneId != null) {
      await prefs.setString('gf_last_punch_zone_id', zoneId);
    }
    // Containment alarm keep-alive: punched IN → the native receiver keeps
    // self-arming the 15-min check (guaranteed OUT even when the OS misses
    // the geofence exit).  Punched OUT → receiver stops on its next fire.
    // Written from ANY isolate — headless punches arm/disarm without the
    // app ever being opened.
    await prefs.setBool(
        'gf_containment_alarm_armed', type == 'In');
    // Foreground service lifecycle: FGS runs ONLY while punched IN (the
    // movement-gated stream catches the walk-out instantly; the moment the
    // OUT punch persists, the FGS is closed — banner gone until the next
    // IN).  No-op on iOS / when nothing to hold (gates inside the service).
    try {
      if (type == 'In') {
        await OemKeepAliveService.startIfNeeded();
      } else {
        await OemKeepAliveService.stop();
      }
    } catch (e) {
      debugPrint('[GF_MON] keep-alive FGS lifecycle error: $e');
    }
  }

  Future<void> _clearShiftEndedFlag(SharedPreferences prefs) async {
    try {
      await prefs.remove('gf_shift_ended');
    } catch (_) {}
  }

  /// Informs the user why the punch was skipped — always a short, direct
  /// message, never a big block of text.
  /// Cooldown for skip notifications — at most one per zone+direction per
  /// window, whatever the cause.  (The big spam source — own-source echoes —
  /// is silenced before this point; this bounds the rest.)
  static const Duration _skipNotifCooldown = Duration(minutes: 30);

  /// Informs the user why the punch was skipped — always a short, direct
  /// message, never a big block of text.  Rate-limited per zone+direction
  /// (see [_skipNotifCooldown]); own-source echoes never reach here.
  /// Notification ID 995 — NOT 999 (that id is reserved for the
  /// permission alert) and not 998 (no-connectivity warning).
  Future<void> _emitSkipNotification(
      String direction, GeofenceZone zone, String reason) async {
    _emit('skipped', zone: zone, direction: direction, reason: reason);
    final prefs = await SharedPreferences.getInstance();
    final cooldownKey = 'gf_skip_notif_${zone.id}_$direction';
    final lastShown = prefs.getString(cooldownKey);
    if (lastShown != null) {
      final last = DateTime.tryParse(lastShown);
      if (last != null &&
          DateTime.now().difference(last) < _skipNotifCooldown) {
        debugPrint('[GF_MON] skip notification cooldown active ($cooldownKey)');
        return;
      }
    }
    await prefs.setString(cooldownKey, DateTime.now().toIso8601String());

    await _ensureNotifications();
    try {
      await _notifications.show(
        995,
        'Punch skipped',
        reason,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'geofence_auto_punch',
            'Geofence Auto-Punch',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[GF_MON] Skip notification failed: $e');
    }
  }

  Future<void> _showPunchNotification(String direction, String officeName) async {
    await _ensureNotifications();
    final isIn = direction == 'In';
    try {
      await _notifications.show(
        994,
        isIn ? 'Auto-Punched In' : 'Auto-Punched Out',
        isIn ? 'Auto-punched IN at $officeName' : 'Auto-punched OUT from $officeName',
        NotificationDetails(
          android: AndroidNotificationDetails(
            'geofence_auto_punch',
            'Geofence Auto-Punch',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      debugPrint('[GF_MON] Punch notification failed: $e');
    }
  }

  /// Tap-to-punch prompt for client-site zones (selfie required by server).
  /// Deduped per site until the user exits (exit clears the cooldown).
  Future<void> _promptClientSitePunch(
    String direction,
    GeofenceZone zone,
    SharedPreferences prefs,
  ) async {
    final cooldownKey = 'gf_prompt_${zone.id}';
    if (direction == 'Out') {
      // Leaving the zone → allow a fresh prompt on next entry.
      await prefs.remove(cooldownKey);
      return;
    }
    final lastPrompt = prefs.getString(cooldownKey);
    if (lastPrompt != null) {
      final last = DateTime.tryParse(lastPrompt);
      if (last != null &&
          DateTime.now().difference(last).inMinutes < 15) {
        debugPrint('[GF_MON] ${zone.id}: prompt cooldown active');
        return;
      }
    }
    await prefs.setString(cooldownKey, DateTime.now().toIso8601String());

    await _ensureNotifications();
    final title = 'Punch in at ${zone.name}';
    final body = 'You are inside ${zone.name}. Tap to punch in with selfie.';
    final payload = jsonEncode({
      'type': 'client_site_punch',
      'direction': direction,
      'clientSiteId': zone.clientSiteId,
      'siteName': zone.name,
    });
    try {
      await _notifications.show(
        3000 + (zone.clientSiteId ?? 0),
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'client_site_punch',
            'Client Site Punch',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        payload: payload,
      );
    } catch (e) {
      debugPrint('[GF_MON] Client-site prompt failed: $e');
    }
  }

  Future<bool> _queueOfflinePunch(
    String direction,
    double lat,
    double lng,
  ) async {
    if (_queueOverride != null) return _queueOverride!(direction, lat, lng);
    try {
      await _ensureHive();
      final punch = OfflinePunch()
        ..method = 'GeofenceAuto'
        ..direction = direction
        ..latitude = lat
        ..longitude = lng
        ..createdAt = DateTime.now();
      await OfflineQueueService().enqueue(punch);
      await OfflineSyncManager.scheduleNow();
      debugPrint('[GF_MON] queued $direction offline (no network)');
      return true;
    } catch (e) {
      debugPrint('[GF_MON] offline queue enqueue failed: $e');
      return false;
    }
  }

  Future<void> _ensureHive() async {
    if (_hiveReady) return;
    try {
      await Hive.initFlutter();
      Hive.registerAdapter(OfflinePunchAdapter());
      await Hive.openBox<OfflinePunch>(AppConstants.offlinePunchBox);
      await Hive.openBox(AppConstants.cacheBox);
      _hiveReady = true;
    } catch (e) {
      debugPrint('[GF_MON] Hive init failed (offline queue unavailable): $e');
    }
  }

  Future<void> _ensureNotifications() async {
    if (_notifInit) return;
    try {
      await _notifications.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );
      _notifInit = true;
    } catch (e) {
      debugPrint('[GF_MON] Notifications init failed: $e');
    }
  }

  // ── HTTP helpers (mirror the old worker's background-isolate logic) ────────

  Future<Dio?> _buildDio(SharedPreferences prefs) async {
    if (_testDio != null) return _testDio;
    final token = prefs.getString('bg_access_token');
    if (token == null) return null;

    final dio = Dio(BaseOptions(
      baseUrl: AppConstants.apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Authorization': 'Bearer $token',
        'X-Client-Type': 'mobile',
        'X-Platform': Platform.isAndroid ? 'android' : 'ios',
      },
    ));

    dio.interceptors.addAll([
      InterceptorsWrapper(
        onError: (error, handler) async {
          if (error.response?.statusCode != 401) {
            return handler.next(error);
          }
          debugPrint('[GF_MON] 401 on ${error.requestOptions.path} — refreshing token');
          try {
            final refreshed = await _refreshToken(prefs);
            if (refreshed == null) {
              return handler.next(error);
            }
            error.requestOptions.headers['Authorization'] = 'Bearer $refreshed';
            final retryResp = await dio.fetch(error.requestOptions);
            return handler.resolve(retryResp);
          } catch (e) {
            debugPrint('[GF_MON] Token refresh error: $e');
            return handler.next(error);
          }
        },
      ),
      PunchStateInterceptor(),
    ]);

    return dio;
  }

  /// Cross-isolate atomic refresh (same protocol as the old worker).
  Future<String?> _refreshToken(SharedPreferences prefs) async {
    final lockTs = prefs.getInt('bg_refresh_lock') ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lockTs > 0 && (now - lockTs) < 30000) {
      debugPrint('[GF_MON] Another isolate is refreshing — skipping');
      return null;
    }

    final owner = '$now-${DateTime.now().microsecondsSinceEpoch}';
    await prefs.setInt('bg_refresh_lock', now);
    await prefs.setString('bg_refresh_lock_owner', owner);
    await prefs.reload();
    final persistedOwner = prefs.getString('bg_refresh_lock_owner');
    final persistedTs = prefs.getInt('bg_refresh_lock') ?? 0;
    if (persistedOwner != owner || persistedTs != now) {
      debugPrint('[GF_MON] Lost refresh-lock race — skipping');
      return null;
    }

    try {
      final sessionId = prefs.getString('auth_session_id');
      final refreshToken = prefs.getString('bg_refresh_token');
      final accessToken = prefs.getString('bg_access_token');
      if (sessionId == null || refreshToken == null || accessToken == null) {
        await prefs.remove('bg_refresh_lock');
        await prefs.remove('bg_refresh_lock_owner');
        return null;
      }

      final refreshDio = Dio(BaseOptions(
        baseUrl: AppConstants.apiBaseUrl,
        connectTimeout: const Duration(seconds: 15),
      ));

      final resp = await refreshDio.post('/api/v1/auth/refresh', data: {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
      });

      final newAccess = resp.data['accessToken'] as String;
      final newRefresh = resp.data['refreshToken'] as String;

      await prefs.reload();
      if (prefs.getString('auth_session_id') != sessionId) {
        debugPrint('[GF_MON] Session changed during refresh — discarding tokens');
        await prefs.remove('bg_refresh_lock');
        await prefs.remove('bg_refresh_lock_owner');
        return null;
      }

      await Future.wait([
        prefs.setString('bg_access_token', newAccess),
        prefs.setString('bg_refresh_token', newRefresh),
        prefs.setInt('bg_token_ts', DateTime.now().millisecondsSinceEpoch),
        prefs.remove('bg_refresh_lock'),
        prefs.remove('bg_refresh_lock_owner'),
      ]);

      debugPrint('[GF_MON] Token refreshed successfully');
      return newAccess;
    } catch (e) {
      await prefs.remove('bg_refresh_lock');
      await prefs.remove('bg_refresh_lock_owner');
      debugPrint('[GF_MON] Token refresh failed — retaining tokens for main isolate');
      return null;
    }
  }

  bool _isEnabled(SharedPreferences prefs) {
    final val = prefs.getBool('geofence_auto_enabled') ?? false;
    final allow = prefs.getBool('bg_allow_geofence_auto');
    final permitted = allow != false;
    debugPrint('[GF_MON] _isEnabled = $val, allowGeofenceAuto = ${allow ?? 'unknown'}');
    return val && permitted;
  }

  void _emit(
    String event, {
    GeofenceZone? zone,
    String? direction,
    double? lat,
    double? lng,
    double? accuracy,
    double? distM,
    double? thresholdM,
    String? reason,
  }) {
    GeofenceDebugBus.emit({
      'ts': DateTime.now().toIso8601String(),
      'event': event,
      'zone': zone?.name,
      'direction': direction,
      'lat': lat,
      'lng': lng,
      'accuracy': accuracy,
      'distM': distM,
      'thresholdM': thresholdM,
      'reason': reason ?? '',
    });
  }
}
