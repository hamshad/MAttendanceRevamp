import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';

import '../../../core/api/api_endpoints.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/utils/date_time_utils.dart';
import '../../dashboard/providers/dashboard_providers.dart';

// ── Break model ───────────────────────────────────────────────────────────────

class BreakSummary {
  final int id;
  final String breakType;
  final DateTime startTime;
  final DateTime? endTime;
  final int durationMinutes;

  const BreakSummary({
    required this.id,
    required this.breakType,
    required this.startTime,
    this.endTime,
    required this.durationMinutes,
  });

  factory BreakSummary.fromJson(Map<String, dynamic> j) => BreakSummary(
        id: j['id'] as int,
        breakType: j['breakType'] as String,
        startTime: parseUtc(j['startTime'] as String),
        endTime: j['endTime'] != null
            ? parseUtc(j['endTime'] as String)
            : null,
        durationMinutes: j['durationMinutes'] as int? ?? 0,
      );

  bool get isOngoing => endTime == null;

  String get formattedStart {
    final h = startTime.toLocal().hour;
    final m = startTime.toLocal().minute.toString().padLeft(2, '0');
    final amPm = h >= 12 ? 'PM' : 'AM';
    final hour12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return '$hour12:$m $amPm';
  }

  String get formattedEnd {
    if (endTime == null) return 'ongoing...';
    final h = endTime!.toLocal().hour;
    final m = endTime!.toLocal().minute.toString().padLeft(2, '0');
    final amPm = h >= 12 ? 'PM' : 'AM';
    final hour12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return '$hour12:$m $amPm';
  }

