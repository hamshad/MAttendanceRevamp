import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/auth/auth_provider.dart';
import '../../../core/api/api_endpoints.dart';
import '../../../core/theme/app_colors.dart';
import '../../../models/attendance.dart';
import '../../../widgets/attendance_calendar.dart';
import '../../../widgets/empty_state.dart';

/// Friendly label for a server attendance status.  Keeps the raw status key
/// for logic, but presents the full name to users.
String _statusLabel(String status) {
  return switch (status.toLowerCase()) {
    'wfh' => 'Work From Home',
    _ => status,
  };
}

class AttendanceHistoryScreen extends ConsumerStatefulWidget {
  const AttendanceHistoryScreen({super.key});

  @override
  ConsumerState<AttendanceHistoryScreen> createState() =>
      _AttendanceHistoryScreenState();
}

class _AttendanceHistoryScreenState
    extends ConsumerState<AttendanceHistoryScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  List<AttendanceDay> _days = [];
  bool _loading = true;
  String? _error;
  int? _selectedDay;

  static final _monthFmt = DateFormat('MMMM yyyy');
  static final _timeFmt = DateFormat('hh:mm a');

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = null;
      _days = [];
      _selectedDay = null;
    });
    try {
      final dio = ref.read(dioClientProvider).dio;
      final from = DateFormat('yyyy-MM-dd')
          .format(DateTime(_month.year, _month.month, 1));
      final to = DateFormat('yyyy-MM-dd')
          .format(DateTime(_month.year, _month.month + 1, 0));

      final response = await dio.get(
        ApiEndpoints.attendanceHistory,
        queryParameters: {'from': from, 'to': to, 'page': 1, 'pageSize': 31},
      );

      final data = response.data['data'] as Map<String, dynamic>;
      final items = (data['items'] as List)
          .map((e) => AttendanceDay.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.attendanceDate.compareTo(b.attendanceDate));

      setState(() {
        _days = items;
        _loading = false;
      });
    } catch (_) {
      setState(() {
        _loading = false;
        _error = 'Failed to load attendance history';
      });
    }
  }

  void _changeMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _selectedDay = null;
    });
    _fetch();
  }

  bool get _isCurrentMonth =>
      _month.year == DateTime.now().year &&
      _month.month == DateTime.now().month;

  // ── Derived data ───────────────────────────────────────────────────────────

  List<CalendarDay> get _calendarDays => _days.map((d) {
        final mins = d.workMinutes;
        final h = mins ~/ 60;
        final m = mins % 60;
        final hoursStr = mins > 0
            ? (h == 0 ? '${m}m' : '${h}h${m}m')
            : null;
        return CalendarDay(
          day: d.attendanceDate.day,
          status: d.status,
          hours: hoursStr,
          punchIn: d.firstInTime != null
              ? _timeFmt.format(d.firstInTime!.toLocal())
              : null,
          punchOut: d.lastOutTime != null
              ? _timeFmt.format(d.lastOutTime!.toLocal())
              : null,
        );
      }).toList();

  Map<String, int> get _summary {
    final counts = <String, int>{};
    for (final d in _days) {
      counts[d.status] = (counts[d.status] ?? 0) + 1;
    }
    return counts;
  }

  void _onDayTap(CalendarDay cal) {
    final AttendanceDay? att = _days.cast<AttendanceDay?>().firstWhere(
          (d) => d!.attendanceDate.day == cal.day,
          orElse: () => null,
        );
    if (att == null) return;

    setState(() => _selectedDay = cal.day);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _DayDetailSheet(day: att),
    ).then((_) {
      // Keep selected state for a moment or until another cell is clicked
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          'Attendance History',
          style: TextStyle(
            color: isDark ? Colors.white : AppColors.textPrimary,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        iconTheme: IconThemeData(
          color: isDark ? Colors.white : AppColors.textPrimary,
        ),
      ),
      body: Column(
        children: [
          // ── Month Navigator ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _MonthNavButton(
                  icon: Icons.chevron_left,
                  onPressed: () => _changeMonth(-1),
                ),
                Text(
                  _monthFmt.format(_month),
                  style: TextStyle(
                    color: isDark ? Colors.white : AppColors.textPrimary,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    letterSpacing: 0.5,
                  ),
                ),
                _MonthNavButton(
                  icon: Icons.chevron_right,
                  onPressed: _isCurrentMonth ? null : () => _changeMonth(1),
                ),
              ],
            ),
          ),

          // ── Content ─────────────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
                : _error != null
                    ? _ErrorView(error: _error!, onRetry: _fetch)
                    : RefreshIndicator(
                        onRefresh: _fetch,
                        color: AppColors.primary,
                        child: SingleChildScrollView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: _days.isEmpty
                              ? const EmptyState(
                                  icon: Icons.calendar_today_outlined,
                                  title: 'No records this month',
                                  subtitle:
                                      'Attendance data will appear here once available.',
                                )
                              : Column(
                                  children: [
                                    AttendanceCalendar(
                                      year: _month.year,
                                      month: _month.month,
                                      days: _calendarDays,
                                      onDayTap: _onDayTap,
                                      selectedDay: _selectedDay,
                                    ),
                                    const SizedBox(height: 32),
                                    _SummaryRow(summary: _summary),
                                    const SizedBox(height: 32),
                                  ],
                                ),
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}

