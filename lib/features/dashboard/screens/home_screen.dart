import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../providers/dashboard_providers.dart';
import '../widgets/status_card.dart';
import '../widgets/punch_button.dart';
import '../widgets/today_timeline.dart';
import '../widgets/quick_stats.dart';
import '../../history/screens/attendance_history_screen.dart';
import '../../punch/screens/break_screen.dart';
import '../../alignment/alignment_providers.dart';
import '../../alignment/widgets/alignment_banner.dart';
import '../../../widgets/skeleton_loader.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final user = ref.watch(authNotifierProvider).value;
    final statusAsync = ref.watch(attendanceStatusProvider);
    final permissionsAsync = ref.watch(accessPermissionsProvider);

    return Column(
      children: [
        // ── Main Scroll Content ───────────────────────────────────────────────
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.read(attendanceStatusProvider.notifier).refresh(),
            child: CustomScrollView(
              slivers: [
                // ── App Bar ──────────────────────────────────────────────────
                SliverAppBar(
                  floating: true,
                  snap: true,
                  backgroundColor: theme.scaffoldBackgroundColor,
                  title: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _greeting(),
                        style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
                      ),
                      Text(
                        user?.firstName ?? '',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                  actions: const [],
                ),

                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      // Date
                      Text(
                        _todayLabel(),
                        style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
                      ),
                      const SizedBox(height: 12),

                      // ── User Alignment Alerts (GPS off, permission, etc.) ──
                      AlignmentBanner(
                        alerts: ref.watch(alignmentMonitorProvider).activeAlerts,
                        onDismiss: (id) =>
                            ref.read(alignmentMonitorProvider).dismissAlert(id),
                      ),

                      // ── Status Card ────────────────────────────────────────
                      statusAsync.when(
                        loading: () => const _StatusCardSkeleton(),
                        error: (_, _) =>
                            const _ErrorCard('Could not load attendance status'),
                        data: (status) => status != null
                            ? StatusCard(status: status)
                            : const _ErrorCard('No attendance data for today'),
                      ),
                      const SizedBox(height: 24),
                      // ── Punch Section ──────────────────────────────────────
                      Center(
                        child: statusAsync.when(
                          loading: () => const SizedBox(
                            width: 160,
                            height: 160,
                            child: CircularProgressIndicator(),
                          ),
                          error: (_, _) => const SizedBox.shrink(),
                          data: (status) => PunchButton(status: status),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ── Method Selector ────────────────────────────────────
                      permissionsAsync.when(
                        loading: () => const SizedBox.shrink(),
                        error: (_, _) => const SizedBox.shrink(),
                        data: (perms) => MethodSelector(permissions: perms),
                      ),
                      const SizedBox(height: 12),

                      // ── Take Break button (shown when punched in) ──────────
                      statusAsync.maybeWhen(
                        data: (status) {
                          final punchedIn = status?.isPunchedIn ?? false;
                          final onBreak = status?.isOnBreak ?? false;
                          if (!punchedIn && !onBreak) return const SizedBox.shrink();
                          return OutlinedButton.icon(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => const BreakScreen()),
                            ),
                            icon: Icon(
                              onBreak
                                  ? Icons.stop_circle_outlined
                                  : Icons.coffee_outlined,
                              size: 18,
                            ),
                            label: Text(onBreak ? 'Manage Break' : 'Take a Break'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.warning,
                              side: BorderSide(color: AppColors.warning.withAlpha(100)),
                              minimumSize: const Size(double.infinity, 44),
                            ),
                          );
                        },
                        orElse: () => const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 28),

                      // ── Today's Timeline ───────────────────────────────────
                      Text(
                        "Today's Timeline",
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      statusAsync.when(
                        loading: () => const _TimelineSkeleton(),
                        error: (_, _) => const SizedBox.shrink(),
                        data: (status) => TodayTimeline(
                          punches: status?.todaysPunches ?? [],
                        ),
                      ),
                      const SizedBox(height: 28),

                      // ── Quick Stats ────────────────────────────────────────
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'This Month',
                            style: theme.textTheme.titleSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          TextButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const AttendanceHistoryScreen(),
                              ),
                            ),
                            child: const Text('View All'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ref.watch(monthlyStatsProvider).when(
                        data: (s) => QuickStats(
                          present: s.present,
                          absent: s.absent,
                          late: s.late,
                          leave: s.leave,
                        ),
                        loading: () => const QuickStats(present: 0, absent: 0, late: 0, leave: 0),
                        error: (_, e) => const QuickStats(present: 0, absent: 0, late: 0, leave: 0),
                      ),
                      const SizedBox(height: 16),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning,';
    if (hour < 17) return 'Good Afternoon,';
    return 'Good Evening,';
  }

  String _todayLabel() {
    final now = DateTime.now();
    const days = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday',
      'Friday', 'Saturday', 'Sunday'
    ];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${days[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}, ${now.year}';
  }
}

// ── Skeletons / Error helpers ─────────────────────────────────────────────────

class _StatusCardSkeleton extends StatelessWidget {
  const _StatusCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return SkeletonLoader(
      child: Container(
        height: 100,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    );
  }
}

class _TimelineSkeleton extends StatelessWidget {
  const _TimelineSkeleton();

  @override
  Widget build(BuildContext context) {
    return SkeletonLoader(
      child: Column(
        children: List.generate(
          2,
          (_) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Container(
              height: 36,
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
}

class _ErrorCard extends StatelessWidget {
  final String message;

  const _ErrorCard(this.message);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.errorSubtle,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppColors.error, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppColors.error, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
