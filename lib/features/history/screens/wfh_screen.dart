import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../widgets/skeleton_loader.dart';
import '../../punch/services/camera_service.dart';
import '../../punch/services/location_service.dart';
import '../../../core/utils/date_time_utils.dart';

// ── Model ─────────────────────────────────────────────────────────────────────

class WFHLog {
  final int id;
  final DateTime checkInTime;
  final String? taskDescription;
  final bool isVerified;

  const WFHLog({
    required this.id,
    required this.checkInTime,
    this.taskDescription,
    required this.isVerified,
  });

  factory WFHLog.fromJson(Map<String, dynamic> j) => WFHLog(
        id: j['id'] as int,
        checkInTime: parseUtc(j['checkInTime'] as String),
        taskDescription: j['taskDescription'] as String?,
        isVerified: j['isVerified'] as bool? ?? false,
      );

  String get formattedTime {
    final local = checkInTime.toLocal();
    final h = local.hour;
    final m = local.minute.toString().padLeft(2, '0');
    final amPm = h >= 12 ? 'PM' : 'AM';
    final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return '$h12:$m $amPm';
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class WFHScreen extends ConsumerStatefulWidget {
  const WFHScreen({super.key});

  @override
  ConsumerState<WFHScreen> createState() => _WFHScreenState();
}

class _WFHScreenState extends ConsumerState<WFHScreen> {
  final _cameraService = CameraService();
  final _locationService = LocationService();
  final _taskCtrl = TextEditingController();

  bool _cameraReady = false;
  String? _cameraError;
  bool _locationLoading = true;
  LocationResult? _location;
  String? _locationError;
  bool _isSubmitting = false;

  List<WFHLog> _todayLogs = [];
  bool _logsLoading = true;

  @override
  void initState() {
    super.initState();
    _initCamera();
    _loadLocation();
    _loadTodayLogs();
  }

  @override
  void dispose() {
    _cameraService.dispose();
    _taskCtrl.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    try {
      await _cameraService.initialize();
      if (mounted) setState(() => _cameraReady = true);
    } catch (e) {
      if (mounted) {
        setState(() => _cameraError = 'Camera unavailable: $e');
      }
    }
  }

  Future<void> _loadLocation() async {
    try {
      final loc = await _locationService.getCurrentPosition();
      if (mounted) {
        setState(() {
          _location = loc;
          _locationLoading = false;
        });
      }
    } on LocationPermissionDeniedException catch (e) {
      if (mounted) {
        setState(() {
          _locationError = e.message;
          _locationLoading = false;
        });
      }
    } on LocationPrecisionRequiredException catch (e) {
      if (mounted) {
        setState(() {
          _locationError = e.message;
          _locationLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _locationError = 'Could not get location.';
          _locationLoading = false;
        });
      }
    }
  }

  Future<void> _loadTodayLogs() async {
    try {
      final dio = ref.read(dioClientProvider).dio;
      final response = await dio.get(ApiEndpoints.wfhTodayLogs);
      final data = response.data['data'] as List<dynamic>? ?? [];
      if (mounted) {
        setState(() {
          _todayLogs = data
              .map((e) => WFHLog.fromJson(e as Map<String, dynamic>))
              .toList();
          _logsLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _logsLoading = false);
    }
  }

  Future<void> _submit() async {
    if (_location == null) {
      _showSnack('Location not available yet.');
      return;
    }
    if (_taskCtrl.text.trim().isEmpty) {
      _showSnack('Please enter a task description.');
      return;
    }

    setState(() => _isSubmitting = true);

    String? selfieBase64;
    if (_cameraReady) {
      try {
        selfieBase64 = await _cameraService.captureAndEncode();
      } catch (_) {
        // selfie optional — proceed without it
      }
    }

    try {
      final dio = ref.read(dioClientProvider).dio;
      await dio.post(ApiEndpoints.wfhCheckin, data: {
        'latitude': _location!.latitude,
        'longitude': _location!.longitude,
        if (selfieBase64 case final s?) 'selfieBase64': s, // ignore: use_null_aware_elements
        'taskDescription': _taskCtrl.text.trim(),
      });
      if (!mounted) return;
      _showSnack('WFH check-in recorded!', success: true);
      _taskCtrl.clear();
      await _loadTodayLogs();
    } catch (e) {
      if (!mounted) return;
      _showSnack(_extractError(e));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  String _extractError(Object e) {
    try {
      final data = (e as dynamic).response?.data as Map?;
      return data?['message'] as String? ?? e.toString();
    } catch (_) {
      return e.toString();
    }
  }

  void _showSnack(String msg, {bool success = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: success ? AppColors.success : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('WFH Check-in'),
        leading: const BackButton(),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Camera preview ──────────────────────────────────────────
              _SectionLabel('Selfie'),
              const SizedBox(height: 8),
              _buildCameraPreview(theme),
              const SizedBox(height: 20),

              // ── GPS status ──────────────────────────────────────────────
              _SectionLabel('Your Location'),
              const SizedBox(height: 8),
              _buildLocationTile(theme),
              const SizedBox(height: 20),

              // ── Task description ────────────────────────────────────────
              _SectionLabel('Task Description'),
              const SizedBox(height: 8),
              TextField(
                controller: _taskCtrl,
                maxLines: 3,
                maxLength: 500,
                decoration: const InputDecoration(
                  hintText: 'What are you working on today?',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),

              // ── Submit ──────────────────────────────────────────────────
              ElevatedButton.icon(
                onPressed: _isSubmitting ? null : _submit,
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.home_work_outlined),
                label: Text(_isSubmitting ? 'Checking in…' : 'WFH CHECK-IN'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 52),
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.graySubtle,
                ),
              ),
              const SizedBox(height: 32),

              // ── Today's check-ins ───────────────────────────────────────
              _SectionLabel("Today's Check-ins"),
              const SizedBox(height: 12),
              _buildTodayLogs(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCameraPreview(ThemeData theme) {
    const h = 180.0;
    if (_cameraError != null) {
      return SkeletonLoader(
        child: Container(
          height: h,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Text(_cameraError!,
                style:
                    TextStyle(color: AppColors.textSecondary, fontSize: 12)),
          ),
        ),
      );
    }
    if (!_cameraReady) {
      return SkeletonLoader(
        child: Container(
          height: h,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        height: h,
        child: CameraPreview(_cameraService.controller!),
      ),
    );
  }

  Widget _buildLocationTile(ThemeData theme) {
    if (_locationLoading) {
      return SkeletonLoader(
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      );
    }
    if (_locationError != null) {
      return Row(
        children: [
          Icon(Icons.location_off, size: 16, color: AppColors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_locationError!,
                style: TextStyle(color: AppColors.error, fontSize: 13)),
          ),
          TextButton(
              onPressed: () {
                setState(() => _locationLoading = true);
                _loadLocation();
              },
              child: const Text('Retry')),
        ],
      );
    }
    final loc = _location!;
    return Row(
      children: [
        Icon(Icons.location_on, size: 16, color: AppColors.success),
        const SizedBox(width: 8),
        Text(
          '${loc.latitude.toStringAsFixed(4)}°, '
          '${loc.longitude.toStringAsFixed(4)}°',
          style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
        ),
        const Spacer(),
        GestureDetector(
          onTap: () {
            setState(() => _locationLoading = true);
            _loadLocation();
          },
          child: Icon(Icons.refresh, size: 16, color: AppColors.gray),
        ),
      ],
    );
  }

  Widget _buildTodayLogs() {
    if (_logsLoading) {
      return Column(
        children: List.generate(
          2,
          (_) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SkeletonLoader(
              child: Container(
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (_todayLogs.isEmpty) {
      return Text(
        'No WFH check-ins today.',
        style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
      );
    }
    return Column(
      children: _todayLogs.map((log) => _WFHLogTile(log: log)).toList(),
    );
  }
}

// ── Log tile ──────────────────────────────────────────────────────────────────

class _WFHLogTile extends StatelessWidget {
  final WFHLog log;
  const _WFHLogTile({required this.log});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Icon(Icons.home_work_outlined,
              size: 20, color: AppColors.info),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  log.formattedTime,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
                if (log.taskDescription != null &&
                    log.taskDescription!.isNotEmpty)
                  Text(
                    log.taskDescription!,
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (log.isVerified)
            Icon(Icons.verified, size: 16, color: AppColors.success),
        ],
      ),
    );
  }
}

// ── Helper ────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: Theme.of(context)
            .textTheme
            .labelMedium
            ?.copyWith(color: AppColors.textSecondary),
      );
}
