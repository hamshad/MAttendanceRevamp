import 'package:flutter/material.dart';
import '../../../core/theme/app_colors.dart';
import '../../../models/attendance.dart';

class TodayTimeline extends StatelessWidget {
  final List<PunchSummary> punches;

  const TodayTimeline({super.key, required this.punches});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    if (punches.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'No punches recorded today',
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
        ),
      );
    }

    return Column(
      children: List.generate(punches.length, (i) {
        final punch = punches[i];
        final isLast = i == punches.length - 1;
        return _TimelineItem(punch: punch, isLast: isLast, isDark: isDark);
      }),
    );
  }
}

class _TimelineItem extends StatelessWidget {
  final PunchSummary punch;
  final bool isLast;
  final bool isDark;

  const _TimelineItem({required this.punch, required this.isLast, required this.isDark});

  @override
  Widget build(BuildContext context) {
    final color = _punchColor(punch.punchType, isDark);
    final icon = _punchIcon(punch.punchType);
    final label = _punchLabel(punch.punchType);

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timeline line + dot
          SizedBox(
            width: 32,
            child: Column(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: color.withAlpha(25),
                    shape: BoxShape.circle,
                    border: Border.all(color: color, width: 1.5),
                  ),
                  child: Icon(icon, size: 14, color: color),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 1.5,
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      color: Colors.grey.shade200,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Content
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(punch.punchTime),
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        punch.method,
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                      ),
                      if (punch.distanceFromOffice != null) ...[
                        Text(
                          ' · ${punch.distanceFromOffice}m from office',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                        ),
                      ],
                      if (punch.isInOffice == true) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.check_circle, size: 11, color: AppColors.statusColor('Present', isDark: isDark)),
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

  String _formatTime(DateTime dt) {
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    final ampm = dt.hour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }

  String _punchLabel(String type) => switch (type) {
        'In' => 'Punch In',
        'Out' => 'Punch Out',
        'BreakStart' => 'Break Start',
        'BreakEnd' => 'Break End',
        _ => type,
      };

  Color _punchColor(String type, bool isDark) => switch (type) {
        'In' => AppColors.statusColor('Present', isDark: isDark),
        'Out' => AppColors.statusColor('Absent', isDark: isDark),
        'BreakStart' => AppColors.statusColor('Late', isDark: isDark),
        'BreakEnd' => AppColors.statusColor('Holiday', isDark: isDark),
        _ => AppColors.gray,
      };

  IconData _punchIcon(String type) => switch (type) {
        'In' => Icons.login,
        'Out' => Icons.logout,
        'BreakStart' => Icons.coffee_outlined,
        'BreakEnd' => Icons.play_arrow,
        _ => Icons.circle,
      };
}
