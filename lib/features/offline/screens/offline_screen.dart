import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/offline/offline_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/constants.dart';
import '../../../models/attendance.dart';
import '../../../models/offline_punch.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../punch/services/location_service.dart';
import '../providers/offline_screen_providers.dart';

class OfflineScreen extends ConsumerStatefulWidget {
  const OfflineScreen({super.key});

  @override
  ConsumerState<OfflineScreen> createState() => _OfflineScreenState();
}

class _OfflineScreenState extends ConsumerState<OfflineScreen> {
  Timer? _cooldownTimer;
  bool _isPunching = false;
  bool _isSyncing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkCooldown());
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _checkCooldown() {
    final last = ref.read(lastOfflinePunchTimeProvider);
    if (last != null && DateTime.now().difference(last) < const Duration(minutes: 5)) {
      _startCooldownTimer();
    }
  }

  void _startCooldownTimer() {
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      final cooldown = ref.read(offlineCooldownProvider);
      if (cooldown == null) _cooldownTimer?.cancel();
    });
  }

  String _resolvePrimaryDirection() {
    final status = ref.read(attendanceStatusProvider).value;
    final offlinePunches = ref.read(offlineQueueServiceProvider).getTodayPunches();

    // Find latest punch across server + offline
    DateTime? latestTime;
    String? latestType;

    if (status != null) {
      for (final p in status.todaysPunches) {
        if (latestTime == null || p.punchTime.isAfter(latestTime)) {
          latestTime = p.punchTime;
          latestType = p.punchType;
        }
      }
    }
    for (final p in offlinePunches) {
      if (latestTime == null || p.createdAt.isAfter(latestTime)) {
        latestTime = p.createdAt;
        latestType = p.direction;
      }
    }

    if (latestTime == null) return 'In';
    if (latestType == 'BreakStart') return 'BreakEnd';
    if (latestType == 'In' || latestType == 'BreakEnd') return 'Out';
    return 'In';
  }

  Future<void> _handlePunch(String direction) async {
    if (_isPunching) return;
    setState(() => _isPunching = true);

    if (!ref.read(canPunchOfflineProvider)) {
      final cooldown = ref.read(offlineCooldownProvider)!;
      final secs = cooldown.inSeconds;
      final m = secs ~/ 60;
      final s = secs % 60;
      _showSnackBar('Cooldown — wait $m:${s.toString().padLeft(2, '0')}');
      setState(() => _isPunching = false);
      return;
    }

    double lat = 0.0;
    double lng = 0.0;
    bool gotLocation = false;
    for (int i = 0; i < 3; i++) {
      try {
        final loc = await LocationService().getCurrentPosition();
        lat = loc.latitude;
        lng = loc.longitude;
        gotLocation = true;
        break;
      } catch (_) {
        if (i < 2) await Future.delayed(const Duration(seconds: 1));
      }
    }

    if (!gotLocation) {
      _showSnackBar('Could not get GPS location — enable GPS and try again');
      setState(() => _isPunching = false);
      return;
    }

    final queue = ref.read(offlineQueueServiceProvider);
    final punch = OfflinePunch()
      ..method = 'GPS'
      ..direction = direction
      ..latitude = lat
      ..longitude = lng;
    await queue.enqueue(punch);

    ref.read(pendingOfflineCountProvider.notifier).state = queue.pendingCount;
    ref.read(lastOfflinePunchTimeProvider.notifier).state = DateTime.now();
    ref.invalidate(offlinePunchListProvider);
    ref.invalidate(todayOfflinePunchesProvider);

    setState(() => _isPunching = false);
    _startCooldownTimer();
    _showSnackBar('Punch saved — will sync when online');
  }

  Future<void> _handleSync() async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);

    final result = await ref.read(syncServiceProvider).syncPendingPunches();

    ref.read(pendingOfflineCountProvider.notifier).state =
        ref.read(offlineQueueServiceProvider).pendingCount;
    ref.invalidate(offlinePunchListProvider);
    ref.invalidate(todayOfflinePunchesProvider);

    setState(() => _isSyncing = false);

    if (result.hasActivity) {
      _showSnackBar(result.failed == 0
          ? '${result.synced} synced'
          : '${result.synced} synced, ${result.failed} failed');
    }
  }

  Future<void> _handleDelete(OfflinePunch punch) async {
    await ref.read(offlineQueueServiceProvider).deleteItem(punch.key);
    ref.read(pendingOfflineCountProvider.notifier).state =
        ref.read(offlineQueueServiceProvider).pendingCount;
    ref.invalidate(offlinePunchListProvider);
    ref.invalidate(todayOfflinePunchesProvider);
  }

  Future<void> _handleRetry(OfflinePunch punch) async {
    punch.retryCount = 0;
    punch.errorMessage = null;
    await punch.save();
    ref.invalidate(offlinePunchListProvider);
    ref.invalidate(todayOfflinePunchesProvider);
  }

  void _showSnackBar(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isOnline = ref.watch(isOnlineProvider).value ?? false;
    final status = ref.watch(attendanceStatusProvider).value;
    final listAsync = ref.watch(offlinePunchListProvider);
    final todayOfflineAsync = ref.watch(todayOfflinePunchesProvider);
    final cooldown = ref.watch(offlineCooldownProvider);
    final canPunch = ref.watch(canPunchOfflineProvider);

    final primaryDir = _resolvePrimaryDirection();

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Offline Mode'),
        actions: [
          if (_isSyncing)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.sync),
              onPressed: _handleSync,
              tooltip: 'Sync now',
            ),
        ],
      ),
      body: Column(
        children: [
          _OfflineBanner(isOnline: isOnline),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _handleSync,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                children: [
                  _buildTimelineSection(status, todayOfflineAsync.valueOrNull ?? []),
                  const SizedBox(height: 24),
                  _buildQueueSection(listAsync.valueOrNull ?? []),
                ],
              ),
            ),
          ),
          _PunchFooter(
            primaryDirection: primaryDir,
            canPunch: canPunch,
            cooldown: cooldown,
            isPunching: _isPunching,
            onPunch: _handlePunch,
          ),
        ],
      ),
    );
  }

  Widget _buildTimelineSection(EmployeeStatus? status, List<OfflinePunch> offlinePunches) {
    final theme = Theme.of(context);

    final serverPunches = status?.todaysPunches ?? [];

    if (serverPunches.isEmpty && offlinePunches.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No punches today',
          style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
        ),
      );
    }

    final entries = <_TimelineEntry>[];
    for (final p in serverPunches) {
      entries.add(_TimelineEntry(
        time: p.punchTime,
        label: _directionLabel(p.punchType),
        direction: p.punchType,
        method: p.method,
        isOffline: false,
        isFailed: false,
      ));
    }
    for (final p in offlinePunches) {
      entries.add(_TimelineEntry(
        time: p.createdAt,
        label: _directionLabel(p.direction),
        direction: p.direction ?? '',
        method: 'Offline (${p.method})',
        isOffline: true,
        isFailed: p.retryCount >= AppConstants.maxRetryCount,
      ));
    }
    entries.sort((a, b) => a.time.compareTo(b.time));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Today',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        ...List.generate(entries.length, (i) {
          final e = entries[i];
          final isLast = i == entries.length - 1;
          final dotColor = _dotColorFor(e);
          return _buildTimelineItem(e, isLast, dotColor);
        }),
      ],
    );
  }

  Widget _buildTimelineItem(_TimelineEntry e, bool isLast, Color dotColor) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Column(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: dotColor.withAlpha(30),
                    shape: BoxShape.circle,
                    border: Border.all(color: dotColor, width: 2),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 1.5,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      color: Colors.grey.shade300,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        e.label,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(e.time),
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        e.method,
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                      ),
                      if (e.isOffline) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: (e.isFailed ? AppColors.error : AppColors.warning).withAlpha(30),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            e.isFailed ? 'failed' : 'pending',
                            style: TextStyle(
                              fontSize: 9,
                              color: e.isFailed ? AppColors.error : AppColors.warning,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueSection(List<OfflinePunch> punches) {
    final theme = Theme.of(context);
    final pending = punches.where((p) => p.retryCount < AppConstants.maxRetryCount).toList();
    final failed = punches.where((p) => p.retryCount >= AppConstants.maxRetryCount).toList();

    if (punches.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Icon(Icons.check_circle_outline, size: 40, color: Colors.grey.shade400),
            const SizedBox(height: 8),
            Text('No offline punches', style: TextStyle(color: Colors.grey.shade500)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Queue (${punches.length})',
          style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        if (pending.isNotEmpty) ...[
          for (final p in pending) _buildQueueCard(p, isFailed: false),
          const SizedBox(height: 8),
        ],
        if (failed.isNotEmpty) ...[
          Text(
            'Failed',
            style: TextStyle(fontSize: 12, color: AppColors.error, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          for (final p in failed) _buildQueueCard(p, isFailed: true),
        ],
      ],
    );
  }

  Widget _buildQueueCard(OfflinePunch punch, {required bool isFailed}) {
    return Dismissible(
      key: ValueKey(punch.key),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: AppColors.error,
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      onDismissed: (_) => _handleDelete(punch),
      child: Card(
        margin: const EdgeInsets.only(bottom: 8),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: isFailed ? AppColors.error.withAlpha(60) : Colors.grey.shade200,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _directionIconColor(punch.direction).withAlpha(20),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  _directionIcon(punch.direction),
                  size: 18,
                  color: _directionIconColor(punch.direction),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          _directionLabel(punch.direction),
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          punch.method,
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatTime(punch.createdAt),
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    ),
                    if (punch.errorMessage != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        punch.errorMessage!,
                        style: TextStyle(fontSize: 10, color: AppColors.error),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (isFailed)
                IconButton(
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: () => _handleRetry(punch),
                  tooltip: 'Retry',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  color: AppColors.warning,
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _directionLabel(String? dir) {
    switch (dir) {
      case 'In': return 'Punch In';
      case 'Out': return 'Punch Out';
      case 'BreakStart': return 'Break Start';
      case 'BreakEnd': return 'Break End';
      default: return dir ?? 'Punch';
    }
  }

  IconData _directionIcon(String? dir) {
    switch (dir) {
      case 'In': return Icons.login;
      case 'Out': return Icons.logout;
      case 'BreakStart': return Icons.coffee_outlined;
      case 'BreakEnd': return Icons.play_arrow;
      default: return Icons.circle;
    }
  }

  Color _directionIconColor(String? dir) {
    switch (dir) {
      case 'In': return AppColors.success;
      case 'Out': return AppColors.error;
      case 'BreakStart': return AppColors.warning;
      case 'BreakEnd': return AppColors.success;
      default: return AppColors.gray;
    }
  }

  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }
}

Color _dotColorFor(_TimelineEntry e) {
  if (e.isOffline && e.isFailed) return AppColors.error;
  if (e.isOffline) return AppColors.warning;
  switch (e.direction) {
    case 'In':
    case 'BreakEnd':
      return AppColors.success;
    case 'Out':
      return AppColors.error;
    case 'BreakStart':
      return AppColors.warning;
    default:
      return AppColors.success;
  }
}

class _TimelineEntry {
  final DateTime time;
  final String label;
  final String direction;
  final String method;
  final bool isOffline;
  final bool isFailed;

  _TimelineEntry({
    required this.time,
    required this.label,
    required this.direction,
    required this.method,
    required this.isOffline,
    required this.isFailed,
  });
}

class _OfflineBanner extends StatelessWidget {
  final bool isOnline;

  const _OfflineBanner({required this.isOnline});

  @override
  Widget build(BuildContext context) {
    if (isOnline) return const SizedBox.shrink();
    return Material(
      color: AppColors.error,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              const Icon(Icons.wifi_off, color: Colors.white, size: 14),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'No internet — punches saved locally',
                  style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PunchFooter extends StatelessWidget {
  final String primaryDirection;
  final bool canPunch;
  final Duration? cooldown;
  final bool isPunching;
  final void Function(String direction) onPunch;

  const _PunchFooter({
    required this.primaryDirection,
    required this.canPunch,
    this.cooldown,
    required this.isPunching,
    required this.onPunch,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final directions = ['In', 'Out'];
    if (primaryDirection == 'BreakEnd') directions.add('BreakEnd');

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(top: BorderSide(color: Colors.grey.shade200)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: _PunchButton(
                      label: 'Punch In',
                      icon: Icons.login,
                      color: AppColors.success,
                      isPrimary: primaryDirection == 'In',
                      isDisabled: primaryDirection != 'In' || !canPunch || isPunching,
                      isLoading: isPunching,
                      onTap: () => onPunch('In'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _PunchButton(
                      label: 'Punch Out',
                      icon: Icons.logout,
                      color: AppColors.error,
                      isPrimary: primaryDirection == 'Out',
                      isDisabled: primaryDirection != 'Out' || !canPunch || isPunching,
                      isLoading: isPunching,
                      onTap: () => onPunch('Out'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (cooldown != null)
                Text(
                  'Cooldown: ${cooldown!.inMinutes}:${(cooldown!.inSeconds % 60).toString().padLeft(2, '0')}',
                  style: TextStyle(fontSize: 11, color: AppColors.warning, fontWeight: FontWeight.w500),
                )
              else if (!isPunching)
                Text(
                  canPunch ? 'Tap to punch — saved offline' : '',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PunchButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool isPrimary;
  final bool isDisabled;
  final bool isLoading;
  final VoidCallback onTap;

  const _PunchButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.isPrimary,
    required this.isDisabled,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = isDisabled ? color.withAlpha(100) : color;

    return SizedBox(
      height: 52,
      child: Material(
        borderRadius: BorderRadius.circular(12),
        color: isPrimary ? effectiveColor : Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: isDisabled ? null : onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: isPrimary ? null : Border.all(color: effectiveColor, width: 1.5),
            ),
            child: Center(
              child: isLoading
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: isPrimary ? Colors.white : color,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(icon, size: 18, color: isPrimary ? Colors.white : effectiveColor),
                        const SizedBox(width: 6),
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: isPrimary ? Colors.white : effectiveColor,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
