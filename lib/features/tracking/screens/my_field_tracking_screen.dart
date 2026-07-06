import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/config/dev_flags.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/date_time_utils.dart';
import '../../punch/services/geofence_debug_bus.dart';
import '../services/field_tracking_service.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

class _DayReport {
  final DateTime date;
  final double totalDistanceKm;
  final int pingCount;
  final DateTime? firstPingAt;
  final DateTime? lastPingAt;

  const _DayReport({
    required this.date,
    required this.totalDistanceKm,
    required this.pingCount,
    this.firstPingAt,
    this.lastPingAt,
  });

  factory _DayReport.fromJson(Map<String, dynamic> j) => _DayReport(
        date: parseUtc(j['date'] as String),
        totalDistanceKm:
            (j['totalDistanceKm'] as num?)?.toDouble() ?? 0.0,
        pingCount: (j['pingCount'] as int?) ?? 0,
        firstPingAt: parseUtcOrNull(j['firstPingAt'] as String?),
        lastPingAt: parseUtcOrNull(j['lastPingAt'] as String?),
      );
}

// ── Debug log entry ───────────────────────────────────────────────────────────

class _DebugEntry {
  final String time;
  final String event;
  final String state;
  final String detail;
  final Color color;

  const _DebugEntry({
    required this.time,
    required this.event,
    required this.state,
    required this.detail,
    required this.color,
  });

  static Color _colorFor(String event) {
    switch (event) {
      // ── Field tracking events ──────────────────────────────────────────────
      case 'ping_sent':       return const Color(0xFF4CAF50);
      case 'ping_skipped':    return const Color(0xFFFF9800);
      case 'ping_error':      return const Color(0xFFF44336);
      case 'rejected':        return const Color(0xFFE91E63);
      case 'state_change':    return const Color(0xFF9C27B0);
      case 'service_start':
      case 'service_stop':    return const Color(0xFF2196F3);
      case 'filtered':        return const Color(0xFF78909C);
      // ── Geofence auto-punch events ─────────────────────────────────────────
      case 'gf_start':
      case 'gf_stop':         return const Color(0xFF2196F3);  // blue
      case 'gf_event':        return const Color(0xFF00BCD4);  // cyan
      case 'gf_enter':        return const Color(0xFF4CAF50);  // green
      case 'gf_exit':         return const Color(0xFFFF9800);  // orange
      case 'gf_blocked':      return const Color(0xFFFFC107);  // amber
      case 'gf_punch':        return const Color(0xFF8BC34A);  // light-green
      case 'gf_punch_err':    return const Color(0xFFF44336);  // red
      case 'gf_conf_fail':    return const Color(0xFFE91E63);  // pink
      case 'gf_acc_fail':     return const Color(0xFFE91E63);  // pink
      case 'gf_jump':         return const Color(0xFFE91E63);  // pink
      case 'gf_jump_soft':    return const Color(0xFFFFEB3B);  // yellow
      case 'jump_soft':       return const Color(0xFFFFEB3B);  // yellow
      case 'gf_reset':        return const Color(0xFF607D8B);  // blue-gray
      case 'gf_skip':         return const Color(0xFF78909C);  // blue-gray
      case 'gf_state':        return const Color(0xFF9C27B0);  // purple
      case 'gf_api_call':     return const Color(0xFF03A9F4);  // light-blue
      case 'gf_reject':       return const Color(0xFFF44336);  // red
      default:                return const Color(0xFF90A4AE);
    }
  }