class _MonthNavButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  const _MonthNavButton({required this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final enabled = onPressed != null;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
        borderRadius: BorderRadius.circular(12),
      ),
      child: IconButton(
        icon: Icon(
          icon, 
          size: 20, 
          color: enabled 
              ? (isDark ? Colors.white : AppColors.textPrimary) 
              : (isDark ? Colors.white.withOpacity(0.3) : AppColors.textPrimary.withOpacity(0.3)),
        ),
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        splashRadius: 20,
      ),
    );
  }
}

// ── Summary row ───────────────────────────────────────────────────────────────

class _SummaryRow extends StatelessWidget {
  final Map<String, int> summary;
  const _SummaryRow({required this.summary});

  static const _show = ['Present', 'HalfDay', 'Leave', 'Absent', 'WFH'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final items = _show.where((s) => (summary[s] ?? 0) > 0).toList();
    if (items.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 12,
      runSpacing: 8,
      alignment: WrapAlignment.center,
      children: items.map((status) {
        final count = summary[status]!;
        
        Color bg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
        Color fg = isDark ? Colors.white : AppColors.textPrimary;
        String label = _statusLabel(status);

        final s = status.toLowerCase();
        if (s == 'present') {
          bg = isDark ? const Color(0xFF0E2E2A) : const Color(0xFFE6F4EA);
          fg = isDark ? const Color(0xFF00C49F) : AppColors.success;
        } else if (s == 'halfday') {
          bg = isDark ? const Color(0xFF2A1C16) : const Color(0xFFFFF3E0);
          fg = isDark ? const Color(0xFFE28743) : AppColors.orange;
          label = 'HalfDay';
        } else if (s == 'leave') {
          bg = isDark ? const Color(0xFF2E220F) : const Color(0xFFFEF3C7);
          fg = isDark ? const Color(0xFFF59E0B) : AppColors.warning;
        } else if (s == 'absent') {
          bg = isDark ? const Color(0xFF2E0E0E) : const Color(0xFFFEE2E2);
          fg = isDark ? const Color(0xFFEF4444) : AppColors.error;
        } else if (s == 'wfh') {
          bg = isDark ? const Color(0xFF0E1E2E) : const Color(0xFFE8F0FE);
          fg = isDark ? const Color(0xFF3B82F6) : AppColors.info;
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$count',
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// ── Day detail sheet ──────────────────────────────────────────────────────────

class _DayDetailSheet extends StatelessWidget {
  final AttendanceDay day;
  const _DayDetailSheet({required this.day});

  static final _timeFmt = DateFormat('hh:mm a');
  static final _dateFmt = DateFormat('EEEE, MMMM d');

  Color _getStatusColor(String status, bool isDark) {
    final s = status.toLowerCase();
    if (isDark) {
      return switch (s) {
        'present' => const Color(0xFF00C49F),
        'halfday' => const Color(0xFFE28743),
        'weekoff' || 'weekend' => const Color(0xFF8A99AD),
        'leave'   => const Color(0xFFF59E0B),
        'absent'  => const Color(0xFFEF4444),
        'wfh'     => const Color(0xFF3B82F6),
        _         => const Color(0xFF8A99AD),
      };
    }
    return switch (s) {
      'present' => AppColors.success,
      'halfday' => AppColors.orange,
      'weekoff' || 'weekend' => AppColors.gray,
      'leave'   => AppColors.warning,
      'absent'  => AppColors.error,
      'wfh'     => AppColors.info,
      _         => AppColors.gray,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return DraggableScrollableSheet(
      initialChildSize: 0.45,
      minChildSize: 0.3,
      maxChildSize: 0.6,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF0F172A) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isDark ? 0.5 : 0.08),
              blurRadius: 20,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: isDark ? Colors.white24 : Colors.black12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),

            Expanded(
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _dateFmt.format(day.attendanceDate),
                        style: TextStyle(
                          color: isDark ? Colors.white : AppColors.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 20,
                        ),
                      ),
                      _StatusBadge(
                        status: day.status,
                        fgColor: _getStatusColor(day.status, isDark),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  Container(
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF0E1629) : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark ? Colors.white.withOpacity(0.05) : AppColors.border,
                      ),
                    ),
                    padding: const EdgeInsets.all(4),
                    child: Column(
                      children: [
                        _DetailRow(
                          icon: Icons.login,
                          iconColor: _getStatusColor('Present', isDark),
                          label: 'Punch In',
                          value: day.firstInTime != null
                              ? _timeFmt.format(day.firstInTime!.toLocal())
                              : '--:--',
                        ),
                        const _Divider(),
                        _DetailRow(
                          icon: Icons.logout,
                          iconColor: _getStatusColor('Absent', isDark),
                          label: 'Punch Out',
                          value: day.lastOutTime != null
                              ? _timeFmt.format(day.lastOutTime!.toLocal())
                              : '--:--',
                        ),
                        const _Divider(),
                        _DetailRow(
                          icon: Icons.access_time,
                          iconColor: _getStatusColor('wfh', isDark),
                          label: 'Work Duration',
                          value: _formatDuration(day.workMinutes),
                          valueColor: day.workMinutes > 0 ? _getStatusColor('Present', isDark) : null,
                        ),
                        const _Divider(),
                        _DetailRow(
                          icon: Icons.business_center_outlined,
                          iconColor: const Color(0xFF8B5CF6),
                          label: 'Shift',
                          value: day.shiftName ?? 'General Shift',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(int minutes) {
    if (minutes == 0) return '0h 0m';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    return '${h}h ${m}m';
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  final Color fgColor;
  const _StatusBadge({required this.status, required this.fgColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: fgColor.withOpacity(0.15),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: fgColor),
          const SizedBox(width: 6),
          Text(
            _statusLabel(status),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: fgColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: iconColor.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(width: 16),
          Text(
            label,
            style: TextStyle(
              color: isDark ? Colors.white70 : AppColors.textSecondary,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: valueColor ?? (isDark ? Colors.white : AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Divider(
        height: 1,
        thickness: 1,
        color: isDark ? Colors.white.withOpacity(0.08) : AppColors.border,
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 48, color: AppColors.error),
          const SizedBox(height: 12),
          Text(error,
              style: TextStyle(
                  color: isDark ? Colors.white70 : AppColors.textSecondary, fontSize: 14)),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