  String get durationLabel {
    if (isOngoing) return 'ongoing';
    if (durationMinutes < 60) return '${durationMinutes}m';
    final h = durationMinutes ~/ 60;
    final m = durationMinutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────

final todayBreaksProvider =
    AsyncNotifierProvider<TodayBreaksNotifier, List<BreakSummary>>(
  () => TodayBreaksNotifier(),
);

class TodayBreaksNotifier extends AsyncNotifier<List<BreakSummary>> {
  @override
  Future<List<BreakSummary>> build() => _fetch();

  Future<List<BreakSummary>> _fetch() async {
    try {
      final dio = ref.read(dioClientProvider).dio;
      final response = await dio.get(ApiEndpoints.todayBreaks);
      final data = response.data['data'] as List<dynamic>? ?? [];
      return data
          .map((e) => BreakSummary.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_fetch);
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class BreakScreen extends ConsumerStatefulWidget {
  const BreakScreen({super.key});

  @override
  ConsumerState<BreakScreen> createState() => _BreakScreenState();
}

class _BreakScreenState extends ConsumerState<BreakScreen> {
  static const _breakTypes = ['Lunch', 'Tea', 'Personal'];

  String _selectedType = 'Lunch';
  bool _isSubmitting = false;

  // ── Live timer for ongoing break ───────────────────────────────────────────
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  DateTime? _breakStartTime;

  @override
  void initState() {
    super.initState();
    _syncTimerFromStatus();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimerFromStatus() {
    final statusAsync = ref.read(attendanceStatusProvider);
    final status = statusAsync.value;
    if (status?.isOnBreak != true) return;

    // Find the most recent BreakStart punch to get start time
    final breakStart = status!.todaysPunches
        .where((p) => p.isBreakStart)
        .fold<DateTime?>(null, (latest, p) {
      if (latest == null || p.punchTime.isAfter(latest)) {
        return p.punchTime;
      }
      return latest;
    });

    if (breakStart != null) {
      _breakStartTime = breakStart;
      _elapsed = DateTime.now().difference(breakStart);
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _elapsed = _breakStartTime != null
              ? DateTime.now().difference(_breakStartTime!)
              : _elapsed + const Duration(seconds: 1);
        });
      }
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    _elapsed = Duration.zero;
    _breakStartTime = null;
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _startBreak() async {
    setState(() => _isSubmitting = true);
    try {
      final dio = ref.read(dioClientProvider).dio;
      await dio.post(
        ApiEndpoints.startBreak,
        data: {'breakType': _selectedType},
      );
      if (!mounted) return;
      _breakStartTime = DateTime.now();
      _elapsed = Duration.zero;
      _startTimer();
      ref.invalidate(attendanceStatusProvider);
      await ref.read(todayBreaksProvider.notifier).refresh();
    } catch (e) {
      if (!mounted) return;
      _showSnack(_extractError(e));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _endBreak() async {
    setState(() => _isSubmitting = true);
    try {
      final dio = ref.read(dioClientProvider).dio;
      await dio.post(ApiEndpoints.endBreak);
      if (!mounted) return;
      _stopTimer();
      ref.invalidate(attendanceStatusProvider);
      await ref.read(todayBreaksProvider.notifier).refresh();
      if (mounted) Navigator.pop(context);
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

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusAsync = ref.watch(attendanceStatusProvider);
    final isOnBreak = statusAsync.value?.isOnBreak ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Break'),
        leading: const CloseButton(),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Timer / idle card ──────────────────────────────────────────
              if (isOnBreak)
                _TimerCard(elapsed: _elapsed, startTime: _breakStartTime)
              else
                _IdleCard(theme: theme),
              const SizedBox(height: 20),

              // ── Type selector (only when not on break) ─────────────────────
              if (!isOnBreak) ...[
                _SectionLabel('Break Type'),
                const SizedBox(height: 10),
                _TypeSelector(
                  types: _breakTypes,
                  selected: _selectedType,
                  onSelected: (t) => setState(() => _selectedType = t),
                ),
                const SizedBox(height: 24),
              ],

              // ── Action button ──────────────────────────────────────────────
              ElevatedButton.icon(
                onPressed: _isSubmitting
                    ? null
                    : (isOnBreak ? _endBreak : _startBreak),
                icon: _isSubmitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Icon(isOnBreak ? Icons.stop_circle_outlined : Icons.coffee),
                label: Text(
                  _isSubmitting
                      ? (isOnBreak ? 'Ending break…' : 'Starting break…')
                      : (isOnBreak ? 'END BREAK' : 'START BREAK'),
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      isOnBreak ? AppColors.error : AppColors.warning,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 52),
                  disabledBackgroundColor: AppColors.border,
                ),
              ),
              const SizedBox(height: 32),

              // ── Today's breaks list ────────────────────────────────────────
              _SectionLabel("Today's Breaks"),
              const SizedBox(height: 12),
              ref.watch(todayBreaksProvider).when(
                    loading: () => const _ListSkeleton(),
                    error: (_, _) => const SizedBox.shrink(),
                    data: (breaks) => breaks.isEmpty
                        ? _EmptyBreaks()
                        : _BreakList(breaks: breaks),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Timer card ────────────────────────────────────────────────────────────────

class _TimerCard extends StatelessWidget {
  final Duration elapsed;
  final DateTime? startTime;

  const _TimerCard({required this.elapsed, required this.startTime});

  String _format(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = (d.inMinutes % 60).toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  String _startedAt() {
    if (startTime == null) return '';
    final local = startTime!.toLocal();
    final h = local.hour;
    final m = local.minute.toString().padLeft(2, '0');
    final amPm = h >= 12 ? 'PM' : 'AM';
    final hour12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
    return 'Started at $hour12:$m $amPm';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        color: AppColors.warningSubtle,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.warning),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.timer_outlined,
                  size: 20, color: AppColors.warning),
              const SizedBox(width: 8),
              Text(
                _format(elapsed),
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: AppColors.warning,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Break in progress',
            style: TextStyle(
              color: AppColors.warning,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (startTime != null) ...[
            const SizedBox(height: 4),
            Text(
              _startedAt(),
              style: TextStyle(color: AppColors.warning, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Idle card ─────────────────────────────────────────────────────────────────

class _IdleCard extends StatelessWidget {
  final ThemeData theme;
  const _IdleCard({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.coffee_outlined,
              size: 28, color: AppColors.textSecondary),
          const SizedBox(width: 12),
          Text(
            'No active break',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

// ── Type selector chips ───────────────────────────────────────────────────────

class _TypeSelector extends StatelessWidget {
  final List<String> types;
  final String selected;
  final ValueChanged<String> onSelected;

  const _TypeSelector({
    required this.types,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 10,
      children: types
          .map((t) => ChoiceChip(
                label: Text(t),
                selected: selected == t,
                onSelected: (_) => onSelected(t),
                selectedColor: AppColors.warning,
                labelStyle: TextStyle(
                  color: selected == t
                      ? Colors.white
                      : theme.colorScheme.onSurface,
                  fontWeight: selected == t
                      ? FontWeight.w600
                      : FontWeight.normal,
                ),
                side: BorderSide(
                  color: selected == t
                      ? AppColors.warning
                      : AppColors.border,
                ),
              ))
          .toList(),
    );
  }
}

// ── Break list ────────────────────────────────────────────────────────────────

class _BreakList extends StatelessWidget {
  final List<BreakSummary> breaks;
  const _BreakList({required this.breaks});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: breaks.map((b) => _BreakRow(b)).toList(),
    );
  }
}

class _BreakRow extends StatelessWidget {
  final BreakSummary b;
  const _BreakRow(this.b);

  @override
  Widget build(BuildContext context) {
    final color = b.isOngoing ? AppColors.warning : AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(
            b.isOngoing ? Icons.radio_button_checked : Icons.circle,
            size: 10,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${b.breakType}: ${b.formattedStart} – ${b.formattedEnd}',
              style: TextStyle(fontSize: 14, color: AppColors.textPrimary),
            ),
          ),
          Text(
            b.durationLabel,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: b.isOngoing ? AppColors.warning : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyBreaks extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        'No breaks recorded today.',
        style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

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

class _ListSkeleton extends StatelessWidget {
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        2,
        (_) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            height: 24,
            decoration: BoxDecoration(
              color: AppColors.graySubtle,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
      ),
    );
  }
}