  static String _labelFor(String event) {
    switch (event) {
      // ── Field tracking events ──────────────────────────────────────────────
      case 'ping_sent':    return 'PING ✓';
      case 'ping_skipped': return 'SKIP';
      case 'ping_error':   return 'ERR';
      case 'rejected':     return 'REJECT';
      case 'state_change': return 'STATE';
      case 'service_start':return 'START';
      case 'service_stop': return 'STOP';
      case 'filtered':     return 'GPS';
      // ── Geofence auto-punch events ─────────────────────────────────────────
      case 'gf_start':     return 'GF START';
      case 'gf_stop':      return 'GF STOP';
      case 'gf_event':     return 'GF ⚡';
      case 'gf_enter':     return 'GF → IN';
      case 'gf_exit':      return 'GF → OUT';
      case 'gf_blocked':   return 'GF ⛔';
      case 'gf_punch':     return 'PUNCH ✓';
      case 'gf_punch_err': return 'PUNCH ✗';
      case 'gf_conf_fail': return 'CONF ✗';
      case 'gf_acc_fail':  return 'ACC ✗';
      case 'gf_jump':      return 'JUMP ✗';
      case 'jump_soft':    return 'SOFT JUMP';
      case 'gf_jump_soft': return 'SOFT JUMP';
      case 'gf_reset':     return 'RESET';
      case 'gf_skip':      return 'GF SKIP';
      case 'gf_state':     return 'STATE';
      case 'gf_api_call':  return 'API →';
      case 'gf_reject':    return 'REJECT 🛡️';
      default:             return event.toUpperCase();
    }
  }

  factory _DebugEntry.fromMap(Map<String, dynamic> d) {
    final event = d['event'] as String? ?? '';
    final ts    = d['ts'] as String? ?? '';
    final time  = ts.length >= 19 ? ts.substring(11, 19) : ts;
    final state = d['state'] as String? ?? '—';

    final lat      = (d['lat']      as num?)?.toStringAsFixed(5) ?? '—';
    final lng      = (d['lng']      as num?)?.toStringAsFixed(5) ?? '—';
    final acc      = (d['accuracy'] as num?)?.toStringAsFixed(1);
    final spd      = (d['speed']    as num?)?.toStringAsFixed(1);
    final reason   = d['reason']    as String? ?? '';
    final elig     = d['eligibility'] as String?;
    
    // Distances
    final distM      = (d['distM']      as num?)?.toStringAsFixed(1);
    final thresholdM = (d['thresholdM'] as num?)?.toStringAsFixed(1);
    final conf       = (d['confidence'] as num?);
    final gfId       = d['geofenceId']  as String?;

    final buf = StringBuffer();
    // Line 1: Pos & Accuracy
    if (lat != '—') {
      buf.write('📍 $lat, $lng');
      if (acc != null) buf.write(' (acc:${acc}m)');
    }
    
    // Line 2: Distance & Threshold (if available)
    if (distM != null) {
      final thresh = thresholdM ?? '—';
      final isInside = thresholdM != null && double.parse(distM) <= double.parse(thresholdM);
      buf.write('\n📏 Dist: ${distM}m / ${thresh}m');
      buf.write(isInside ? ' 🟢 [INSIDE]' : ' 🔴 [OUTSIDE]');
    }

    // Line 3: Speed, Conf, Eligibility
    String line3 = '';
    if (spd != null) line3 += '⚡ spd:${spd}m/s ';
    if (conf != null) line3 += '🎯 conf:${(conf * 100).toStringAsFixed(0)}% ';
    if (elig != null) line3 += '💡 status:$elig';
    if (line3.isNotEmpty) buf.write('\n$line3');

    // Line 4: Reason / Action
    if (reason.isNotEmpty) {
      buf.write('\n📝 $reason');
    }

    if (gfId != null) {
      buf.write('  [Zone:${gfId.replaceFirst('office-', '#')}]');
    }

    return _DebugEntry(
      time:   time,
      event:  _labelFor(event),
      state:  state,
      detail: buf.toString(),
      color:  _colorFor(event),
    );
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class MyFieldTrackingScreen extends ConsumerStatefulWidget {
  const MyFieldTrackingScreen({super.key});

  @override
  ConsumerState<MyFieldTrackingScreen> createState() =>
      _MyFieldTrackingScreenState();
}

class _MyFieldTrackingScreenState
    extends ConsumerState<MyFieldTrackingScreen> {
  final _dateFmt  = DateFormat('d MMM yyyy');
  final _paramFmt = DateFormat('yyyy-MM-dd');
  final _timeFmt  = DateFormat('HH:mm');

  late DateTime _from;
  late DateTime _to;

  bool _loading   = false;
  String? _error;
  List<_DayReport> _days = [];
  bool _exporting = false;

  // ── Real-time map state ──────────────────────────────────────────────────
  final MapController _mapController = MapController();
  LatLng? _currentPos;
  double? _currentAccuracy;
  bool _hasPosition = false;

  // ── Debug console state ──────────────────────────────────────────────────
  final List<_DebugEntry> _logs = [];
  StreamSubscription<Map<String, dynamic>>? _debugSub;
  StreamSubscription<Map<String, dynamic>>? _gfDebugSub;  // geofence auto-punch bus
  final _logScrollCtrl = ScrollController();
  bool _debugExpanded = true;
  static const int _maxLogs = 300;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _from = DateTime(now.year, now.month, 1);
    _to   = now;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());

    // Always listen for position updates from the background tracking isolate.
    // The map is shown even outside dev mode.
    _debugSub = FieldTrackingService.debugStream.listen((data) {
      final lat = data['lat'] as double?;
      final lng = data['lng'] as double?;
      if (lat != null && lng != null) {
        final pos = LatLng(lat, lng);
        final acc = data['accuracy'] as double?;
        if (mounted) {
          setState(() {
            _currentPos = pos;
            _currentAccuracy = acc;
            _hasPosition = true;
          });
          // Follow the user on the map
          if (_hasPosition) {
            _mapController.move(pos, 16);
          }
        }
      }

      // Debug console entries (dev mode only)
      if (DevFlags.kDevMode && mounted) {
        final entry = _DebugEntry.fromMap(data);
        setState(() {
          _logs.insert(0, entry);
          if (_logs.length > _maxLogs) _logs.removeLast();
        });
      }
    });

    // Geofence auto-punch events: only useful for debugging
    if (DevFlags.kDevMode) {
      _gfDebugSub = GeofenceDebugBus.stream.listen((data) {
        if (!mounted) return;
        final entry = _DebugEntry.fromMap(data);
        setState(() {
          _logs.insert(0, entry);
          if (_logs.length > _maxLogs) _logs.removeLast();
        });
      });
    }
  }

  @override
  void dispose() {
    _debugSub?.cancel();
    _gfDebugSub?.cancel();
    _mapController.dispose();
    _logScrollCtrl.dispose();
    super.dispose();
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final dio = ref.read(dioClientProvider).dio;
      final response = await dio.get(
        ApiEndpoints.myTrackingReport,
        queryParameters: {
          'from': _paramFmt.format(_from),
          'to':   _paramFmt.format(_to),
        },
      );
      final list =
          (response.data['data'] as List<dynamic>? ?? [])
              .map((e) => _DayReport.fromJson(e as Map<String, dynamic>))
              .toList();
      if (mounted) setState(() => _days = list);
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final dio = ref.read(dioClientProvider).dio;
      final response = await dio.get(
        ApiEndpoints.myTrackingReportExport,
        queryParameters: {
          'from': _paramFmt.format(_from),
          'to':   _paramFmt.format(_to),
        },
        options: Options(responseType: ResponseType.bytes),
      );
      final dir      = await getApplicationDocumentsDirectory();
      final filename =
          'field_tracking_${_paramFmt.format(_from)}_${_paramFmt.format(_to)}.xlsx';
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(response.data as List<int>);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Saved: $filename'),
          backgroundColor: AppColors.success,
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Export failed: ${_message(e)}'),
          backgroundColor: AppColors.error,
        ));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _message(Object e) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map) {
        return (data['message'] as String?) ?? e.message ?? 'Network error';
      }
      if (data != null) return data.toString();
      return e.message ?? 'Network error';
    }
    return e.toString();
  }

  // ── Date picker ───────────────────────────────────────────────────────────

  Future<void> _pickDate({required bool isFrom}) async {
    final initial = isFrom ? _from : _to;
    final first   = isFrom ? DateTime(2020) : _from;
    final last    = isFrom ? _to : DateTime.now();

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) { _from = picked; } else { _to = picked; }
    });
    _load();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isRunning = ref.watch(fieldTrackingRunningProvider);
    final theme     = Theme.of(context);

    final totalDays  = _days.length;
    final totalKm    = _days.fold(0.0, (s, d) => s + d.totalDistanceKm);
    final totalPings = _days.fold(0,   (s, d) => s + d.pingCount);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Field Tracking'),
        actions: [
          if (DevFlags.kDevMode)
            IconButton(
              tooltip: 'Toggle debug console',
              icon: Icon(
                _debugExpanded
                    ? Icons.bug_report
                    : Icons.bug_report_outlined,
                color: _debugExpanded ? AppColors.warning : null,
              ),
              onPressed: () =>
                  setState(() => _debugExpanded = !_debugExpanded),
            ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Export Excel',
            onPressed: _exporting ? null : _export,
            icon: _exporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download_outlined),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Status banner ────────────────────────────────────────────────
          Container(
            color: isRunning
                ? AppColors.success.withAlpha(26)
                : theme.colorScheme.surfaceContainerHighest,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: [
                Icon(
                  isRunning
                      ? Icons.location_on
                      : Icons.location_off_outlined,
                  size: 18,
                  color: isRunning ? AppColors.success : AppColors.gray,
                ),
                const SizedBox(width: 8),
                Text(
                  isRunning ? 'Tracking Active' : 'Tracking Off',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: isRunning
                        ? AppColors.success
                        : AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          // ── Real-time tracking map ───────────────────────────────────────
          if (isRunning && _hasPosition && _currentPos != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 180,
                child: Stack(
                  children: [
                    FlutterMap(
                      mapController: _mapController,
                      options: MapOptions(
                        initialCenter: _currentPos!,
                        initialZoom: 16,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName:
                              'com.mattendance.mattendance_mobile',
                        ),
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: _currentPos!,
                              width: 30,
                              height: 30,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: Colors.white, width: 2.5),
                                  boxShadow: [
                                    BoxShadow(
                                      color: theme.colorScheme.primary
                                          .withAlpha(80),
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                                child: const Icon(Icons.my_location,
                                    color: Colors.white, size: 14),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    // GPS accuracy badge
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '±${_currentAccuracy?.toStringAsFixed(0) ?? '?'}m',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (isRunning)
            Container(
              height: 100,
              margin:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Center(
                child: Text(
                  'Waiting for GPS position…',
                  style: TextStyle(color: AppColors.textSecondary),
                ),
              ),
            ),

          // ── Dev debug console ────────────────────────────────────────────
          if (DevFlags.kDevMode && _debugExpanded)
            _DebugConsole(logs: _logs),

          // ── Date range chips ─────────────────────────────────────────────
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Flexible(
                  child: _DateChip(
                    label: 'From',
                    value: _dateFmt.format(_from),
                    onTap: () => _pickDate(isFrom: true),
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: _DateChip(
                    label: 'To',
                    value: _dateFmt.format(_to),
                    onTap: () => _pickDate(isFrom: false),
                  ),
                ),
              ],
            ),
          ),

          // ── Summary strip ─────────────────────────────────────────────────
          if (!_loading && _error == null && _days.isNotEmpty)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _Stat(label: 'Days',     value: '$totalDays'),
                  _Stat(label: 'Distance', value: '${totalKm.toStringAsFixed(1)} km'),
                  _Stat(label: 'Pings',    value: '$totalPings'),
                ],
              ),
            ),

          const SizedBox(height: 4),

          // ── List / states ─────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _ErrorState(message: _error!, onRetry: _load)
                    : _days.isEmpty
                        ? const _EmptyState()
                        : ListView.separated(
                            padding:
                                const EdgeInsets.fromLTRB(16, 4, 16, 24),
                            itemCount: _days.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 8),
                            itemBuilder: (_, i) {
                              final day = _days[i];
                              return _DayCard(
                                day: day,
                                dateFmt: _dateFmt,
                                timeFmt: _timeFmt,
                              );
                            },
                          ),
          ),
        ],
      ),
    );
  }
}

// ── Debug Console ─────────────────────────────────────────────────────────────

class _DebugConsole extends StatelessWidget {
  final List<_DebugEntry> logs;
  const _DebugConsole({required this.logs});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg     = isDark ? const Color(0xFF0D1117) : const Color(0xFF1A1A2E);

    return Container(
      height: 220,
      color: bg,
      child: Column(
        children: [
          // Header bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            color: const Color(0xFF00BCD4).withAlpha(30),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 13, color: Color(0xFF00BCD4)),
                const SizedBox(width: 6),
                Text(
                  'DEV · GPS Pipeline Log',
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: Color(0xFF00BCD4),
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const Spacer(),
                Text(
                  '${logs.length} events',
                  style: const TextStyle(
                    fontSize: 10,
                    fontFamily: 'monospace',
                    color: Color(0xFF546E7A),
                  ),
                ),
              ],
            ),
          ),

          // Log rows
          Expanded(
            child: logs.isEmpty
                ? const Center(
                    child: Text(
                      'Waiting for GPS events…',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: Color(0xFF546E7A),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: EdgeInsets.zero,
                    itemCount: logs.length,
                    itemBuilder: (_, i) => _LogRow(entry: logs[i]),
                  ),
          ),

          // Legend
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            child: Row(
              children: [
                _Legend('GPS',      const Color(0xFF78909C)),
                _Legend('STATE',    const Color(0xFF9C27B0)),
                _Legend('PING ✓',   const Color(0xFF4CAF50)),
                _Legend('SKIP',     const Color(0xFFFF9800)),
                _Legend('REJECT',   const Color(0xFFE91E63)),
                _Legend('ERR',      const Color(0xFFF44336)),
                _Legend('GF ⚡',    const Color(0xFF00BCD4)),
                _Legend('GF → IN',  const Color(0xFF4CAF50)),
                _Legend('GF → OUT', const Color(0xFFFF9800)),
                _Legend('GF ⛔',    const Color(0xFFFFC107)),
                _Legend('PUNCH ✓',  const Color(0xFF8BC34A)),
                _Legend('ACC ✗',    const Color(0xFFE91E63)),
                _Legend('SOFT JUMP',const Color(0xFFFFEB3B)),
                _Legend('RESET',    const Color(0xFF607D8B)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  final _DebugEntry entry;
  const _LogRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: entry.color, width: 2.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timestamp
          Text(
            entry.time,
            style: const TextStyle(
              fontSize: 9.5,
              fontFamily: 'monospace',
              color: Color(0xFF546E7A),
            ),
          ),
          const SizedBox(width: 6),
          // Event badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: entry.color.withAlpha(40),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              entry.event,
              style: TextStyle(
                fontSize: 9,
                fontFamily: 'monospace',
                color: entry.color,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 6),
          // State pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xFF263238),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              entry.state,
              style: const TextStyle(
                fontSize: 9,
                fontFamily: 'monospace',
                color: Color(0xFF80CBC4),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Detail
          Expanded(
            child: Text(
              entry.detail,
              style: const TextStyle(
                fontSize: 9.5,
                fontFamily: 'monospace',
                color: Color(0xFFB0BEC5),
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final String label;
  final Color color;
  const _Legend(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 9,
                  fontFamily: 'monospace',
                  color: color.withAlpha(200))),
        ],
      ),
    );
  }
}

// ── Existing widgets ──────────────────────────────────────────────────────────

class _DateChip extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _DateChip({required this.label, required this.value, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$label: ',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textSecondary)),
            Flexible(
              child: Text(value,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 4),
            const Icon(Icons.calendar_today_outlined, size: 13),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold)),
        const SizedBox(height: 2),
        Text(label,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textSecondary)),
      ],
    );
  }
}

class _DayCard extends StatelessWidget {
  final _DayReport day;
  final DateFormat dateFmt;
  final DateFormat timeFmt;

  const _DayCard({required this.day, required this.dateFmt, required this.timeFmt});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dateFmt.format(day.date),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                  if (day.firstPingAt != null && day.lastPingAt != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '${timeFmt.format(day.firstPingAt!)} – ${timeFmt.format(day.lastPingAt!)}',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: AppColors.textSecondary),
                      ),
                    ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('${day.totalDistanceKm.toStringAsFixed(2)} km',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('${day.pingCount} ping${day.pingCount == 1 ? '' : 's'}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.location_off_outlined, size: 52, color: AppColors.gray),
          const SizedBox(height: 12),
          Text('No tracking data for this period',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 52, color: AppColors.gray),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
